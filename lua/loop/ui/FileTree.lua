local class      = require("loop.tools.class")
local uitools    = require("loop.tools.uitools")
local TreeBuffer = require("loop.buf.TreeBuffer")
local wsmonitor  = require("loop.workspacemonitor")


local uv         = vim.loop

---@class loop.comp.FileTree.ItemData
---@field path string
---@field name string
---@field is_dir boolean
---@field icon string
---@field icon_hl string
---@field on_children_loaded fun()?

---@alias loop.comp.FileTree.ItemDef loop.comp.TreeBuffer.ItemData

-- at the top of your file
local _dev_icons_attempt, devicons
local file_icons = {
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

---@class loop.comp.FileTree
---@field new fun(self:loop.comp.FileTree):loop.comp.FileTree
local FileTree = class()

function FileTree:init()
    self._tree = TreeBuffer:new({
        formatter = function(id, data)
            return self:_file_formatter(id, data)
        end,
        base_opts = {
            name = "Workspace Files",
            filetype = "loop-filetree",
            listed = false,
            wipe_when_hidden = true,
        }
    })


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

    local function on_buffer_create()
        assert(not self.bufenter_autocmd_id)
        assert(not self._workspace_tracker)
        self.bufenter_autocmd_id = vim.api.nvim_create_autocmd("BufEnter", {
            callback = function()
                if self._tree:get_buf() == -1 then
                    return
                end
                local buf = vim.api.nvim_get_current_buf()
                if uitools.is_regular_buffer(buf) then
                    local path = vim.api.nvim_buf_get_name(buf)
                    if path ~= "" then
                        self:reveal(path, true)
                    end
                end
            end
        })
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

    local function on_buffer_delete()
        if self.bufenter_autocmd_id then
            vim.api.nvim_del_autocmd(self.bufenter_autocmd_id)
            self.bufenter_autocmd_id = nil
        end
        if self._workspace_tracker then
            self._workspace_tracker:cancel()
            self._workspace_tracker = nil
            --vim.notify("(loop.nvim) tracker cleanup")
        end
    end


    self._tree:add_tracker({
        on_create = function()
            on_buffer_create()
        end,
        on_delete = function()
            on_buffer_delete()
        end,
        on_selection = function(id, data)
            uitools.smart_open_file(data.path)
        end,
    })

    self._reveal_counter = 0
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

---@param name string?
---@param root string?
---@param include_globs string[]?
---@param exclude_gobs string[]?
function FileTree:_reload(name, root, include_globs, exclude_gobs)
    self._tree:clear_items()
    if not name or not root or not include_globs or not exclude_gobs then
        local error_msg = root and "Workspace configuration error" or "No open workspace"
        ---@type loop.comp.TreeBuffer.ItemDef
        local root_item = {
            id = {},
            data = {
                path = "",
                name = error_msg,
                is_dir = false,
                icon = "⚠",
                icon_hl = "ErrorMsg"
            }
        }
        self._tree:add_item(nil, root_item)
        return
    end

    self._root = vim.fs.normalize(root)
    self._include_patterns = _compile_globs(include_globs)
    self._exclude_patterns = _compile_globs(exclude_gobs)

    local path = self._root

    ---@type loop.comp.TreeBuffer.ItemDef
    local root_item = {
        id = path,
        expanded = true,
        data = {
            path = path,
            name = vim.fn.fnamemodify(path, ":t"),
            is_dir = true,
            icon = "",
            icon_hl = "Directory"
        }
    }

    root_item.children_callback = function(cb)
        self:_read_dir(path, cb)
    end

    self._tree:add_item(nil, root_item)
end

---@param id string
---@param data loop.comp.FileTree.ItemData
function FileTree:_file_formatter(id, data)
    if not data then return {}, {} end
    return {
        { data.icon, data.icon_hl },
        { " " },
        { data.name }
    }, {}
end

function FileTree:_read_dir(path, cb)
    ---@diagnostic disable-next-line: undefined-field
    local handle, err = uv.fs_scandir(path)
    if not handle then
        vim.schedule(function() cb({}) end)
        return
    end

    local entries = {}

    -- In luv, the handle is closed automatically when uv.fs_scandir_next
    -- returns nil. To "fix" a leak, we just ensure we always exhaust it.
    local success, err_next = pcall(function()
        while true do
            ---@diagnostic disable-next-line: undefined-field
            local name, type = uv.fs_scandir_next(handle)
            if not name then break end
            table.insert(entries, { name = name, type = type })
        end
    end)

    if not success then
        -- If something went wrong during iteration, we still want to
        -- provide what we found or an empty list.
        print("Error during scan: " .. tostring(err_next))
    end

    vim.schedule(function()
        local children = {}
        -- Optimization: Load devicons once per directory scan
        if not _dev_icons_attempt then
            _dev_icons_attempt = true
            local loaded, res = pcall(require, "nvim-web-devicons")
            if loaded then devicons = res end
        end

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
                        local d_icon, d_hl = devicons.get_icon(entry.name, ext, { default = false })
                        icon = d_icon or ""
                        icon_hl = d_hl or "Normal"
                    else
                        icon = file_icons[ext] or ""
                        icon_hl = "Normal"
                    end
                end

                local item = {
                    id = full,
                    parent_id = path,
                    expanded = false,
                    data = {
                        path = full,
                        name = entry.name,
                        is_dir = is_dir,
                        icon = icon,
                        icon_hl = icon_hl
                    }
                }
                if is_dir then
                    item.children_callback = function(c) self:_read_dir(full, c) end
                end
                table.insert(children, item)
            end
        end

        table.sort(children, function(a, b)
            if a.data.is_dir ~= b.data.is_dir then return a.data.is_dir end
            return a.data.name:lower() < b.data.name:lower()
        end)

        cb(children)

        -- Notify reveal waiters
        local parent = self._tree:get_item(path)
        if parent then
            parent.data.children_loaded = true
            if parent.data.on_children_loaded then
                parent.data.on_children_loaded()
                parent.data.on_children_loaded = nil
            end
        end
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
    if token ~= self._reveal_counter then return end -- Abort stale request
    -- Base Case: We've reached the end of the path parts
    if idx > #parts then
        self._tree:set_cursor_by_id(parent)
        return
    end

    local next_path = vim.fs.joinpath(parent, parts[idx])
    local parent_item = self._tree:get_item(parent)

    -- Safety: If the parent doesn't exist in the tree, we can't go deeper
    if not parent_item then
        return
    end

    ---@param children loop.comp.FileTree.ItemDef[]|nil
    local function continue(children)
        -- Verify the target child actually exists in this directory.
        -- If 'children' is nil, it means the item was already expanded,
        -- so we check the TreeBuffer directly.
        self:_reveal_step(next_path, parts, idx + 1, token)
    end

    -- If already expanded, we don't need to wait for a callback
    if parent_item.expanded then
        continue(nil)
        return
    end

    if parent_item.data.children_loaded then
        self._tree:expand(parent)
        continue()
        return
    end

    -- Register the waiter before expanding to get notified when children are loaded
    parent_item.data.on_children_loaded = vim.schedule_wrap(function()
        continue()
    end)
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

return FileTree
