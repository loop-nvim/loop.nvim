local class = require('loop.tools.class')
local Tree = require("loop.tools.Tree")
local Trackers = require("loop.tools.Trackers")
local table_clear = require("table.clear")

---@class loop.comp.ItemTree.Item
---@field id any
---@field data any
---@field expanded boolean

---@alias loop.comp.ItemTree.ChildrenCallback fun(cb:fun(items:loop.comp.ItemTree.ItemDef[]))

---@class loop.comp.ItemTree.ItemDef
---@field id any
---@field data any
---@field children_callback loop.comp.ItemTree.ChildrenCallback?
---@field expanded boolean|nil

---@class loop.comp.ItemTree.ItemData
---@field userdata any
---@field children_callback loop.comp.ItemTree.ChildrenCallback?
---@field expanded boolean|nil
---@field reload_children boolean|nil
---@field children_loading boolean|nil
---@field load_sequence number
---@field is_loading boolean|nil
---@field _cached_output {text: any, virt: any}? -- Cache storage
---@field dirty boolean?                        -- Cache invalidation flag

---@class loop.comp.ItemTree.Tracker
---@field on_selection? fun(id:any,data:any)
---@field on_toggle? fun(id:any,data:any,expanded:boolean)

---@class loop.comp.ItemTree.VirtText
---@field text string
---@field highlight string

---@alias loop.comp.ItemTree.FormatterFn fun(id:any, data:any,expanded:boolean):string[][],string[][]

---@class loop.comp.ItemTree.InitArgs
---@field formatter loop.comp.ItemTree.FormatterFn
---@field expand_char string?
---@field collapse_char string?
---@field enable_loading_indictaor boolean?
---@field loading_char string?
---@field indent_string string?
---@field render_delay_ms number?
---@field header string[][]?

---@class loop.comp.ItemTree
local ItemTree = class()

local _ns_id = vim.api.nvim_create_namespace('LoopPluginItemTreeComp')

local _header_hl_group = "LoopItemTreeHeader"
vim.api.nvim_set_hl(0, _header_hl_group, {
    bg = (function()
        local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = "WinBar", link = false })
        if not ok then return nil end
        return hl.bg
    end)()
})

---@param item loop.comp.ItemTree.ItemDef
---@return loop.comp.ItemTree.ItemData
local function _itemdef_to_itemdata(item)
    return {
        userdata = item.data,
        children_callback = item.children_callback,
        expanded = item.expanded,
        reload_children = true,
        load_sequence = 1,
        dirty = true,
    }
end

---@param args loop.comp.ItemTree.InitArgs
function ItemTree:init(args)
    assert(args.formatter, "formatter is required")
    assert(not args.header or type(args.header) == "table", "header must be a table")


    ---@type loop.comp.ItemTree.FormatterFn
    self._formatter = args.formatter
    self._header = args.header ---@type string[][]?

    self._trackers = Trackers:new()

    self._expand_char = args.expand_char or "▶"
    self._collapse_char = args.collapse_char or "▼"
    self._loading_char = args.enable_loading_indictaor and (args.loading_char or "⧗") or nil
    self._indent_string = args.indent_string or "  "
    self._render_delay_ms = args.render_delay_ms or 150

    self._tree = Tree:new()
    self._flat = {} ---@type loop.tools.Tree.FlatNode[]

    -- Reusable scratchpads
    self._buffer_lines = {}
    self._extmarks_data = {}
    self._hl_calls = {}
    -- Pre-allocate indent cache
    self._indent_cache = {}
    for i = 0, 20 do
        self._indent_cache[i] = string.rep(args.indent_string or "  ", i)
    end
end

---@param tracker loop.comp.ItemTree.Tracker
function ItemTree:add_tracker(tracker) return self._trackers:add_tracker(tracker) end

---@param comp loop.CompBufferController
---@return any,any
function ItemTree:_get_cur_node(comp)
    local cursor = comp:get_cursor()
    if not cursor then return nil end
    local row = cursor[1]
    if self._header then
        if row == 1 then
            return nil
        end
        row = row - 1
    end

    local node = self._flat[row]

    if not node then return nil end
    return node.id, node.data
end

---@param buf_ctrl loop.CompBufferController
function ItemTree:link_to_buffer(buf_ctrl)
    -- Helper to get current node
    local function get_node()
        local id, data = self:_get_cur_node(buf_ctrl)
        if not id or not data then return nil end
        return id, data
    end

    -- Callbacks
    local callbacks = {
        on_enter = function()
            ---@type any,loop.comp.ItemTree.ItemData?
            local id, data = get_node()
            if id and data then
                if (self._tree:have_children(id) or data.children_callback) then
                    self:toggle_expand(id)
                else
                    self._trackers:invoke("on_selection", id, data.userdata)
                end
            end
        end,
        toggle = function()
            local id, data = get_node()
            if id and data and (self._tree:have_children(id) or data.children_callback) then
                self:toggle_expand(id)
            end
        end,
        expand = function()
            local id, data = get_node()
            if id and data and (self._tree:have_children(id) or data.children_callback) then
                self:expand(id)
            end
        end,

        collapse = function()
            local id, data = get_node()
            if id and data and (self._tree:have_children(id) or data.children_callback) then
                self:collapse(id)
            end
        end,

        expand_recursive = function()
            local id = get_node()
            if id then self:expand_all(id) end
        end,

        collapse_recursive = function()
            local id = get_node()
            if id then self:collapse_all(id) end
        end,
    }

    -- Attach buffer and renderer
    self._linked_buf = buf_ctrl
    self._linked_buf.set_renderer({
        render = function(bufnr) return self:_on_render_request(bufnr) end,
        dispose = function() return self:dispose() end
    })

    -- Keymap table: key → {callback, description}
    local keymaps = {
        ["<CR>"] = { callbacks.on_enter, "Expand/collapse" },
        ["<2-LeftMouse>"] = { callbacks.toggle, "Expand/collapse" },
        -- Non-recursive
        ["zo"] = { callbacks.expand, "Expand node under cursor" },
        ["zc"] = { callbacks.collapse, "Collapse node under cursor" },
        ["za"] = { callbacks.toggle, "Toggle node under cursor" },
        -- Recursive
        ["zO"] = { callbacks.expand_recursive, "Expand all nodes under cursor" },
        ["zC"] = { callbacks.collapse_recursive, "Collapse all nodes under cursor" },
    }

    -- Register keymaps
    for key, map in pairs(keymaps) do
        self._linked_buf.add_keymap(key, { callback = map[1], desc = map[2] })
    end

    self:_request_render()
end

function ItemTree:dispose() end

function ItemTree:set_cursor_by_id(id)
    if self._render_pending then
        self._pending_active_item_id = id
        return
    end
    if self._linked_buf and self._flat then
        for index, node in ipairs(self._flat) do
            if id == node.id then
                self._linked_buf.set_cursor(index)
                break
            end
        end
    end
end

---@return loop.comp.ItemTree.Item?
function ItemTree:get_cur_item()
    if self._linked_buf then
        local id, nodedata = self:_get_cur_node(self._linked_buf)
        if id and nodedata then
            return { id = id, data = nodedata.userdata }
        end
    end
end

---@param id any
---@return boolean
function ItemTree:have_item(id)
    return self._tree:have_item(id)
end

--- Is this node a root node? (has no parent)
---@return boolean
function ItemTree:is_root(id)
    return self._tree:is_root(id)
end

--- Get root nodes (same as get_children(nil) but maybe clearer name in some contexts)
function ItemTree:get_roots()
    return self._tree:get_roots()
end

--- Get the parent ID of a node (or nil if it's a root node)
---@param id any
---@return any|nil parent_id
function ItemTree:get_parent_id(id)
    return self._tree:get_parent_id(id)
end

---@return loop.comp.ItemTree.Item?
function ItemTree:get_item(id)
    local itemdata = self:_get_data(id)
    if not itemdata then return nil end
    return { id = id, data = itemdata.userdata, expanded = itemdata.expanded }
end

---@return loop.comp.ItemTree.Item?
function ItemTree:get_parent_item(id)
    local par_id = self._tree:get_parent_id(id)
    if not par_id then return nil end

    ---@type loop.comp.ItemTree.ItemData
    local itemdata = self._tree:get_data(par_id)
    if not itemdata then return nil end

    return { id = par_id, data = itemdata.userdata, expanded = itemdata.expanded }
end

function ItemTree:clear_items()
    self._tree = Tree:new()
    self:_request_render()
end

---@param parent_id any
---@param item loop.comp.ItemTree.ItemDef
function ItemTree:add_item(parent_id, item)
    local item_data = _itemdef_to_itemdata(item)
    self._tree:add_item(parent_id, item.id, item_data)
    if not self:_request_children(item.id, item_data) then
        self:_request_render()
    end
end

---@param parent_id any
---@param items loop.comp.ItemTree.ItemDef[]
function ItemTree:add_items(parent_id, items)
    for _, item in ipairs(items) do
        self._tree:add_item(parent_id, item.id, _itemdef_to_itemdata(item))
    end
end

---@param parent_id any
---@param children loop.comp.ItemTree.ItemDef[]
function ItemTree:set_children(parent_id, children)
    ---@type loop.tools.Tree.Item[]
    local baseitems = {}
    for _, child_item in ipairs(children) do
        ---@type loop.tools.Tree.Item
        local item = {
            id = child_item.id,
            data = _itemdef_to_itemdata(child_item)
        }
        table.insert(baseitems, item)
    end
    self._tree:set_children(parent_id, baseitems)
    self:_request_render()
    for _, item in ipairs(baseitems) do
        if item.data.children_callback then
            self:_request_children(item.id, item.data)
        end
    end
end

function ItemTree:set_item_data(id, data)
    ---@type loop.comp.ItemTree.ItemData?
    local base_data = self._tree:get_data(id)
    assert(base_data, "id not found: " .. tostring(id))
    base_data.userdata = data
    base_data.dirty = true
    self._tree:set_item_data(id, base_data)
    self:_request_render()
end

---@param callback nil|fun(cb:fun(items:loop.comp.ItemTree.ItemDef[]))
function ItemTree:set_children_callback(id, callback)
    ---@type loop.comp.ItemTree.ItemData?
    local base_data = self._tree:get_data(id)
    assert(base_data, "it not found: " .. tostring(id))
    base_data.children_callback = callback
    if base_data.children_callback then
        base_data.reload_children = true
        base_data.load_sequence = base_data.load_sequence + 1
    end
    self._tree:set_item_data(id, base_data)
    self:_request_children(id, base_data)
end

---@param item loop.comp.ItemTree.ItemDef
---@return boolean
function ItemTree:update_item(item)
    ---@type loop.comp.ItemTree.ItemData
    local existing = self._tree:get_data(item.id)
    if not existing then return false end
    existing.userdata = item.data
    existing.children_callback = item.children_callback
    if existing.children_callback then
        existing.reload_children = true
        existing.load_sequence = existing.load_sequence + 1
    else
        self._tree:remove_children(item.id)
    end
    if item.expanded ~= nil then
        existing.expanded = item.expanded
    end
    self:_request_render()
    return true
end

---@return loop.comp.ItemTree.Item[]
function ItemTree:get_children(parent_id)
    local items = {}
    local tree_items = self._tree:get_children(parent_id)

    for _, treeitem in ipairs(tree_items) do
        ---@type loop.comp.ItemTree.ItemData
        local data = treeitem.data
        ---@type loop.comp.ItemTree.Item
        local item = {
            id = treeitem.id,
            data = data.userdata,
            expanded = data.expanded
        }
        table.insert(items, item)
    end
    return items
end

function ItemTree:remove_items(ids)
    for _, id in ipairs(ids) do
        self._tree:remove_item(id)
    end
    self:_request_render()
    return true
end

function ItemTree:remove_item(id)
    self._tree:remove_item(id)
    self:_request_render()
    return true
end

function ItemTree:remove_children(id)
    self._tree:remove_children(id)
    self:_request_render()
    return true
end

function ItemTree:_request_render()
    if self._linked_buf then
        self._render_pending = true
        self._linked_buf.request_refresh()
    end
end

function ItemTree:_on_render_request(buf)
    self._render_pending = false
    table_clear(self._buffer_lines)
    table_clear(self._extmarks_data)
    table_clear(self._hl_calls)

    local t_insert = table.insert
    local s_rep = string.rep

    -- 1. HEADER RENDERING
    if self._header then
        local row = 0
        local left, right = self._header[1] or {}, self._header[2] or {}
        local line = left[1] or ""

        t_insert(self._buffer_lines, line)
        t_insert(self._extmarks_data, { row, 0, { line_hl_group = _header_hl_group } })

        if left[2] then
            t_insert(self._hl_calls, { hl = left[2], row = row, s_col = 0, e_col = #line })
        end
        if right[1] and #right[1] > 0 then
            t_insert(self._extmarks_data, { row, 0, {
                virt_text = { { right[1], right[2] } },
                virt_text_pos = "right_align",
                hl_mode = "combine",
            } })
        end
    end

    -- 2. FLATTEN TREE
    self._tree:flatten_into(self._flat, function(_, data) return data.expanded ~= false end)

    local indent_str = self._indent_string
    local expand_char, collapse_char, loading_char = self._expand_char, self._collapse_char, self._loading_char
    local expand_padding = s_rep(" ", vim.fn.strdisplaywidth(expand_char)) .. " "

    -- 3. NODE RENDERING
    for _, flatnode in ipairs(self._flat) do
        local item_id, item, depth = flatnode.id, flatnode.data, flatnode.depth
        local row = #self._buffer_lines

        -- Prefix Construction
        local icon = ""
        if item_id and (self._tree:have_children(item_id) or item.children_callback) then
            icon = (item.children_loading and loading_char) or (item.expanded and collapse_char) or expand_char
        end

        local indent = self._indent_cache[depth] or s_rep(indent_str, depth)
        local prefix = icon ~= "" and (indent .. icon .. " ") or (indent .. expand_padding)

        -- Cache/Formatter Logic
        if item.dirty or not item._cached_output then
            local text, virt = self._formatter(item_id, item.userdata, item.expanded)
            item._cached_output = { text = text, virt = virt }
            item.dirty = false
        end

        local text_chunks = item._cached_output.text
        local current_line = prefix
        local col = #prefix

        for i = 1, #text_chunks do
            local chunk = text_chunks[i]
            local txt, hl = chunk[1], chunk[2]
            local len = #txt
            if len > 0 then
                if hl then
                    t_insert(self._hl_calls, { hl = hl, row = row, s_col = col, e_col = col + len })
                end
                current_line = current_line .. txt
                col = col + len
            end
        end

        t_insert(self._buffer_lines, current_line)

        -- Virtual Text
        local virt = item._cached_output.virt
        if virt and #virt > 0 then
            t_insert(self._extmarks_data, { row, 0, { virt_text = virt, hl_mode = "combine" } })
        end
    end

    -- 4. BUFFER UPDATES
    vim.api.nvim_buf_clear_namespace(buf, _ns_id, 0, -1)
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, self._buffer_lines)
    vim.bo[buf].modifiable = false

    -- Batch apply highlights and extmarks
    for _, h in ipairs(self._hl_calls) do
        vim.hl.range(buf, _ns_id, h.hl, { h.row, h.s_col }, { h.row, h.e_col })
    end
    for _, d in ipairs(self._extmarks_data) do
        vim.api.nvim_buf_set_extmark(buf, _ns_id, d[1], d[2], d[3])
    end

    if self._pending_active_item_id then
        self:set_cursor_by_id(self._pending_active_item_id)
        self._pending_active_item_id = nil
    end
    return true
end

function ItemTree:toggle_expand(id)
    local data = self:_get_data(id)
    if data then
        if not data.expanded then
            self:expand(id)
        else
            self:collapse(id)
        end
    end
end

function ItemTree:expand(id)
    ---@type loop.comp.ItemTree.ItemData
    local data = self._tree:get_data(id)
    if data then
        data.expanded = true
        data.dirty = true -- state change may affect the formatter
        if not self:_request_children(id, data) then
            self:_request_render()
        end
        self._trackers:invoke("on_toggle", id, data.userdata, true)
    end
end

function ItemTree:collapse(id)
    ---@type loop.comp.ItemTree.ItemData
    local data = self._tree:get_data(id)
    if data then
        data.expanded = false
        data.dirty = true -- state change may affect the formatter
        self:_request_render()
        self._trackers:invoke("on_toggle", id, data.userdata, false)
    end
end

function ItemTree:expand_all(id)
    self:_expand_recursive(id)
end

function ItemTree:collapse_all(id)
    self:_collapse_recursive(id)
    self:_request_render()
end

function ItemTree:_expand_recursive(id)
    local data = self:_get_data(id)
    if not data then return end
    -- recusive expand does not async fetched nodes (children_callback) for performance
    if not data.expanded and (self._tree:have_children(id) or data.children_callback) then
        data.expanded = true
        if not self:_request_children(id, data) then
            self:_request_render()
        end
        self._trackers:invoke("on_toggle", id, data.userdata, true)
    end
    local children = self._tree:get_children(id)
    for _, child in ipairs(children) do
        self:_expand_recursive(child.id)
    end
end

function ItemTree:_collapse_recursive(id)
    local item = self:_get_data(id)
    if not item then return end
    if item.expanded then
        item.expanded = false
        self._trackers:invoke("on_toggle", id, item.userdata, false)
    end

    local children = self._tree:get_children(id)
    for _, child in ipairs(children) do
        self:_collapse_recursive(child.id)
    end
end

---@return loop.comp.ItemTree.ItemData
function ItemTree:_get_data(id)
    return self._tree:get_data(id)
end

---@return loop.comp.ItemTree.Item[]
function ItemTree:get_items()
    local items = {}
    for _, treeitem in ipairs(self._tree:get_items()) do
        ---@type loop.comp.ItemTree.ItemData
        local data = treeitem.data
        ---@type loop.comp.ItemTree.Item
        local item = {
            id = treeitem.id,
            data = data.userdata,
            expanded = data.expanded,
        }
        table.insert(items, item)
    end
    return items
end

function ItemTree:refresh_content()
    self:_request_render()
end

---@param item_id any
---@param item_data loop.comp.ItemTree.ItemData
---@return boolean
function ItemTree:_request_children(item_id, item_data)
    local tree = self._tree
    ---@param parent_id any
    ---@param loaded_children loop.comp.ItemTree.ItemDef[]
    local update_children = function(parent_id, loaded_children)
        local old_ids = {}
        for _, child in ipairs(tree:get_children(parent_id)) do
            old_ids[child.id] = true
        end
        for _, child in ipairs(loaded_children or {}) do
            old_ids[child.id] = nil
            ---@type loop.comp.ItemTree.ItemData
            local child_basedata = tree:get_data(child.id)
            if child_basedata then
                local existing_parent = tree:get_parent_id(child.id)
                assert(
                    not existing_parent or existing_parent == parent_id,
                    "id exists under a different node: " .. tostring(child.id)
                )
                if child.data then
                    child_basedata.userdata = child.data
                    child_basedata.dirty = true
                end
                if child.expanded ~= nil then child_basedata.expanded = child.expanded end
                if child.children_callback then
                    child_basedata.children_callback = child.children_callback
                    child_basedata.reload_children = true
                    child_basedata.load_sequence = child_basedata.load_sequence + 1
                    self:_request_children(child.id, child_basedata)
                else
                    tree:remove_children(child.id)
                end
            else
                self:add_item(parent_id, child)
            end
        end
        for id, _ in pairs(old_ids) do
            tree:remove_item(id)
        end
        self:_request_render()
    end
    ---@type loop.comp.ItemTree.ItemData
    if item_data.children_callback and item_data.reload_children ~= false then
        if item_data.expanded then
            item_data.reload_children = false
            item_data.children_loading = true
            local sequence = item_data.load_sequence
            vim.schedule(function()
                if sequence ~= item_data.load_sequence or not item_data.children_callback then return end
                item_data.children_callback(function(loaded_children)
                    if sequence ~= item_data.load_sequence then return end
                    if tree:get_data(item_id) then
                        item_data.children_loading = false
                        update_children(item_id, loaded_children)
                    end
                end)
            end)
        end
        return true
    end
    return false
end

return ItemTree
