local class        = require("loop.tools.class")
local uitools      = require("loop.tools.uitools")
local ItemTreeComp = require("loop.comp.ItemTree")

local uv           = vim.loop

---@class loop.comp.FileTree.ItemData
---@field path string
---@field name string
---@field is_dir boolean
---@field _children_waiters fun(children:loop.comp.FileTree.ItemDef[])[]?

---@alias loop.comp.FileTree.ItemDef loop.comp.ItemTree.ItemDef

---@class loop.comp.FileTree : loop.comp.ItemTree
---@field new fun(self:loop.comp.FileTree):loop.comp.FileTree
local FileTree     = class(ItemTreeComp)


-- formatter
---@param id string
---@param data loop.comp.FileTree.ItemData
local function _file_formatter(id, data)
    if not data then
        return {}, {}
    end

    local chunks = {}

    local icon = data.is_dir and " " or " "
    local hl = data.is_dir and "Directory" or "Normal"

    table.insert(chunks, { icon, hl })
    table.insert(chunks, { data.name, hl })

    return chunks, {}
end


function FileTree:init(root)
    ItemTreeComp.init(self, {
        formatter = _file_formatter
    })

    ---@diagnostic disable-next-line: undefined-field
    self.root = root or uv.cwd()

    self:_set_root(self.root)
end

function FileTree:_set_root(path)
    self:clear_items()

    ---@type loop.comp.FileTree.ItemDef
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

    self:add_item(nil, root_item)
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
    local handle = uv.fs_scandir(path)
    local children = {}

    if not handle then
        cb(children)
        return
    end

    while true do
        local name, type = uv.fs_scandir_next(handle)
        if not name then break end

        local full = path .. "/" .. name
        local is_dir = type == "directory"

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

    table.sort(children, function(a, b)
        if a.data.is_dir ~= b.data.is_dir then
            return a.data.is_dir
        end
        return a.data.name < b.data.name
    end)

    cb(children)

    -- notify listeners waiting for this directory
    local parent = self:get_item(path)
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
    local root = self.root
    if path:sub(1, #root) ~= root then
        return
    end

    local rel = path:sub(#root + 2)
    local parts = vim.split(rel, "/")

    self:_reveal_step(root, parts, 1)
end

function FileTree:_reveal_step(parent, parts, idx)
    if idx > #parts then
        --self:set_cursor_by_id(parent)
        return
    end

    local next_path = parent .. "/" .. parts[idx]
    local parent_item = self:get_item(parent)
    if not parent_item then return end

    local function continue()
        self:_reveal_step(next_path, parts, idx + 1)
    end

    if parent_item.expanded then
        continue()
        return
    end

    self:_on_children_loaded(parent_item, continue)
    self:expand(parent)
end

function FileTree:open(path)
    self:_set_root(path)
end

function FileTree:link_to_buffer(comp)
    ItemTreeComp.link_to_buffer(self, comp)
    self:add_tracker({
        on_selection = function(id, data)
            if data.is_dir then
                self:toggle_expand(id)
            else
                uitools.smart_open_file(data.path)
            end
        end
    })
end

function FileTree:dispose()
    ItemTreeComp.dispose(self)
end

return FileTree
