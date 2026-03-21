local loopconfig     = require("loop").config
local class          = require("loop.tools.class")
local log            = require("loop.log")
local uitools        = require("loop.tools.uitools")
local filetools      = require("loop.tools.file")
local TreeBuffer     = require("loop.buf.TreeBuffer")
local wsmonitor      = require("loop.workspacemonitor")
local LRU            = require("loop.tools.LRU")
local floatwin       = require("loop.tools.floatwin")
local fntools        = require("loop.tools.fntools")

local uv             = vim.loop

---@class loop.comp.FileTree.ItemData
---@field path string
---@field name string
---@field is_dir boolean
---@field icon string
---@field icon_hl string
---@field is_current boolean?
---@field error_flag boolean?
---@field childrenload_req_id number
---@field children_loading boolean
---@field on_children_loaded fun()?

---@alias loop.comp.FileTree.ItemDef loop.comp.TreeBuffer.ItemData

-- at the top of your file
local _dev_icons_attempt, devicons
local _file_icons    = {
    txt      = "",
    md       = "",
    markdown = "",
    json     = "",
    lua      = "",
    py       = "",
    js       = "",
    ts       = "",
    html     = "",
    css      = "",
    c        = "",
    cpp      = "",
    h        = "",
    hpp      = "",
    sh       = "",
    rb       = "",
    go       = "",
    rs       = "",
    java     = "",
    kt       = "𝙆",
    default  = "",
}

local _error_node_id = {} -- unique id for the error node

---@param globs string[]|nil
---@return string[]|nil
local function _compile_globs(globs)
    if not globs or #globs == 0 then return nil end
    local compiled = {}
    for _, g in ipairs(globs) do
        -- Compile into a vim.regex object
        table.insert(compiled, vim.regex(vim.fn.glob2regpat(g)))
    end
    return compiled
end

---@param id string
---@param data loop.comp.FileTree.ItemData
local function _file_formatter(id, data)
    if not data then return {}, {} end
    local virt_chunks = {}
    if data.error_flag then
        table.insert(virt_chunks, { "⚠", "ErrorMsg" })
    end
    local chunks = {
        { data.icon, data.icon_hl },
        { " " },
        { data.name, data.is_current and "Type" or nil }
    }
    return chunks, virt_chunks
end


local function _show_help()
    local help_text = {
        "Navigation:",
        "  <CR>     Open file / Toggle directory",
        "",
        "Creation:",
        "  a        Create new file (in parent directory)",
        "  i        Create new file (inside directory / current folder)",
        "  A        Create new directory (in parent directory)",
        "  I        Create new directory (inside directory / current folder)",
        "",
        "Management:",
        "  r, c     Rename file/directory",
        "  d        Delete file or empty directory",
        "  D        Delete directory (recursive)",
        "",
        "Other:",
        "  R        Rescan workspace",
        "  g?       Show this help",
    }

    floatwin.show_floatwin(table.concat(help_text, "\n"), {
        title = "File Tree Help",
        relative = "editor",
        border = "rounded"
    })
end


---@class loop.comp.FileTree
---@field new fun(self:loop.comp.FileTree):loop.comp.FileTree
local FileTree = class()

function FileTree:init()
    self._expanded_lru = LRU:new(10000)
    self._monitor_lru = LRU:new(loopconfig.filetree.max_monitored_folders, {
        on_removed = function(path, cancel_fn)
            --vim.notify("removing monitor: " .. path)
            cancel_fn()
        end
    })

    self._viewport_monitor_fn = self:_get_viewport_monitor_fn()
    self._toggle_counter = 0
    self._reveal_counter = 0
    self._reload_counter = 0

    self:_setup_tree()
    self:_setup_keymaps()
end

function FileTree:_setup_tree()
    assert(not self._tree)

    self._tree = TreeBuffer:new({
        formatter = function(id, data)
            return _file_formatter(id, data)
        end,
        base_opts = {
            name = "Workspace Files",
            filetype = "loop-filetree",
            listed = false,
            wipe_when_hidden = true,
        }
    })

    self._tree:add_tracker({
        on_create = function()
            self:_on_buffer_create()
        end,
        on_delete = function()
            self:_on_buffer_delete()
        end,
        on_selection = function(id, data)
            if not data.is_dir then
                uitools.smart_open_file(data.path)
            end
        end,
        on_toggle = function(id, data, expanded)
            self._toggle_counter = self._toggle_counter + 1
            if data.is_dir then
                if expanded then
                    self._expanded_lru:put(data.path, true)
                    local old = data.childrenload_req_id
                    self._viewport_monitor_fn()
                    if old == data.childrenload_req_id then
                        self:_read_dir(data.path, self._reload_counter, true)
                    end
                else
                    self._expanded_lru:delete(data.path)
                end
            end
        end
    })
end

function FileTree:_on_buffer_create()
    assert(not self.bufenter_autocmd_id)
    assert(not self._workspace_tracker)
    assert(not self._cancel_viewport_timer)

    --vim.notify("_on_buffer_create: " .. self._tree:get_buf())
    local on_buffer_enter = function()
        if self._tree:get_buf() == -1 then
            return
        end
        local buf = vim.api.nvim_get_current_buf()
        if uitools.is_regular_buffer(buf) then
            local path = vim.api.nvim_buf_get_name(buf)
            if path ~= "" then
                self:_reveal(path, loopconfig.filetree.track_current_file.auto_collapse_others, true)
            end
        end
    end
    if loopconfig.filetree.track_current_file.enabled then
        self.bufenter_autocmd_id = vim.api.nvim_create_autocmd("BufEnter", {
            callback = on_buffer_enter,
        })
    end

    self._cancel_viewport_timer = fntools.start_timer(1000, self._viewport_monitor_fn)

    self:_init_workspace_tracker()
end

function FileTree:_on_buffer_delete()
    --vim.notify("_on_buffer_delete")

    self:_stop_workspace_tracker()

    if self.bufenter_autocmd_id then
        vim.api.nvim_del_autocmd(self.bufenter_autocmd_id)
        self.bufenter_autocmd_id = nil
    end

    if self._cancel_viewport_timer then
        self._cancel_viewport_timer()
        self._cancel_viewport_timer = nil
    end

    self:_clear_all_monitors()
end

---@private
---@return fun()
function FileTree:_get_viewport_monitor_fn()
    local lastwinid, topline, botline, toggle_counter
    return function()
        local buf = self._tree:get_buf()
        if buf <= 0 then return end

        local winid = vim.fn.bufwinid(buf)
        if winid <= 0 then return end

        local info = vim.fn.getwininfo(winid)[1]
        if not info then return end

        -- Detect if viewport or tree state changed
        if winid ~= lastwinid or info.topline ~= topline or info.botline ~= botline or toggle_counter ~= self._toggle_counter then
            lastwinid, topline, botline, toggle_counter = winid, info.topline, info.botline, self._toggle_counter

            local visible_items = self._tree:get_visible_items(winid)
            local active_folders = {}

            -- Identify folders that need monitoring
            for _, item in ipairs(visible_items) do
                local parent = self._tree:get_parent_item(item.id)
                if parent then
                    active_folders[parent.data.path] = true
                end
                if item.data.is_dir and item.expanded then
                    active_folders[item.data.path] = true
                end
            end

            -- 1. Cleanup stale monitors
            for path in self._monitor_lru:items() do
                if not active_folders[path] then
                    self._monitor_lru:delete(path)
                end
            end

            -- 2. Attach new monitors and Sync
            for path, _ in pairs(active_folders) do
                -- Only act if this folder is NOT already monitored
                if not self._monitor_lru:has(path) then
                    -- A. Start monitor FIRST to catch tail-end changes
                    self:_start_dir_monitor(path)

                    -- B. Immediate Sync to catch anything missed before the monitor started
                    self:_read_dir(path, self._reload_counter, false)
                end
            end
        end
    end
end

---@private
function FileTree:_setup_keymaps()
    local function with_item(fn)
        local item = self._tree:get_cursor_item()
        if item then fn(item) end
    end

    -- Creation
    -- "a" → always sibling file
    self._tree:add_keymap("a", {
        desc = "Create File",
        callback = function()
            with_item(function(i) self:_create_node(i, false, true) end)
        end
    })

    -- "A" → always sibling dir
    self._tree:add_keymap("A", {
        desc = "Create Directory",
        callback = function()
            with_item(function(i) self:_create_node(i, true, true) end)
        end
    })

    -- "i" → context-aware (inside folder)
    self._tree:add_keymap("i", {
        desc = "Create File (inside)",
        callback = function()
            with_item(function(i) self:_create_node(i, false, false) end)
        end
    })

    -- "I" → context-aware dir
    self._tree:add_keymap("I", {
        desc = "Create Directory (inside)",
        callback = function()
            with_item(function(i) self:_create_node(i, true, false) end)
        end
    })

    -- Refactoring
    self._tree:add_keymap("r", {
        desc = "Rename",
        callback = function() with_item(function(i) self:_rename_node(i) end) end
    })
    self._tree:add_keymap("c", {
        desc = "Change (Rename)",
        callback = function() with_item(function(i) self:_rename_node(i) end) end
    })
    self._tree:add_keymap("d", {
        desc = "Delete file or empty directory",
        callback = function() with_item(function(i) self:_delete_node(i) end) end
    })
    self._tree:add_keymap("D", {
        desc = "Delete Folder",
        callback = function() with_item(function(i) self:_delete_dir_recurive(i) end) end
    })

    -- Utilities
    self._tree:add_keymap("R", {
        desc = "Reload Workspace",
        callback = function() self:_reload() end
    })
    self._tree:add_keymap("g?", {
        desc = "Show Help",
        callback = function() _show_help() end
    })
end

function FileTree:_init_workspace_tracker()
    ---@param wsdir string?
    ---@param config loop.WorkspaceConfig?
    local function reload(wsdir, config)
        vim.schedule(function()
            self:_load_workspace(config and config.name,
                wsdir,
                config and config.files.include,
                config and config.files.exclude)
        end)
    end
    assert(not self._workspace_tracker)
    --vim.notify("(loop.nvim) tracker init")
    self._workspace_tracker = wsmonitor.add_tracker({
        on_open = function(wsdir, config)
            reload(wsdir, config)
        end,
        on_config_change = function(wsdir, config)
            reload(wsdir, config)
        end,
        on_close = function()
            reload(nil, nil)
        end
    })
end

function FileTree:_stop_workspace_tracker()
    if self._workspace_tracker then
        self._workspace_tracker:cancel()
        self._workspace_tracker = nil
    end
end

---@return loop.comp.BaseBuffer
function FileTree:get_compbuffer()
    return self._tree
end

---@param path string
---@param patterns string[]|nil
---@return boolean
function FileTree:_match_patterns(path, patterns)
    if not patterns then return false end
    for i = 1, #patterns do
        -- .match_str is significantly faster than vim.fn.match
        ---@diagnostic disable-next-line: undefined-field
        if patterns[i]:match_str(path) then
            return true
        end
    end
    return false
end

---@param rel string
---@param is_dir boolean
---@return boolean
function FileTree:_should_include(rel, is_dir)
    if is_dir and rel:sub(-1) == "/" then
        rel = rel:sub(1, #rel - 1)
    end
    if self:_match_patterns(rel, self._exclude_patterns) then
        return false
    end
    if self:_match_patterns(rel .. '/', self._exclude_patterns) then
        return false
    end
    if is_dir then
        return true
    end
    if self._include_patterns then
        return self:_match_patterns(rel, self._include_patterns)
    end
    return true
end

--- Starts a monitor for a single directory and manages its lifecycle via LRU
function FileTree:_start_dir_monitor(path)
    if not loopconfig.filetree.monitor_file_system then
        return
    end
    if self._monitor_lru:has(path) then
        return
    end
    local cancel_fn, error_msg = filetools.monitor_dir(path, function(fname, status)
        local full_path = vim.fs.joinpath(path, fname)
        vim.schedule(function()
            if self._tree:get_buf() ~= -1 then
                self:_handle_fs_change(full_path, status)
            end
        end)
    end)

    if cancel_fn then
        --vim.notify("attach_monitor: " .. path)
        self._monitor_lru:put(path, cancel_fn)
    elseif error_msg then
        log.log("FileTree monitor error: " .. tostring(error_msg), vim.log.levels.ERROR)
    end
end

function FileTree:_clear_all_monitors()
    --- this will stop monitors automatically
    self._monitor_lru:clear()
end

---@param name string?
---@param root string?
---@param include_globs string[]?
---@param exclude_globs string[]?
function FileTree:_load_workspace(name, root, include_globs, exclude_globs)
    self._root = root and vim.fs.normalize(root) or nil -- normalize is important because we may use / to split path
    self._include_patterns = include_globs and _compile_globs(include_globs) or nil
    self._exclude_patterns = exclude_globs and _compile_globs(exclude_globs) or nil
    self:_reload()
end

function FileTree:_reload()
    self._reload_counter = self._reload_counter + 1
    local path = self._root
    if not path or not self._include_patterns or not self._exclude_patterns then
        local error_msg = path and "Workspace configuration error" or "No workspace"
        local root_item = {
            id = _error_node_id,
            data = { path = "", name = error_msg, is_dir = false, icon = "⚠", icon_hl = "WarningMsg" }
        }
        self:_clear_all_monitors()
        self._tree:clear_items()
        self._tree:add_item(nil, root_item)
        return
    end

    self._tree:remove_item(_error_node_id)

    if not self._tree:have_item(path) then
        local icon, iconhl = self:_get_icon_for_node(path, true)
        local root_item = {
            id = path,
            expandable = true,
            expanded = true,
            data = {
                path = path,
                name = vim.fn.fnamemodify(path, ":t"),
                is_dir = true,
                icon = icon,
                icon_hl = iconhl
            }
        }
        self._tree:add_item(nil, root_item)
    end

    self:_read_dir(path, self._reload_counter, true)
end

---@param path string Full path to the changed file/dir
---@param status table|nil optional status from uv.fs_event
function FileTree:_handle_fs_change(path, status)
    path = vim.fs.normalize(path)
    local parent_path = vim.fs.normalize(vim.fn.fnamemodify(path, ":h"))

    -- Check if we even care about this parent
    local parent_item = self._tree:get_item(parent_path)
    if not parent_item then return end

    -- Use libuv to check if the file still exists
    ---@diagnostic disable-next-line: undefined-field
    uv.fs_stat(path, function(err, stat)
        vim.schedule(function()
            if err then
                -- File likely deleted or moved
                if self._tree:get_item(path) then
                    self._tree:remove_item(path)
                end
            else
                -- File created or modified
                local is_dir = stat.type == "directory"
                self:_upsert_single_item(parent_path, path, is_dir)
            end
        end)
    end)
end

---@param parent_path string
---@param full_path string
---@param is_dir boolean
---@private
function FileTree:_upsert_single_item(parent_path, full_path, is_dir)
    local root = self._root
    if not root then return end
    if self._tree:get_item(full_path) then
        -- If it exists, nothing to do
        return
    end
    -- Logical check: should this file even be here?
    local rel = vim.fs.relpath(root, full_path)
    if not rel or not self:_should_include(rel, is_dir) then return end
    -- Prepare the new item definition
    local name = vim.fn.fnamemodify(full_path, ":t")
    local icon, icon_hl = self:_get_icon_for_node(name, is_dir)
    ---@type loop.comp.TreeBuffer.ItemDef
    local new_item = {
        id = full_path,
        expandable = is_dir,
        expanded = is_dir and self._expanded_lru:has(full_path),
        data = {
            path = full_path,
            name = name,
            is_dir = is_dir,
            icon = icon,
            icon_hl = icon_hl
        }
    }
    -- Find the correct alphabetical position among siblings
    local loname = name:lower()
    local siblings = self._tree:get_children(parent_path)
    local insert_target_id = nil
    local insert_before = false

    for _, sibling in ipairs(siblings) do
        -- Sorting logic: Directories first, then alphabetical
        local sibling_is_dir = sibling.data.is_dir
        local sibling_name = sibling.data.name:lower()
        local should_be_before = false
        if is_dir ~= sibling_is_dir then
            should_be_before = is_dir -- dirs come before files
        else
            should_be_before = loname < sibling_name
        end
        if should_be_before then
            insert_target_id = sibling.id
            insert_before = true
            break
        end
    end
    if insert_target_id then
        -- Insert into the specific alphabetical slot
        self._tree:add_sibling(insert_target_id, new_item, insert_before)
    else
        -- Either no siblings exist, or this belongs at the very end
        self._tree:add_item(parent_path, new_item)
    end
end

---@param name string The filename or directory name
---@param is_dir boolean
---@return string icon
---@return string|nil hl_group
function FileTree:_get_icon_for_node(name, is_dir)
    if is_dir then
        return "", "Directory"
    end
    if not _dev_icons_attempt then
        _dev_icons_attempt = true
        local loaded, res = pcall(require, "nvim-web-devicons")
        if loaded then devicons = res end
    end

    local icon, icon_hl
    local ext = name:match("%.([^.]+)$") or ""
    if devicons then
        icon, icon_hl = devicons.get_icon(name, ext, { default = false })
    else
        icon = _file_icons[ext] or ""
    end

    return icon, icon_hl
end

---@param path string
---@param reload_counter number
---@param recursive boolean
function FileTree:_read_dir(path, reload_counter, recursive)
    if reload_counter ~= self._reload_counter then return end
    local item = self._tree:get_item(path)
    if not item then return end
    ---@type loop.comp.FileTree.ItemData
    local data = item.data

    local req_id = (data.childrenload_req_id or 0) + 1
    data.children_loading = true
    data.childrenload_req_id = req_id
    data.on_children_loaded = nil

    --vim.notify("Scanning dir: " .. path)
    -- Asynchronous scandir
    ---@diagnostic disable-next-line: undefined-field
    uv.fs_scandir(path, function(err, handle)
        if reload_counter ~= self._reload_counter then return end
        if req_id ~= data.childrenload_req_id then return end
        local entries = {}
        if handle then
            while true do
                ---@diagnostic disable-next-line: undefined-field
                local name, type = uv.fs_scandir_next(handle)
                if not name then break end
                table.insert(entries, { name = name, type = type })
            end
        end
        -- schedule because read_dir is called in a fast event context
        vim.schedule(function()
            if reload_counter ~= self._reload_counter then return end
            if req_id ~= data.childrenload_req_id then return end
            self:_process_dir(path, entries, err ~= nil)
            data.children_loading = false
            if data.on_children_loaded then
                data.on_children_loaded()
                data.on_children_loaded = nil
            end
            -- Handle nested expansion for existing expanded folders
            -- This ensures that if a folder was already expanded, we refresh its view too
            if recursive then
                for _, entry in ipairs(entries) do
                    if entry.type == "directory" then
                        local child_path = vim.fs.joinpath(path, entry.name)
                        local child_item = self._tree:get_item(child_path)
                        -- it's important to load non-expanded nodes,
                        -- otherwise it will load the whole tree and we may have infinite recursion with symlinks
                        if child_item and child_item.expanded then
                            self:_read_dir(child_path, reload_counter, recursive)
                        end
                    end
                end
            end
        end)
    end)
end

---@param path string
---@param entries table[]
---@param error_flag boolean
function FileTree:_process_dir(path, entries, error_flag)
    local root = self._root
    if not root then return end
    local parent_item = self._tree:get_item(path)
    if not parent_item then return end

    if error_flag then
        parent_item.data.error_flag = true
        self._tree:refresh_item(path)
    end

    -- Map new entries for quick lookup and filtering
    local new_entries_map = {}
    for _, entry in ipairs(entries) do
        local full_path = vim.fs.joinpath(path, entry.name)
        local is_dir = entry.type == "directory"
        local rel = vim.fs.relpath(root, full_path)

        if rel and self:_should_include(rel, is_dir) then
            new_entries_map[full_path] = entry
        end
    end

    -- Identify and remove children that are no longer present
    local current_children = self._tree:get_children(path)
    for _, child in ipairs(current_children) do
        if not new_entries_map[child.id] then
            self._tree:remove_item(child.id)
        end
    end

    -- Create entries and reverse order them to improve the performance of _upsert_single_item
    local sorted_entries = {}
    for full_path, entry in pairs(new_entries_map) do
        table.insert(sorted_entries, { path = full_path, name = entry.name, is_dir = (entry.type == "directory") })
    end
    table.sort(sorted_entries, function(a, b)
        if a.is_dir ~= b.is_dir then return a.is_dir end
        return a.name:lower() > b.name:lower() -- reverse order
    end)
    -- upsert
    for _, entry in ipairs(sorted_entries) do
        self:_upsert_single_item(path, entry.path, entry.is_dir)
    end
end

-- async reveal
---@param path string
---@param collapse_others boolean?
---@param set_current boolean?
function FileTree:_reveal(path, collapse_others, set_current)
    local root = self._root
    if not root then return end
    if not path or path == "" then return end

    if collapse_others then
        -- Collapse everything that isn't a parent of the target path
        local items = self._tree:get_items()
        for _, item in ipairs(items) do
            -- Don't collapse the root and don't collapse if the item is a parent of our target
            -- We check if 'id' is a prefix of 'path'
            if item.id ~= root and item.expanded then
                if not vim.startswith(path, item.id) then
                    self._tree:collapse(item.id)
                end
            end
        end
    end

    -- Unset the flag on the previous item
    if self._last_revealed_id then
        local id = self._last_revealed_id
        self._last_revealed_id = nil
        local old_item = self._tree:get_item(id)
        if old_item then
            old_item.data.is_current = false
            self._tree:refresh_item(id)
        end
    end

    path = vim.fs.normalize(path)
    local rel = vim.fs.relpath(root, path)
    if not rel then
        return
    end

    local parts = rel ~= "" and vim.split(rel, "/", { plain = true }) or {}
    self._reveal_counter = self._reveal_counter + 1
    local token = {
        reload_counter = self._reload_counter,
        reveal_counter = self._reveal_counter
    }
    self:_reveal_step(root, parts, 1, set_current or false, token)
end

---@param parent string The current directory path we are looking inside
---@param parts string[] The split segments of the relative path to the target
---@param idx number The current index in parts we are looking for
---@param set_current boolean
---@param token {reload_counter:number,reveal_counter:number}
function FileTree:_reveal_step(parent, parts, idx, set_current, token)
    if token.reveal_counter ~= self._reveal_counter then return end
    if token.reload_counter ~= self._reload_counter then return end

    if idx > #parts then
        self._tree:set_cursor_by_id(parent)
        if set_current then
            local data = self._tree:get_item(parent)
            if data then
                self._last_revealed_id = parent
                data.data.is_current = true
                self._tree:refresh_item(parent)
            end
        end
        return
    end

    local next_path = vim.fs.joinpath(parent, parts[idx])
    local parent_item = self._tree:get_item(parent)
    if not parent_item then return end


    local function continue()
        if self._tree:get_item(next_path) then
            self:_reveal_step(next_path, parts, idx + 1, set_current, token)
        else
            log.log("Reveal failed: path not found in tree: " .. next_path, vim.log.levels.DEBUG)
        end
    end

    -- If it's a directory, we MUST expand it to see children
    if not parent_item.expanded then
        self._tree:expand(parent) -- This triggers _read_dir
    end
    -- Check if we are currently waiting on the disk I/O
    if parent_item.data.children_loading then
        parent_item.data.on_children_loaded = vim.schedule_wrap(function()
            continue()
        end)
    else
        -- Already loaded and expanded, proceed immediately
        continue()
    end
end

---@param collapse_others boolean?
function FileTree:reveal_current_file(collapse_others)
    local buf = vim.api.nvim_get_current_buf()
    if uitools.is_regular_buffer(buf) then
        local path = vim.api.nvim_buf_get_name(buf)
        if path ~= "" then
            self:_reveal(path, collapse_others or false, true)
        end
    end
end

--- Create a new file or directory
---@param item table The parent or sibling item
---@param as_dir boolean
---@param force_parent boolean?
function FileTree:_create_node(item, as_dir, force_parent)
    -- Determine base directory: if item is file, use its parent. If dir, use it.
    local path = item.data.path

    local base_dir
    if force_parent then
        -- always behave like "a" (sibling creation)
        base_dir = vim.fn.fnamemodify(item.data.path, ":h")
    else
        -- smart behavior (like "i")
        if item.data.is_dir then
            base_dir = item.data.path
        else
            base_dir = vim.fn.fnamemodify(item.data.path, ":h")
        end
    end

    local type_label = as_dir and "directory" or "file"

    local reload_counter = self._reload_counter
    floatwin.input_at_cursor({
            prompt = "New " .. type_label .. " name",
            validate = function(name)
                local root = self._root
                if not root or reload_counter ~= self._reload_counter then
                    return false, ("Cannot create %s, tree was reloaded"):format(type_label)
                end
                if not name or name == "" then return false, "Name cannot be empty" end
                local new_path = vim.fs.joinpath(base_dir, name)
                local rel = vim.fs.relpath(root, new_path)
                if not rel then return false, "Invalid name" end
                vim.notify("validating " .. rel)
                if not self:_should_include(rel, as_dir) then
                    return false, "Name incompatible with worspace file patterns"
                end
                return true
            end
        },
        function(name)
            if not name or name == "" then return end
            if reload_counter ~= self._reload_counter then return end
            if not self._tree:get_item(path) then return end

            local new_path = vim.fs.joinpath(base_dir, name)
            if as_dir then
                ---@diagnostic disable-next-line: undefined-field
                local ok, err = uv.fs_mkdir(new_path, 493) -- 493 is octal 0755
                if ok then
                    self:_reveal(new_path)
                else
                    vim.notify(err, vim.log.levels.ERROR)
                end
            else
                local created, err = filetools.create_file(new_path)
                if created then
                    self:_read_dir(base_dir, self._reload_counter, false)
                    self:_reveal(new_path)
                else
                    vim.notify(err or "Failed to create file", vim.log.levels.ERROR)
                end
            end
        end)
end

--- Rename a file or directory
---@param item table
function FileTree:_rename_node(item)
    local is_dir = item.data.is_dir
    local old_path = item.data.path
    local old_name = item.data.name
    local parent_dir = vim.fn.fnamemodify(old_path, ":h")

    local reload_counter = self._reload_counter
    floatwin.input_at_cursor({
            prompt = ("Rename `%s`"):format(old_name),
            default_text = old_name,
            validate = function(name)
                local root = self._root
                if not root or reload_counter ~= self._reload_counter then
                    return false, "Cannot change name, tree was reloaded"
                end
                if not name or name == "" then return false, "Name cannot be empty" end
                local new_path = vim.fs.joinpath(parent_dir, name)
                local rel = vim.fs.relpath(root, new_path)
                vim.notify("validating " .. rel)
                if not rel then return false, "Invalid name" end
                if not self:_should_include(rel, is_dir) then
                    return false, "Name incompatible with worspace file patterns"
                end
                return true
            end
        },
        function(new_name)
            if not new_name or new_name == "" then return end
            if reload_counter ~= self._reload_counter then return end
            if not self._tree:get_item(old_path) then return end
            local new_path = vim.fs.joinpath(parent_dir, new_name)
            ---@diagnostic disable-next-line: undefined-field
            local ok, err = uv.fs_rename(old_path, new_path)
            if ok then
                self:_read_dir(parent_dir, self._reload_counter, false)
                self:_reveal(new_path)
            else
                vim.notify("Rename failed: " .. err, vim.log.levels.ERROR)
            end
        end)
end

--- Delete a file or directory only if it matches the wanted type
---@param item table The TreeBuffer item
function FileTree:_delete_node(item)
    -- Check if the item type matches the 'wanted' type
    local is_folder = item.data.is_dir
    local path = item.data.path
    if path == self._root then
        vim.notify("Cannot delete workspace root")
        return
    end
    local parent_dir = vim.fn.fnamemodify(path, ":h")
    local type_str = is_folder and "directory" or "file"
    local reload_counter = self._reload_counter
    -- Confirmation dialog
    local confirm = uitools.confirm_action(("Delete %s?\n%s"):format(type_str, path), false, function(confirmed)
        if not confirmed then return end
        if reload_counter ~= self._reload_counter then return end
        if not self._tree:get_item(path) then return end
        -- Attempt simple removal
        local success, err_msg = os.remove(path)
        self:_read_dir(parent_dir, self._reload_counter, false)
        if not success then
            vim.notify(("Failed to delete %s\n%s"):format(type_str, err_msg), vim.log.levels.ERROR)
        end
    end)
end

--- Delete a directory and all its contents
---@param item table The TreeBuffer item
function FileTree:_delete_dir_recurive(item)
    if not item.data.is_dir then
        vim.notify("Selected item is not a directory", vim.log.levels.WARN)
        return
    end
    local path = item.data.path
    if path == self._root then
        vim.notify("Cannot delete workspace root", vim.log.levels.WARN)
        return
    end
    local parent_dir = vim.fn.fnamemodify(path, ":h")
    local reload_counter = self._reload_counter
    -- Pass 'true' to confirm_action if it supports a "danger" highlight
    uitools.confirm_action("RECURSIVELY delete directory?\n" .. path, false, function(confirmed)
        if not confirmed or reload_counter ~= self._reload_counter then return end
        if not self._tree:get_item(path) then return end

        -- 'rf' means recursive and force
        local success = vim.fn.delete(path, "rf")
        if success == 0 then
            self:_read_dir(parent_dir, self._reload_counter, false)
        else
            vim.notify("Failed to delete directory: " .. path, vim.log.levels.ERROR)
        end
        -- Note: The monitor will handle removing the item from the tree
    end)
end

return FileTree
