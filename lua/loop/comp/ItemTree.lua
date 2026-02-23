local class = require('loop.tools.class')
local Tree = require("loop.tools.Tree")
local Trackers = require("loop.tools.Trackers")

---@class loop.comp.ItemTree.Item
---@field id any
---@field data any

---@class loop.comp.ItemTree.ItemDef : loop.comp.ItemTree.Item
---@field children_callback nil|fun(cb:fun(items:loop.comp.ItemTree.ItemDef[]))
---@field expanded boolean|nil

---@class loop.comp.ItemTree.ItemData
---@field userdata any
---@field children_callback nil|fun(cb:fun(items:loop.comp.ItemTree.ItemDef[]))
---@field expanded boolean|nil
---@field reload_children boolean|nil
---@field children_loading boolean|nil
---@field load_sequence number
---@field is_loading boolean|nil

---@class loop.comp.ItemTree.Tracker
---@field on_selection? fun(id:any,data:any)
---@field on_open? fun(id:any,data:any)
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

---@class loop.comp.ItemTree
local ItemTree = class()

local _ns_id = vim.api.nvim_create_namespace('LoopPluginItemTreeComp')

local function _normalize_text_chunks(chunks)
    local out = {}

    for _, chunk in ipairs(chunks or {}) do
        local text = chunk[1] or ""
        local hl = chunk[2]

        local parts = vim.split(text, "\n", { trimempty = false })
        for i, part in ipairs(parts) do
            table.insert(out, {
                part,        -- text
                hl,          -- highlight
                (i < #parts) -- is new line
            })
        end
    end

    return out
end

---@param item loop.comp.ItemTree.ItemDef
---@return loop.comp.ItemTree.ItemData
local function _itemdef_to_itemdata(item)
    return {
        userdata = item.data,
        children_callback = item.children_callback,
        expanded = item.expanded,
        reload_children = true,
        load_sequence = 1,
    }
end

---@param old loop.comp.ItemTree.ItemData
---@param new loop.comp.ItemTree.ItemData
local function _merge_itemdata(old, new)
    local data = old or {}
    data.userdata = new.userdata
    data.children_callback = new.children_callback
    data.reload_children = new.children_callback ~= nil
    -- Keep expanded/loading flags intact
    return data
end

local function _refresh_tree(tree, async_update)
    local flat = {}
    local have_loading_nodes = false
    local nodes = tree:flatten(function(id, data)
        if not data.expanded then
            return "exclude_children"
        end
        return nil
    end)

    for _, flat_node in ipairs(nodes) do
        table.insert(flat, flat_node)
        local item = flat_node.data
        if item.expanded then
            local item_id = flat_node.id
            if item.children_callback and item.reload_children ~= false then
                item.reload_children = false
                item.children_loading = true
                have_loading_nodes = true

                local sequence = item.load_sequence
                vim.schedule(function()
                    if sequence ~= item.load_sequence then return end
                    item.children_callback(function(loaded_children)
                        if sequence ~= item.load_sequence then return end
                        if tree:get_item(item_id) then
                            local treeitems = {}
                            for _, child in ipairs(loaded_children or {}) do
                                local basetreeitem = { id = child.id, data = _itemdef_to_itemdata(child) }
                                table.insert(treeitems, basetreeitem)
                            end
                            tree:update_children(item_id, treeitems, _merge_itemdata)
                            item.children_loading = false
                            async_update()
                        end
                    end)
                end)
            end
        end
    end
    return flat, have_loading_nodes
end

function ItemTree:init(args)
    assert(args.formatter, "formatter is required")
    assert(not args.header or type(args.header) == "table", "header must be a table")


    ---@type loop.comp.ItemTree.FormatterFn
    self._formatter = args.formatter
    self._trackers = Trackers:new()

    self._expand_char = args.expand_char or "▶"
    self._collapse_char = args.collapse_char or "▼"
    self._loading_char = args.enable_loading_indictaor and (args.loading_char or "⧗") or nil
    self._indent_string = args.indent_string or "  "
    self._render_delay_ms = args.render_delay_ms or 150

    self._tree = Tree:new()
    self._flat = {}
end

function ItemTree:add_tracker(cb) return self._trackers:add_tracker(cb) end

function ItemTree:_get_cur_node(comp)
    local cursor = comp:get_cursor()
    if not cursor then return nil end
    local row = cursor[1]
    local node = self._flat[row]
    if not node then return nil end
    return node.id, node.data
end

function ItemTree:link_to_buffer(buf_ctrl)
    -- Helper to get current node
    local function get_node()
        local id, data = self:_get_cur_node(buf_ctrl)
        if not id or not data then return nil end
        return id, data
    end

    -- Callbacks
    local callbacks = {
        open = function()
            local id, data = get_node()
            if id and data then self._trackers:invoke("on_open", id, data.userdata) end
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
        ["<CR>"] = { callbacks.toggle, "Expand/collapse" },
        ["<2-LeftMouse>"] = { callbacks.toggle, "Expand/collapse" },
        ["go"] = { callbacks.open, "Open details" },
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

    buf_ctrl:request_refresh()
end

function ItemTree:dispose() end

---@return loop.comp.ItemTree.Item?
function ItemTree:get_cur_item()
    if self._linked_buf then
        local id, nodedata = self:_get_cur_node(self._linked_buf)
        if id and nodedata then
            return { id = id, data = nodedata.userdata }
        end
    end
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
    local itemdata = self:_get_item(id)
    if not itemdata then return nil end
    return { id = id, data = itemdata.userdata }
end

---@return loop.comp.ItemTree.Item?
function ItemTree:get_parent_item(id)
    local par_id = self._tree:get_parent_id(id)
    if not par_id then return end
    local itemdata = self:_get_item(par_id)
    if not itemdata then return end
    return { id = id, data = itemdata.userdata }
end

function ItemTree:clear_items()
    self._tree = Tree:new()
    self:_request_render()
end

---@param parent_id any
---@param items loop.comp.ItemTree.ItemDef[]
function ItemTree:upsert_items(parent_id, items)
    for _, item in ipairs(items) do
        self._tree:upsert_item(parent_id, item.id, _itemdef_to_itemdata(item))
    end
    self:_request_render()
end

---@param parent_id any
---@param children loop.comp.ItemTree.ItemDef[]
function ItemTree:update_children(parent_id, children)
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
    self._tree:update_children(parent_id, baseitems, _merge_itemdata)
    self:_request_render()
end

---@param parent_id any
---@param item loop.comp.ItemTree.ItemDef
function ItemTree:upsert_item(parent_id, item)
    local existing = self._tree:get_item(item.id)
    if existing then
        existing.userdata = item.data
        existing.children_callback = item.children_callback
        existing.reload_children = true
        existing.load_sequence = existing.load_sequence + 1
        if item.expanded ~= nil then
            existing.expanded = item.expanded
        end
    else
        local new_data = _itemdef_to_itemdata(item)
        self._tree:upsert_item(parent_id, item.id, new_data)
    end

    self:_request_render()
end

---@param item loop.comp.ItemTree.ItemDef
---@return boolean
function ItemTree:update_item(item)
    local existing = self._tree:get_item(item.id)
    if not existing then return false end
    existing.userdata = item.data
    existing.children_callback = item.children_callback
    existing.reload_children = true
    existing.load_sequence = existing.load_sequence + 1
    if item.expanded ~= nil then
        existing.expanded = item.expanded
    end
    self:_request_render()
    return true
end

function ItemTree:get_children(parent_id)
    local items = {}
    local tree_items = self._tree:get_children(parent_id)

    for _, treeitem in ipairs(tree_items) do
        local data = treeitem.data
        table.insert(items, {
            id = treeitem.id,
            parent_id = parent_id,
            data = data.userdata,
            expanded = data.expanded,
            children_callback = data.children_callback
        })
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
        self._linked_buf.request_refresh()
    end
end

function ItemTree:_on_render_request(buf)
    local flat, have_loading_nodes = _refresh_tree(self._tree, function()
        vim.schedule(function() self:_request_render() end)
    end)

    if have_loading_nodes and not self._no_delay_next_render then
        vim.defer_fn(function()
            self._no_delay_next_render = true
            self:_request_render()
        end, self._render_delay_ms or 150)
        return false
    end
    self._no_delay_next_render = false

    local buffer_lines = {}
    local extmarks_data = {}
    local new_flat_nodes = {}

    for _, flatnode in ipairs(flat) do
        local item_id = flatnode.id
        local item = flatnode.data

        -- icon
        local icon = ""
        if item_id and (self._tree:have_children(item_id) or item.children_callback) then
            if self._loading_char and item.children_loading then
                icon = self._loading_char
            elseif item.expanded then
                icon = self._collapse_char
            else
                icon = self._expand_char
            end
        end

        -- prefix
        local prefix = string.rep(self._indent_string, flatnode.depth or 0)
        if icon ~= "" then
            prefix = prefix .. icon .. " "
        else
            prefix = prefix .. string.rep(" ", vim.fn.strdisplaywidth(self._expand_char)) .. " "
        end

        local prefix_width = vim.fn.strdisplaywidth(prefix)
        local empty_prefix = string.rep(" ", prefix_width)

        -- formatter → normalized chunks
        local text_chunks, virt_chunks = self._formatter(item_id, item.userdata, item.expanded)
        local chunks = _normalize_text_chunks(text_chunks)

        -- line state
        local cur_line = prefix
        local cur_col = #prefix
        local cur_hls = {}
        local first_row = nil

        local function flush()
            table.insert(buffer_lines, cur_line)
            table.insert(new_flat_nodes, flatnode)

            local row = #buffer_lines - 1
            first_row = first_row or row

            for _, hl in ipairs(cur_hls) do
                table.insert(extmarks_data, {
                    row = row,
                    start_col = hl.start_col,
                    mark = {
                        end_col = hl.end_col,
                        hl_group = hl.group,
                    }
                })
            end

            cur_line = empty_prefix
            cur_col = #empty_prefix
            cur_hls = {}
        end

        -- render chunks
        for _, chunk in ipairs(chunks) do
            local text = chunk[1]
            local hl_grp = chunk[2]
            local is_nl = chunk[3]
            local start_col = cur_col
            cur_line = cur_line .. text
            cur_col = cur_col + #text

            if hl_grp and #text > 0 then
                table.insert(cur_hls, {
                    group = hl_grp,
                    start_col = start_col,
                    end_col = cur_col,
                })
            end

            if is_nl then
                flush()
            end
        end

        -- flush final line
        flush()

        -- virt_text
        local vt = {}
        for _, c in ipairs(virt_chunks or {}) do
            table.insert(vt, c) -- each element is already {virt_text, hl}
        end
        if #vt > 0 and first_row then
            table.insert(extmarks_data, {
                row = first_row,
                start_col = 0,
                mark = { virt_text = vt, hl_mode = "combine" },
            })
        end
    end

    self._flat = new_flat_nodes

    vim.api.nvim_buf_clear_namespace(buf, _ns_id, 0, -1)
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, buffer_lines)
    vim.bo[buf].modifiable = false

    for _, data in ipairs(extmarks_data) do
        vim.api.nvim_buf_set_extmark(buf, _ns_id, data.row, data.start_col, data.mark)
    end

    return true
end

function ItemTree:toggle_expand(id)
    local item = self:_get_item(id)
    if item then
        item.expanded = not item.expanded
        self:_request_render()
        self._trackers:invoke("on_toggle", id, item.userdata, item.expanded)
    end
end

function ItemTree:expand(id)
    ---@type loop.comp.ItemTree.ItemData
    local item = self._tree:get_item(id)
    if item then
        item.expanded = true
        self:_request_render()
        self._trackers:invoke("on_toggle", id, item.userdata, true)
    end
end

function ItemTree:collapse(id)
    ---@type loop.comp.ItemTree.ItemData
    local item = self._tree:get_item(id)
    if item then
        item.expanded = false
        self:_request_render()
        self._trackers:invoke("on_toggle", id, item.userdata, false)
    end
end

function ItemTree:expand_all(id)
    self:_expand_recursive(id)
    self:_request_render()
end

function ItemTree:collapse_all(id)
    self:_collapse_recursive(id)
    self:_request_render()
end

function ItemTree:_expand_recursive(id)
    local item = self:_get_item(id)
    if not item then return end
    if not item.expanded then
        item.expanded = true
        self._trackers:invoke("on_toggle", id, item.userdata, true)
    end

    local children = self._tree:get_children(id)
    for _, child in ipairs(children) do
        self:_expand_recursive(child.id)
    end
end

function ItemTree:_collapse_recursive(id)
    local item = self:_get_item(id)
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
function ItemTree:_get_item(id)
    return self._tree:get_item(id)
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
        }
        table.insert(items, item)
    end
    return items
end

function ItemTree:refresh_content()
    self:_request_render()
end

return ItemTree
