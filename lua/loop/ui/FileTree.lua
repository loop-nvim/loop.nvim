local loopconfig     = require("loop").config
local class          = require("loop.utils.class")
local log            = require("loop.log")
local strtools       = require("loop.utils.strtools")
local uitools        = require("loop.utils.uitools")
local filetools      = require("loop.utils.file")
local TreeBuffer     = require("loop.buf.TreeBuffer")
local wsmonitor      = require("loop.workspacemonitor")
local LRU            = require("loop.utils.LRU")
local floatwin       = require("loop.utils.floatwin")
local utils          = require("loop.utils.utils")

---@class loop.comp.FileTree.ItemData
---@field path string
---@field name string
---@field loname string
---@field is_dir boolean
---@field is_link boolean?
---@field icon string
---@field icon_hl string
---@field is_current boolean?
---@field error_flag boolean?
---@field childrenload_req_id number
---@field children_loading boolean
---@field on_children_loaded fun()?

---@alias loop.comp.FileTree.ItemDef loop.comp.TreeBuffer.ItemData

---@class loop.FileTree.PrepareDirEntry
---@field name string
---@field type string

---@class loop.FileTree.ProcessDirEntry
---@field name string
---@field is_dir boolean
---@field is_link boolean

---@class loop.FileTree.UpsetSingleItemArgs
---@field parent_path string
---@field full_path string
---@field name string
---@field loname string
---@field is_dir boolean
---@field is_link boolean?

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

---@param id string
---@param data loop.comp.FileTree.ItemData
local function _file_formatter(id, data)
    if not data then return {}, {} end
    local virt_chunks = {}
    if data.error_flag then
        table.insert(virt_chunks, { "⚠", "ErrorMsg" })
    end
    if data.is_link then
        table.insert(virt_chunks, { "↗", "Special" })
    end
    local chunks = {
        { data.icon, data.icon_hl },
        { " " },
        { data.name, data.is_current and "Type" or nil }
    }
    return chunks, virt_chunks
end


local function _show_help()
    local help_text = { [[
NAVIGATION
==========
`ENTER`   Open file / Toggle directory
`R`       Refresh tree

CREATION (FILE)
===============
`a`       Create in parent directory
`i`       Create inside selected directory

CREATION (DIRECTORY)
====================
`A`       Create in parent directory
`I`       Create inside selected directory

MANAGEMENT
==========
`r`       Rename file or directory
`d!`      **Permanently** delete file or empty directory
`D!`      **Permanently** delete directory and **all** its contents (recursive)

OTHER
=====
`g?`      Show this help]]
    }

    floatwin.show_floatwin(table.concat(help_text, "\n"), {
        title = " File Tree Help ",
        is_markdown = true,
    })
end


---@class loop.comp.FileTree
---@field new fun(self:loop.comp.FileTree):loop.comp.FileTree
local FileTree = class()

function FileTree:init()
    self._expanded_lru = LRU:new(1000) -- limit to 1000 for performance (note that those are stored in the persistence)
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
        header = { { "Worskpace files", "Title" } },
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
                vim.schedule(function()
                    self:_reveal(path, loopconfig.filetree.track_current_file.auto_collapse_others, true)
                end)
            end
        end
    end
    if loopconfig.filetree.track_current_file.enabled then
        self.bufenter_autocmd_id = vim.api.nvim_create_autocmd("BufEnter", {
            callback = on_buffer_enter,
        })
    end

    self._cancel_viewport_timer = utils.start_timer(1000, self._viewport_monitor_fn)

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
                -- Start monitor FIRST to catch tail-end changes
                if self:_start_dir_monitor(path) then
                    -- If monitoring, immediate Sync to catch anything missed before the monitor started
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
        desc = "Rename file or directory",
        callback = function() with_item(function(i) self:_rename_node(i) end) end
    })
    self._tree:add_keymap("d!", {
        desc = "Permanenty delete file or empty directory",
        callback = function() with_item(function(i) self:_delete_node(i) end) end
    })
    self._tree:add_keymap("D!", {
        desc = "Permanenty delete folder and ALL it's content",
        callback = function() with_item(function(i) self:_delete_dir_recurive(i) end) end
    })

    -- Utilities
    self._tree:add_keymap("R", {
        desc = "Refresh tree",
        callback = function() self:_on_refresh_by_user() end
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
        local follow_symlinks
        if config then
            follow_symlinks = config.files.follow_symlinks
        end
        vim.schedule(function()
            self:_load_workspace(config and config.name,
                wsdir,
                config and config.files.include,
                config and config.files.exclude,
                follow_symlinks)
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

---@param rel string
---@param is_dir boolean
---@return boolean
function FileTree:_should_include(rel, is_dir)
    if is_dir then
        -- dir is included unless explicitly excluded
        return strtools.check_path_pattern(rel, true, nil, self._exclude_patterns)
    end
    return strtools.check_path_pattern(rel, false, self._include_patterns, self._exclude_patterns)
end

--- Starts a monitor for a single directory and manages its lifecycle via LRU
---@private
---@param path string
---@return boolean
function FileTree:_start_dir_monitor(path)
    if not loopconfig.filetree.monitor_file_system then
        return false
    end
    if self._monitor_lru:has(path) then
        return false
    end
    local cancel_fn, error_msg = filetools.monitor_dir(path, function(name, status)
        path = vim.fs.normalize(path)
        local reload_counter = self._reload_counter
        ---@type loop.FileTree.ProcessDirEntry[]
        if reload_counter ~= self._reload_counter then return end
        if self._tree:get_buf() ~= -1 then
            --vim.notify("change: " .. path .. " - " .. name)
            -- rescan the whole dir, detecting individual file change is not reliable on case insenstive systems
            self:_read_dir(path, reload_counter, false)
        end
    end)
    if not cancel_fn then
        log.log("FileTree monitor error: " .. tostring(error_msg or "unknown error"), vim.log.levels.ERROR)
        return false
    end
    --vim.notify("attaching monitor: " .. path)
    self._monitor_lru:put(path, cancel_fn)
    return true
end

function FileTree:_clear_all_monitors()
    --- this will stop monitors automatically
    self._monitor_lru:clear()
end

---@param name string?
---@param root string?
---@param include_globs string[]?
---@param exclude_globs string[]?
---@param follow_symlinks boolean?
function FileTree:_load_workspace(name, root, include_globs, exclude_globs, follow_symlinks)
    self._root = root and vim.fs.normalize(root) or nil -- normalize is important because we may use / to split path
    self._include_patterns = include_globs and strtools.compile_globs(include_globs) or nil
    self._exclude_patterns = exclude_globs and strtools.compile_globs(exclude_globs) or nil
    self._follow_symlinks = follow_symlinks
    self:_reload()
end

function FileTree:_reload()
    self._reload_counter = self._reload_counter + 1
    local path = self._root
    if not path or not self._include_patterns or not self._exclude_patterns or self._follow_symlinks == nil then
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
        local icon, iconhl = self:_get_icon_for_node(path, true, false)
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
    if self._pending_selection then
        self:_reveal(self._pending_selection)
        self._pending_selection = nil
    end
end

function FileTree:_on_refresh_by_user()
    self._reload_counter = self._reload_counter + 1
    self._tree:clear_items()
    -- delay a little to
    -- avoid flicker, protect against burst, and to provide visual feedback
    local reload_counter = self._reload_counter
    vim.defer_fn(function()
        if reload_counter == self._reload_counter then
            self:_reload()
        end
    end, 300)
end

---@private
---@param parent_id string
---@param item loop.comp.TreeBuffer.ItemDef
function FileTree:_upsert_single_item(parent_id, item)
    local root = self._root
    if not root then return end
    local data = item.data ---@type loop.comp.FileTree.ItemData
    do
        local existing = self._tree:get_item(item.id)
        if existing then
            local type_changed = (data.is_dir ~= existing.data.is_dir)
            if not type_changed then
                if data.is_link ~= existing.data.is_link then
                    existing.data.is_link = data.is_link
                    self._tree:refresh_item(item.id)
                end
                return -- nothing to do if name did not change
            end
            self._tree:remove_item(item.id)
        end
    end
    -- Find the correct alphabetical position among siblings
    local siblings = self._tree:get_children(parent_id)
    local insert_target_id = nil
    local insert_before = false
    for _, sibling in ipairs(siblings) do
        -- Sorting logic: Directories first, then alphabetical
        local sibling_is_dir = sibling.data.is_dir
        local sibling_name = sibling.data.loname
        local should_be_before = false
        if data.is_dir ~= sibling_is_dir then
            should_be_before = data.is_dir -- dirs come before files
        else
            should_be_before = data.loname < sibling_name
        end
        if should_be_before then
            insert_target_id = sibling.id
            insert_before = true
            break
        end
    end
    if insert_target_id then
        -- Insert into the specific alphabetical slot
        self._tree:add_sibling(insert_target_id, item, insert_before)
    else
        -- Either no siblings exist, or this belongs at the very end
        self._tree:add_item(parent_id, item)
    end
end

---@param name string The filename or directory name
---@param is_dir boolean
---@return string icon
---@return string|nil hl_group
function FileTree:_get_icon_for_node(name, is_dir, is_link)
    if not _dev_icons_attempt then
        _dev_icons_attempt = true
        local loaded, res = pcall(require, "nvim-web-devicons")
        if loaded then devicons = res end
    end

    local icon, icon_hl
    if is_dir then
        icon, icon_hl = "", "Directory"
    elseif not is_link then
        local ext = name:match("%.([^.]+)$") or ""
        if devicons then
            icon, icon_hl = devicons.get_icon(name, ext, { default = false })
        else
            icon = _file_icons[ext]
        end
    end

    return icon or "", icon_hl
end

---@param path string
---@param prep_entries loop.FileTree.PrepareDirEntry[]
---@param callback fun(resolved_entries: loop.FileTree.ProcessDirEntry[])
function FileTree:_prepare_dir_entries(path, prep_entries, callback)
    local root = self._root
    local resolved = {} ---@type loop.FileTree.ProcessDirEntry[]
    local pending = #prep_entries
    -- Handle empty directories immediately
    if pending == 0 or not root then
        callback({})
        return
    end

    ---@type fun(fp:string,name:string,is_dir:boolean,is_link:boolean)
    local process_entry = function(full_path, name, is_dir, is_link)
        if not is_link or self._follow_symlinks then
            local rel = vim.fs.relpath(self._root, full_path)
            -- No need to stat files or non-followed links
            if rel and self:_should_include(rel, is_dir) then
                ---@type loop.FileTree.ProcessDirEntry
                local entry = {
                    name = name,
                    is_dir = is_dir,
                    is_link = is_link,
                }
                table.insert(resolved, entry)
            end
        end
        pending = pending - 1
        if pending == 0 then callback(resolved) end
    end

    local reload_counter = self._reload_counter
    for _, entry in ipairs(prep_entries) do
        local full_path = vim.fs.joinpath(path, entry.name)
        if entry.type == "link" and self._follow_symlinks then
            ---@diagnostic disable-next-line: undefined-field
            vim.uv.fs_stat(full_path, function(err, stat)
                vim.schedule(function() -- processing inside libuv callback -> crash
                    if reload_counter ~= self._reload_counter then return end
                    -- If it's a link, we update is_dir based on the target
                    local is_dir = not err and stat and stat.type == "directory"
                    process_entry(full_path, entry.name, is_dir, true)
                end)
            end)
        else
            process_entry(full_path, entry.name, entry.type == "directory", entry.type == "link")
        end
    end
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
    vim.uv.fs_scandir(path, function(err, handle)
        vim.schedule(function() -- get out of the fast event context
            if reload_counter ~= self._reload_counter then return end
            if req_id ~= data.childrenload_req_id then return end
            local prep_entries = {} ---@type loop.FileTree.PrepareDirEntry[]
            if handle then
                while true do
                    ---@diagnostic disable-next-line: undefined-field
                    local name, type = vim.uv.fs_scandir_next(handle)
                    if not name then break end
                    local entry = { name = name, type = type } ---@type loop.FileTree.PrepareDirEntry
                    table.insert(prep_entries, entry)
                end
            end
            self:_prepare_dir_entries(path, prep_entries, function(resolved_entries)
                -- schedule because read_dir is called in a fast event context
                if reload_counter ~= self._reload_counter then return end
                if req_id ~= data.childrenload_req_id then return end
                self:_process_dir(path, resolved_entries, err ~= nil)
                data.children_loading = false
                if data.on_children_loaded then
                    data.on_children_loaded()
                    data.on_children_loaded = nil
                end
                -- Handle nested expansion for existing expanded folders
                -- This ensures that if a folder was already expanded, we refresh its view too
                if recursive then
                    for _, child in ipairs(self._tree:get_children(path)) do
                        ---@type loop.comp.FileTree.ItemData
                        local child_data = child.data
                        local child_path = child_data.path
                        ---@type loop.comp.FileTree.ItemData
                        if child_data.is_dir then
                            -- it's important to load non-expanded nodes,
                            -- otherwise it will load the whole tree and we may have infinite recursion with symlinks
                            if child.expandable and child.expanded then
                                self:_read_dir(child_path, reload_counter, recursive)
                            end
                        end
                    end
                end
            end)
        end)
    end)
end

--@param path string
---@param entries loop.FileTree.ProcessDirEntry[]
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
    local new_entries_map = {} ---@type table<string, loop.FileTree.UpsetSingleItemArgs>
    for _, entry in ipairs(entries) do
        local full_path = vim.fs.joinpath(path, entry.name)
        local rel = vim.fs.relpath(root, full_path)
        if rel and self:_should_include(rel, entry.is_dir) then
            new_entries_map[full_path] = {
                parent_path = path,
                full_path = full_path,
                name = entry.name,
                loname = entry.name:lower(),
                is_dir = entry.is_dir,
                is_link = entry.is_link,
            }
        end
    end

    -- Identify and remove children that are no longer present
    local current_children = self._tree:get_children(path)
    for _, child in ipairs(current_children) do
        if not new_entries_map[child.id] then
            self._tree:remove_item(child.id)
        end
    end

    local children = {} ---@type loop.comp.TreeBuffer.ItemDef[]
    for _, entry in pairs(new_entries_map) do
        -- Prepare the new item definition
        local icon, icon_hl = self:_get_icon_for_node(entry.name, entry.is_dir, entry.is_link)
        ---@type loop.comp.TreeBuffer.ItemDef
        local child = {
            id = entry.full_path,
            expandable = entry.is_dir,
            expanded = entry.is_dir and self._expanded_lru:has(entry.full_path),
            data = {
                path = entry.full_path,
                name = entry.name,
                loname = entry.loname,
                is_dir = entry.is_dir,
                is_link = entry.is_link,
                icon = icon,
                icon_hl = icon_hl
            }
        }
        table.insert(children, child)
    end

    if #current_children > 0 then
        -- sort in reverse order them to improve the performance of _upsert_single_item
        table.sort(children, function(a, b)
            if a.data.is_dir ~= b.data.is_dir then return a.data.is_dir end
            return a.data.loname > b.data.loname -- reverse order
        end)
        for _, child in ipairs(children) do
            local item = self:_upsert_single_item(path, child)
        end
    else
        -- set children directly
        table.sort(children, function(a, b)
            if a.data.is_dir ~= b.data.is_dir then return a.data.is_dir end
            return a.data.loname < b.data.loname
        end)
        self._tree:set_children(path, children)
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
        self._last_selection_id = parent
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
                --vim.notify("validating " .. rel)
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
                local ok, err = vim.uv.fs_mkdir(new_path, 493) -- 493 is octal 0755
                if ok then
                    self:_read_dir(base_dir, self._reload_counter, false)
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
                --vim.notify("validating " .. rel)
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
            local ok, err = vim.uv.fs_rename(old_path, new_path)
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
    uitools.confirm_action(("Permanently delete %s?\n%s"):format(type_str, path), false, function(confirmed)
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
    if not item.data.is_dir or item.data.is_link then
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
    uitools.confirm_action("Permanently delete directory and all its contents?\n" .. path, false, function(confirmed)
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

function FileTree:set_persistent_state(state)
    self._expanded_lru:clear()

    if type(state) ~= "table" then return end
    if type(state.root) ~= "string" then return end
    if type(state.expanded) ~= "table" then return end

    local root = vim.fs.normalize(state.root)
    for _, rel in ipairs(state.expanded) do
        if type(rel) == "string" then
            local full_path = vim.fs.joinpath(root, rel)
            self._expanded_lru:put(full_path, true)
        end
    end
    if type(state.current) == "string" then
        if not self._tree:set_cursor_by_id(state.current) then
            self._pending_selection = state.current
        end
    end
end

function FileTree:get_persistent_state()
    local root = self._root
    if not root then
        return { root = nil, expanded = {} }
    end
    local expanded = {}
    for path, _ in self._expanded_lru:items() do
        local rel = vim.fs.relpath(root, path)
        if rel then
            table.insert(expanded, rel)
        end
    end
    local cursor_item = self._tree:get_cursor_item()
    if cursor_item and cursor_item.id then
        self._last_saved_cursor = cursor_item.id
    end
    return {
        root = root,
        current = self._last_saved_cursor,
        expanded = expanded,
    }
end

return FileTree
