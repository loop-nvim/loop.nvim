local loopconfig  = require("loop").config
local class       = require("loop.tools.class")
local uitools     = require("loop.tools.uitools")
local filetools   = require("loop.tools.file")
local TreeBuffer  = require("loop.buf.TreeBuffer")
local wsmonitor   = require("loop.workspacemonitor")
local LRU         = require("loop.tools.LRU")
local floatwin    = require("loop.tools.floatwin")

local uv          = vim.loop

---@class loop.comp.FileTree.ItemData
---@field path string
---@field name string
---@field is_dir boolean
---@field icon string
---@field icon_hl string
---@field is_current boolean?
---@field on_children_loaded fun()?

---@alias loop.comp.FileTree.ItemDef loop.comp.TreeBuffer.ItemData

-- at the top of your file
local _dev_icons_attempt, devicons
local _file_icons = {
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

--- Helper to check if a path is inside another directory
---@param path string The path to check
---@param root string The potential parent directory
---@return boolean
local function _is_subpath(path, root)
    if path == root then return true end
    -- Ensure root ends with a separator for prefix matching
    local prefix = root:sub(-1) == "/" and root or root .. "/"
    return path:find(prefix, 1, true) == 1
end

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
    return {
        { data.icon, data.icon_hl },
        { " " },
        { data.name, data.is_current and "Type" or nil }
    }, {}
end

---@class loop.comp.FileTree
---@field new fun(self:loop.comp.FileTree):loop.comp.FileTree
local FileTree = class()

function FileTree:init()
    self._expanded_lru = LRU:new(1000)

    self._monitor_lru = LRU:new(loopconfig.filetree.max_monitored_folders, {
        on_removed = function(path, cancel_fn)
            --vim.notify("removing monitor: " .. path)
            cancel_fn()
        end
    })

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
            uitools.smart_open_file(data.path)
        end,
        on_toggle = function(id, data, expanded)
            if data.is_dir then
                if expanded then
                    self._expanded_lru:put(data.path, true)
                    self:_attach_monitor(data.path)
                    -- MANUALLY TRIGGER LOAD
                    self:_read_dir(data.path)
                else
                    self._expanded_lru:delete(data.path)
                    self:_stop_monitor(data.path)
                end
            end
        end
    })
end

function FileTree:_on_buffer_create()
    assert(not self.bufenter_autocmd_id)
    assert(not self._workspace_tracker)
    local on_buffer_enter = function()
        if self._tree:get_buf() == -1 then
            return
        end
        local buf = vim.api.nvim_get_current_buf()
        if uitools.is_regular_buffer(buf) then
            local path = vim.api.nvim_buf_get_name(buf)
            if path ~= "" then
                self:reveal(path, loopconfig.filetree.track_current_file.auto_collapse_others)
            end
        end
    end
    if loopconfig.filetree.track_current_file.enabled then
        self.bufenter_autocmd_id = vim.api.nvim_create_autocmd("BufEnter", {
            callback = on_buffer_enter,
        })
    end
    self:_init_workspace_tracker()
end

function FileTree:_on_buffer_delete()
    self:_clear_all_monitors()
    self:_stop_workspace_tracker()
    if self.bufenter_autocmd_id then
        vim.api.nvim_del_autocmd(self.bufenter_autocmd_id)
        self.bufenter_autocmd_id = nil
    end
end

---@private
function FileTree:_setup_keymaps()
    local function with_item(fn)
        local item = self._tree:get_cursor_item()
        if item then fn(item) end
    end

    self._tree:add_keymap("a", {
        desc = "Create File",
        callback = function() with_item(function(i) self:_create_node(i, false) end) end
    })
    self._tree:add_keymap("A", {
        desc = "Create Directory",
        callback = function() with_item(function(i) self:_create_node(i, true) end) end
    })
    self._tree:add_keymap("i", {
        desc = "Create File",
        callback = function() with_item(function(i) self:_create_node(i, false) end) end
    })
    self._tree:add_keymap("I", {
        desc = "Create Directory",
        callback = function() with_item(function(i) self:_create_node(i, true) end) end
    })
    self._tree:add_keymap("r", {
        desc = "Rename",
        callback = function() with_item(function(i) self:_rename_node(i) end) end
    })
    self._tree:add_keymap("c", {
        desc = "Rename",
        callback = function() with_item(function(i) self:_rename_node(i) end) end
    })
    self._tree:add_keymap("d", {
        desc = "Delete",
        callback = function() with_item(function(i) self:_delete_node(i, "file") end) end
    })
    self._tree:add_keymap("D", {
        desc = "Delete folder",
        callback = function() with_item(function(i) self:_delete_node(i, "folder") end) end
    })
end

function FileTree:_init_workspace_tracker()
    ---@param wsdir string?
    ---@param config loop.WorkspaceConfig?
    local function reload(wsdir, config)
        vim.schedule(function()
            self:_reload(config and config.name,
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

--- Internal helper to stop a specific monitor
---@param path string
function FileTree:_stop_monitor(path)
    self._monitor_lru:delete(path)
end

--- Internal helper to stop all monitors under a specific path
---@param root string The directory path to clear sub-monitors for
---@param root_exclusive boolean If true, the 'root' monitor itself is kept; only children are cleared.
function FileTree:_clear_branch_monitors(root, root_exclusive)
    local to_stop = {}
    -- Identify which active monitors are children of 'root'
    for monitored_path, _ in self._monitor_lru:items() do
        local is_match = _is_subpath(monitored_path, root)
        if root_exclusive and monitored_path == root then
            is_match = false
        end
        if is_match then
            table.insert(to_stop, monitored_path)
        end
    end
    -- Stop them using the established helper to maintain the queue
    for _, path in ipairs(to_stop) do
        self:_stop_monitor(path)
    end
end

--- Internal helper to stop everything
function FileTree:_clear_all_monitors()
    self._monitor_lru:clear()
end

---@param path string
function FileTree:_attach_monitor(path)
    if self._monitor_lru:has(path) then return end
    -- Start the monitor
    local cancel_fn = filetools.monitor_dir(path, function(fname, status)
        local full_path = vim.fs.joinpath(path, fname)
        vim.schedule(function()
            if self._tree:get_buf() ~= -1 then
                self:_handle_fs_change(full_path, status)
            end
        end)
    end)
    if cancel_fn then
        --vim.notify("adding monitor: " .. path)
        self._monitor_lru:put(path, cancel_fn)
    end
end

---@param name string?
---@param root string?
---@param include_globs string[]?
---@param exclude_gobs string[]?
function FileTree:_reload(name, root, include_globs, exclude_gobs)
    self._reload_counter = self._reload_counter + 1
    self._tree:clear_items()
    self:_clear_all_monitors()

    if not name or not root or not include_globs or not exclude_gobs then
        local error_msg = root and "Workspace configuration error" or "No open workspace"
        local root_item = {
            id = "error_node",
            data = { path = "", name = error_msg, is_dir = false, icon = "⚠", icon_hl = "ErrorMsg" }
        }
        self._tree:add_item(nil, root_item)
        return
    end

    self._root = vim.fs.normalize(root)
    self._include_patterns = _compile_globs(include_globs)
    self._exclude_patterns = _compile_globs(exclude_gobs)

    local path = self._root
    local root_item = {
        id = path,
        expandable = true,
        expanded = true,
        data = {
            path = path,
            name = vim.fn.fnamemodify(path, ":t"),
            is_dir = true,
            icon = "",
            icon_hl = "Directory"
        }
    }

    self._tree:add_item(nil, root_item)
    self:_attach_monitor(path)
    -- START LOADING ROOT
    self:_read_dir(path)
end

---@param dir string
function FileTree:_reload_dir(dir)
    dir = vim.fs.normalize(dir)
    local item = self._tree:get_item(dir)
    if not item then return end

    self:_clear_branch_monitors(dir, true)
    -- RE-READ MANUALLY
    self:_read_dir(dir)
end

---@param path string Full path to the changed file/dir
---@param status table|nil optional status from uv.fs_event
function FileTree:_handle_fs_change(path, status)
    path = vim.fs.normalize(path)
    --vim.notify(("fs_change (%s): %s"):format(vim.inspect(status), path))
    -- If the changed path is a directory, refresh it.
    -- If it's a file, refresh its parent to catch additions/deletions/renames.
    local parent = vim.fn.fnamemodify(path, ":h")
    self:_reload_dir(parent)
end

---@param path string
function FileTree:_read_dir(path)
    -- Asynchronous scandir
    ---@diagnostic disable-next-line: undefined-field
    uv.fs_scandir(path, function(err, handle)
        if err or not handle then return end

        local entries = {}
        while true do
            ---@diagnostic disable-next-line: undefined-field
            local name, type = uv.fs_scandir_next(handle)
            if not name then break end
            table.insert(entries, { name = name, type = type })
        end

        vim.schedule(function()
            if not _dev_icons_attempt then
                _dev_icons_attempt = true
                local loaded, res = pcall(require, "nvim-web-devicons")
                if loaded then devicons = res end
            end

            local children = {}
            for _, entry in ipairs(entries) do
                local full = vim.fs.joinpath(path, entry.name)
                local is_dir = entry.type == "directory"
                local rel = vim.fs.relpath(self._root, full)

                if rel and self:_should_include(rel, is_dir) then
                    local icon, icon_hl
                    if is_dir then
                        icon, icon_hl = "", "Directory"
                    else
                        local ext = entry.name:match("%.([^.]+)$") or ""
                        if devicons then
                            icon, icon_hl = devicons.get_icon(entry.name, ext, { default = false })
                        end
                        icon = icon or _file_icons[ext] or ""
                        icon_hl = icon_hl or nil
                    end

                    table.insert(children, {
                        id = full,
                        expandable = is_dir,
                        expanded = self._expanded_lru:has(full),
                        data = {
                            path = full,
                            name = entry.name,
                            is_dir = is_dir,
                            icon = icon,
                            icon_hl = icon_hl
                        }
                    })
                end
            end

            table.sort(children, function(a, b)
                if a.data.is_dir ~= b.data.is_dir then return a.data.is_dir end
                return a.data.name:lower() < b.data.name:lower()
            end)

            -- PUSH TO TREE
            self._tree:set_children(path, children)

            -- Handle nested expansion
            for _, child in ipairs(children) do
                if child.expanded and child.data.is_dir then
                    self:_read_dir(child.id)
                end
            end

            -- Notify reveal waiters
            local parent = self._tree:get_item(path)
            if parent and parent.data.on_children_loaded then
                parent.data.on_children_loaded()
                parent.data.on_children_loaded = nil
            end
        end)
    end)
end

-- async reveal
---@param path string
---@param collapse_others boolean?
function FileTree:reveal(path, collapse_others)
    if not self._root then return end
    if not path or path == "" then return end

    if collapse_others then
        -- Collapse everything that isn't a parent of the target path
        local items = self._tree:get_items()
        for _, item in ipairs(items) do
            -- Don't collapse the root and don't collapse if the item is a parent of our target
            -- We check if 'id' is a prefix of 'path'
            if item.id ~= self._root and item.expanded then
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
    local root = self._root
    local rel = vim.fs.relpath(self._root, path)
    if not rel then
        return
    end
    local parts = rel ~= "" and vim.split(rel, "/", { plain = true }) or {}
    self._reveal_counter = self._reveal_counter + 1
    local current_request = self._reveal_counter
    self:_reveal_step(root, parts, 1, current_request)
end

---@param parent string The current directory path we are looking inside
---@param parts string[] The split segments of the relative path to the target
---@param idx number The current index in parts we are looking for
---@param token number
function FileTree:_reveal_step(parent, parts, idx, token)
    if token ~= self._reveal_counter then return end

    if idx > #parts then
        self._tree:set_cursor_by_id(parent)
        local data = self._tree:get_item(parent)
        if data then
            self._last_revealed_id = parent
            data.data.is_current = true
            self._tree:refresh_item(parent)
        end
        return
    end

    local next_path = vim.fs.joinpath(parent, parts[idx])
    local parent_item = self._tree:get_item(parent)
    if not parent_item then return end

    local function continue()
        self:_reveal_step(next_path, parts, idx + 1, token)
    end

    -- If already expanded, just go to next step
    if parent_item.expanded then
        continue()
        return
    end

    -- Hook into the read completion
    parent_item.data.on_children_loaded = vim.schedule_wrap(continue)
    self._tree:expand(parent)
end

---@param collapse_others boolean?
function FileTree:reveal_current_file(collapse_others)
    local buf = vim.api.nvim_get_current_buf()
    if uitools.is_regular_buffer(buf) then
        local path = vim.api.nvim_buf_get_name(buf)
        if path ~= "" then
            self:reveal(path, collapse_others)
        end
    end
end

--- Create a new file or directory
---@param item table The parent or sibling item
---@param as_dir boolean
function FileTree:_create_node(item, as_dir)
    -- Determine base directory: if item is file, use its parent. If dir, use it.
    local path = item.data.path
    local base_dir = item.data.is_dir and item.data.path or vim.fn.fnamemodify(item.data.path, ":h")
    local type_label = as_dir and "Directory" or "File"

    local reload_counter = self._reload_counter
    floatwin.input_at_cursor({ prompt = "New " .. type_label .. " name" }, function(name)
        if not name or name == "" then return end
        if reload_counter ~= self._reload_counter then return end
        if not self._tree:get_item(path) then return end

        local new_path = vim.fs.joinpath(base_dir, name)
        if as_dir then
            ---@diagnostic disable-next-line: undefined-field
            local ok, err = uv.fs_mkdir(new_path, 493) -- 493 is octal 0755
            if not ok then vim.notify(err, vim.log.levels.ERROR) end
        else
            ---@diagnostic disable-next-line: undefined-field
            local fd, err = uv.fs_open(new_path, "w", 420) -- 420 is octal 0644
            if fd then
                ---@diagnostic disable-next-line: undefined-field
                uv.fs_close(fd)
            else
                vim.notify("Could not create file, " .. tostring(err), vim.log.levels.ERROR)
            end
        end
        self:reveal(new_path)
    end)
end

--- Rename a file or directory
---@param item table
function FileTree:_rename_node(item)
    local old_path = item.data.path
    local old_name = item.data.name
    local parent_dir = vim.fn.fnamemodify(old_path, ":h")

    local reload_counter = self._reload_counter
    floatwin.input_at_cursor({
            prompt = ("Rename `%s`"):format(old_name),
            default_text = old_name
        },
        function(new_name)
            if not new_name or new_name == "" then return end
            if reload_counter ~= self._reload_counter then return end
            if not self._tree:get_item(old_path) then return end
            local new_path = vim.fs.joinpath(parent_dir, new_name)
            ---@diagnostic disable-next-line: undefined-field
            local ok, err = uv.fs_rename(old_path, new_path)
            if not ok then
                vim.notify("Rename failed: " .. err, vim.log.levels.ERROR)
            end
        end)
end

--- Delete a file or directory only if it matches the wanted type
---@param item table The TreeBuffer item
---@param wanted "file"|"folder"
function FileTree:_delete_node(item, wanted)
    -- Check if the item type matches the 'wanted' type
    local is_folder = item.data.is_dir
    if (wanted == "folder" and not is_folder) or (wanted == "file" and is_folder) then
        return
    end
    local path = item.data.path
    if path == self._root then
        vim.notify("Cannot delete workspace root")
        return
    end
    local type_str = is_folder and "directory" or "file"
    local reload_counter = self._reload_counter
    -- Confirmation dialog
    local confirm = uitools.confirm_action(("Delete %s?\n%s"):format(type_str, path), false, function(confirmed)
        if not confirmed then return end
        if reload_counter ~= self._reload_counter then return end
        if not self._tree:get_item(path) then return end
        -- Attempt simple removal
        local success, err_msg = os.remove(path)
        if not success then
            vim.notify(("Failed to delete %s\n%s"):format(type_str, err_msg), vim.log.levels.ERROR)
        end
    end)
end

return FileTree
