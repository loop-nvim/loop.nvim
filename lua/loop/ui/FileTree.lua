local class      = require("loop.tools.class")
local uitools    = require("loop.tools.uitools")
local TreeBuffer = require("loop.buf.TreeBuffer")

local uv         = vim.loop

---@class loop.comp.FileTree.ItemData
---@field path string
---@field name string
---@field is_dir boolean
---@field _children_waiters fun(children:loop.comp.FileTree.ItemDef[])[]?

---@alias loop.comp.FileTree.ItemDef loop.comp.ItemTree.ItemDef

---@class loop.comp.FileTreeOpts
---@field root string
---@field include_globs string[]
---@field exclude_globs string[]

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

---@class loop.comp.FileTree : loop.comp.ItemTree
---@field new fun(self:loop.comp.FileTree,opts:loop.comp.FileTreeOpts):loop.comp.FileTree
local FileTree   = class()

---@param opts loop.comp.FileTreeOpts
function FileTree:init(opts)
    vim.validate("opts", opts, "table")
    vim.validate("opts.root", opts.root, "string")

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

    self._tree:add_tracker({
        on_create = function()
            vim.notify("Autocmd created")
            self.bufenter_autocmd_id = vim.api.nvim_create_autocmd("BufEnter", {
                callback = function()
                    local buf = vim.api.nvim_get_current_buf()
                    if uitools.is_regular_buffer(buf) then
                        local path = vim.api.nvim_buf_get_name(buf)
                        if path ~= "" then
                            self:reveal(path)
                        end
                    end
                end
            })
        end,
        on_delete = function()
            if self.bufenter_autocmd_id then
                vim.api.nvim_del_autocmd(self.bufenter_autocmd_id)
                self.bufenter_autocmd_id = nil
                vim.notify("Autocmd deleted")
            end
        end,
        on_selection = function(id, data)
            uitools.smart_open_file(data.path)
        end,
    })

    self.root = vim.fs.normalize(opts.root)
    self._include_patterns = self:_compile_globs(opts.include_globs)
    self._exclude_patterns = self:_compile_globs(opts.exclude_globs)

    self:_set_root(self.root)
end

---@return loop.comp.BaseBuffer
function FileTree:get_compbuffer()
    return self._tree
end

---@param globs string[]|nil
---@return string[]|nil
function FileTree:_compile_globs(globs)
    if not globs or #globs == 0 then
        return nil
    end

    local compiled = {}
    for _, g in ipairs(globs) do
        table.insert(compiled, vim.fn.glob2regpat(g))
    end
    return compiled
end

---@param path string
---@param patterns string[]|nil
---@return boolean
function FileTree:_match_patterns(path, patterns)
    if not patterns then
        return false
    end

    for i = 1, #patterns do
        if vim.fn.match(path, patterns[i]) ~= -1 then
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

function FileTree:_set_root(path)
    self._tree:clear_items()

    ---@type loop.comp.TreeBuffer.ItemDef
    local root_item = {
        id = path,
        expanded = true,
        data = {
            path = path,
            name = vim.fn.fnamemodify(path, ":t"),
            is_dir = true
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
    if not data then
        return {}, {}
    end
    local chunks = {}
    local icon, icon_hl, text_hl
    if data.is_dir then
        icon = " "
        icon_hl = "Directory"
        text_hl = icon_hl
    else
        local ext = data.name:match("%.([^.]+)$")
        if not _dev_icons_attempt then
            local loaded
            loaded, devicons = pcall(require, "nvim-web-devicons")
            if not loaded then devicons = nil end
        end
        -- try devicons first
        if devicons then
            local devicon_icon, devicon_hl = devicons.get_icon(data.name, ext, { default = false })
            if devicon_icon then
                icon = devicon_icon
                icon_hl = devicon_hl or "Normal"
            else
                icon = file_icons[ext] or file_icons.default
                icon_hl = "Normal"
            end
        else
            icon = file_icons[ext] or file_icons.default
            icon_hl = "Normal"
        end
    end
    table.insert(chunks, { icon, icon_hl })
    table.insert(chunks, { " " })
    table.insert(chunks, { data.name, text_hl })
    return chunks, {}
end

-- register listener for when a directory's children are loaded
function FileTree:_on_children_loaded(item, fn)
    local data = item.data
    data._children_waiters = data._children_waiters or {}
    table.insert(data._children_waiters, fn)
end

---@param path string
---@param cb fun(items:loop.comp.FileTree.ItemDef[])
function FileTree:_read_dir(path, cb)
    ---@diagnostic disable-next-line: undefined-field
    local handle = uv.fs_scandir(path)
    local children = {}

    if not handle then
        cb(children)
        return
    end

    while true do
        ---@diagnostic disable-next-line: undefined-field
        local name, type = uv.fs_scandir_next(handle)
        if not name then break end

        local full = vim.fs.joinpath(path, name)
        local is_dir = type == "directory"
        local rel = vim.fs.relpath(self.root, full)
        if not rel then
            vim.notify_once("directory scanning error")
            goto continue
        end
        if self:_should_include(rel, is_dir) then
            ---@type loop.comp.FileTree.ItemDef
            local item = {
                id = full,
                parent_id = path,
                expanded = false,
                data = {
                    path = full,
                    name = name,
                    is_dir = is_dir
                }
            }

            if is_dir then
                item.children_callback = function(cb2)
                    self:_read_dir(full, cb2)
                end
            end

            table.insert(children, item)
        end
        ::continue::
    end

    table.sort(children, function(a, b)
        if a.data.is_dir ~= b.data.is_dir then
            return a.data.is_dir
        end
        return a.data.name < b.data.name
    end)

    cb(children)

    -- notify listeners waiting for this directory
    local parent = self._tree:get_item(path)
    if parent then
        local waiters = parent.data._children_waiters
        if waiters then
            parent.data._children_waiters = nil
            for _, fn in ipairs(waiters) do
                fn(children)
            end
        end
    end
end

-- async reveal
function FileTree:reveal(path)
    if not path or path == "" then
        return
    end
    path = vim.fs.normalize(path)
    local root = self.root
    local rel = vim.fs.relpath(self.root, path)
    if not rel then
        return
    end
    -- 1. Collapse everything that isn't a parent of the target path
    local items = self._tree:get_items()
    for _, item in ipairs(items) do
        -- Don't collapse the root and don't collapse if the item is a parent of our target
        -- We check if 'id' is a prefix of 'path'
        if item.id ~= self.root and item.expanded then
            if not vim.startswith(path, item.id) then
                self._tree:collapse(item.id)
            end
        end
    end
    local parts = rel ~= "" and vim.split(rel, "/", { plain = true }) or {}
    self:_reveal_step(root, parts, 1)
end

function FileTree:_reveal_step(parent, parts, idx)
    if idx > #parts then
        self._tree:set_cursor_by_id(parent)
        return
    end

    local next_path = vim.fs.joinpath(parent, parts[idx])
    local parent_item = self._tree:get_item(parent)
    if not parent_item then return end

    local function continue()
        self:_reveal_step(next_path, parts, idx + 1)
    end

    if parent_item.expanded then
        continue()
        return
    end

    self:_on_children_loaded(parent_item, continue)
    self._tree:expand(parent)
end

function FileTree:open(path)
    path = vim.fs.normalize(path)
    self.root = path
    self:_set_root(path)
end

return FileTree
