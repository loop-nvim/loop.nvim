local class = require('loop.tools.class')
local BaseBuffer = require('loop.buf.BaseBuffer')
local Tree = require("loop.tools.Tree")
local strtools = require('loop.tools.strtools')

---@class loop.comp.TreeBuffer.Item
---@field id any
---@field data any
---@field expanded boolean

---@alias loop.comp.TreeBuffer.ChildrenCallback fun(cb:fun(items:loop.comp.TreeBuffer.ItemDef[]))

---@class loop.comp.TreeBuffer.ItemDef
---@field id any
---@field data any
---@field children_callback loop.comp.TreeBuffer.ChildrenCallback?
---@field expanded boolean|nil

---@class loop.comp.TreeBuffer.ItemData
---@field userdata any
---@field children_callback loop.comp.TreeBuffer.ChildrenCallback?
---@field expanded boolean|nil
---@field reload_children boolean|nil
---@field children_loading boolean|nil
---@field load_sequence number
---@field is_loading boolean|nil

---@class loop.comp.TreeBuffer.Tracker
---@field on_selection? fun(id:any,data:any)
---@field on_toggle? fun(id:any,data:any,expanded:boolean)

---@class loop.comp.TreeBuffer.VirtText
---@field text string
---@field highlight string

---@alias loop.comp.TreeBuffer.FormatterFn fun(id:any, data:any,expanded:boolean):string[][],string[][]
---@
---@class loop.comp.TreeBufferOpts
---@field base_opts loop.comp.BaseBufferOpts
---@field formatter loop.comp.TreeBuffer.FormatterFn
---@field expand_char string?
---@field collapse_char string?
---@field enable_loading_indicator boolean?
---@field loading_char string?
---@field indent_string string?
---@field render_delay_ms number?
---@field header string[][]?
---@field transient_children_callbacks boolean?

---@class loop.comp.TreeBuffer.Tracker : loop.comp.Tracker
---@field on_selection? fun(id:any,data:any)
---@field on_toggle? fun(id:any,data:any,expanded:boolean)

local _ns_id = vim.api.nvim_create_namespace('LoopPluginTreeBuffer')

local _header_hl_group = "LoopLuginTreeBufferHeader"
vim.api.nvim_set_hl(0, _header_hl_group, {
    bg = (function()
        local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = "WinBar", link = false })
        if not ok then return nil end
        return hl.bg
    end)()
})

---@class loop.comp.TreeBuffer:loop.comp.BaseBuffer
---@field new fun(self: loop.comp.TreeBuffer,opts:loop.comp.TreeBufferOpts): loop.comp.TreeBuffer
local TreeBuffer = class(BaseBuffer)

---@param item loop.comp.TreeBuffer.ItemDef
---@return loop.comp.TreeBuffer.ItemData
local function _itemdef_to_itemdata(item)
    return {
        userdata = item.data,
        children_callback = item.children_callback,
        expanded = item.expanded,
        reload_children = true,
        load_sequence = 1,
    }
end

local _filter = function(_, data) return data.expanded ~= false end

---@param opts loop.comp.TreeBufferOpts
function TreeBuffer:init(opts)
    BaseBuffer.init(self, opts.base_opts)
    ---@type loop.comp.TreeBuffer.FormatterFn
    self._formatter = opts.formatter
    self._header = opts.header ---@type string[][]?

    self._expand_char = opts.expand_char or "▶"
    self._collapse_char = opts.collapse_char or "▼"
    self._loading_char = opts.enable_loading_indicator and (opts.loading_char or "⧗") or nil
    self._indent_string = opts.indent_string or "  "

    -- Pre-allocate indent cache
    self._indent_cache = {}
    for i = 0, 20 do
        self._indent_cache[i] = string.rep(opts.indent_string or "  ", i)
    end

    self._tree = Tree:new()

    ---@type number[]
    self._flat_ids = {}

    self:_setup_keymaps()
end

function TreeBuffer:destroy()
    BaseBuffer.destroy(self)
end

function TreeBuffer:_setup_buf()
    BaseBuffer._setup_buf(self)
    self:_full_render()
end

---@param callbacks loop.comp.TreeBuffer.Tracker
---@return loop.TrackerRef
function TreeBuffer:add_tracker(callbacks)
    return self._trackers:add_tracker(callbacks)
end

function TreeBuffer:_setup_keymaps()
    ---@return loop.comp.TreeBuffer.ItemData?
    -- Callbacks
    local callbacks = {
        on_enter = function()
            ---@type any,loop.comp.TreeBuffer.ItemData?
            local id, data = self:_get_cur_item()
            if id and data then
                if (self._tree:have_children(id) or data.children_callback) then
                    self:toggle_expand(id)
                else
                    self._trackers:invoke("on_selection", id, data.userdata)
                end
            end
        end,
        toggle = function()
            local id, data = self:_get_cur_item()
            if id and data and (self._tree:have_children(id) or data.children_callback) then
                self:toggle_expand(id)
            end
        end,
        expand = function()
            local id, data = self:_get_cur_item()
            if id and data and (self._tree:have_children(id) or data.children_callback) then
                self:expand(id)
            end
        end,

        collapse = function()
            local id, data = self:_get_cur_item()
            if id and data and (self._tree:have_children(id) or data.children_callback) then
                self:collapse(id)
            end
        end,

        expand_recursive = function()
            local id = self:_get_cur_item()
            if id then self:expand_all(id) end
        end,

        collapse_recursive = function()
            local id = self:_get_cur_item()
            if id then self:collapse_all(id) end
        end,
    }

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
        self:add_keymap(key, { callback = map[1], desc = map[2] })
    end
end

---@param item_id any
---@param item_data loop.comp.TreeBuffer.ItemData
function TreeBuffer:_request_children(item_id, item_data)
    if not item_data.expanded or not item_data.children_callback or item_data.reload_children == false then
        return
    end
    item_data.reload_children = false
    item_data.children_loading = true
    local sequence = item_data.load_sequence
    vim.schedule(function()
        if sequence ~= item_data.load_sequence or not item_data.children_callback then return end
        item_data.children_callback(function(loaded_children)
            if sequence ~= item_data.load_sequence then return end
            if self._tree:get_data(item_id) then
                item_data.children_loading = false
                self:set_children(item_id, loaded_children)
            end
        end)
    end)
end

---Renders a single node's text and collects its metadata
---@param flatnode loop.tools.Tree.FlatNode
---@param row number The buffer row this node will occupy
---@return string line, table hl_calls, table extmark_data
function TreeBuffer:_render_node(flatnode, row)
    local item_id, item, depth = flatnode.id, flatnode.data, flatnode.depth
    local hl_calls = {}
    local extmark_data = {}

    -- 1. Prefix Construction
    local icon = ""
    if item_id and (self._tree:have_children(item_id) or item.children_callback) then
        icon = (item.children_loading and self._loading_char) or (item.expanded and self._collapse_char) or
            self._expand_char
    end

    local indent = self._indent_cache[depth] or string.rep(self._indent_string, depth)
    local expand_padding = string.rep(" ", vim.fn.strdisplaywidth(self._expand_char)) .. " "
    local prefix = icon ~= "" and (indent .. icon .. " ") or (indent .. expand_padding)

    -- 2. Formatter / Cache Logic
    local text_chunks, virt = self._formatter(item_id, item.userdata, item.expanded)

    local current_line = prefix
    local col = #prefix

    for i = 1, #text_chunks do
        local chunk = text_chunks[i]
        local txt, hl = chunk[1], chunk[2]
        local len = #txt
        if len > 0 then
            if hl then
                table.insert(hl_calls, { hl = hl, row = row, s_col = col, e_col = col + len })
            end
            current_line = current_line .. txt
            col = col + len
        end
    end

    -- 3. Virtual Text
    if virt and #virt > 0 then
        table.insert(extmark_data, { row, 0, { virt_text = virt, hl_mode = "combine" } })
    end

    return current_line, hl_calls, extmark_data
end

---Applies collected metadata to a range of rows
function TreeBuffer:_apply_metadata(buf, hl_calls, extmarks)
    for _, h in ipairs(hl_calls) do
        vim.hl.range(buf, _ns_id, h.hl, { h.row, h.s_col }, { h.row, h.e_col })
    end
    for _, d in ipairs(extmarks) do
        vim.api.nvim_buf_set_extmark(buf, _ns_id, d[1], d[2], d[3])
    end
end

function TreeBuffer:_full_render()
    local buf = self:get_buf()
    if buf <= 0 then return end

    local buffer_lines = {}
    local extmarks_data = {}
    local hl_calls = {}
    self._flat_ids = {}
    local t_insert = table.insert

    -- Handle Header (if exists)
    if self._header then
        local row = 0
        local left, right = self._header[1] or {}, self._header[2] or {}
        local line = left[1] or ""

        t_insert(buffer_lines, line)
        t_insert(self._flat_ids, {}) -- array unsed as unique id
        t_insert(extmarks_data, { row, 0, { line_hl_group = _header_hl_group } })

        if left[2] then
            t_insert(hl_calls, { hl = left[2], row = row, s_col = 0, e_col = #line })
        end
        if right[1] and #right[1] > 0 then
            t_insert(extmarks_data, { row, 0, {
                virt_text = { { right[1], right[2] } },
                virt_text_pos = "right_align",
                hl_mode = "combine",
            } })
        end
    end

    local flat = self._tree:flatten(nil, _filter)

    for _, flatnode in ipairs(flat) do
        local row = #buffer_lines
        local line, n_hls, n_exts = self:_render_node(flatnode, row)

        table.insert(buffer_lines, line)
        table.insert(self._flat_ids, flatnode.id)

        -- Merge metadata
        for _, h in ipairs(n_hls) do table.insert(hl_calls, h) end
        for _, e in ipairs(n_exts) do table.insert(extmarks_data, e) end
    end

    vim.api.nvim_buf_clear_namespace(buf, _ns_id, 0, -1)
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, buffer_lines)
    vim.bo[buf].modifiable = false

    self:_apply_metadata(buf, hl_calls, extmarks_data)
end

---@return loop.comp.TreeBuffer.ItemData
function TreeBuffer:_get_data(id)
    return self._tree:get_data(id)
end

---@return loop.comp.TreeBuffer.Item?
function TreeBuffer:get_item(id)
    local itemdata = self:_get_data(id)
    if not itemdata then return nil end
    return { id = id, data = itemdata.userdata, expanded = itemdata.expanded }
end

---@return loop.comp.TreeBuffer.Item[]
function TreeBuffer:get_items()
    local items = {}
    for _, treeitem in ipairs(self._tree:get_items()) do
        ---@type loop.comp.TreeBuffer.ItemData
        local data = treeitem.data
        ---@type loop.comp.TreeBuffer.Item
        local item = {
            id = treeitem.id,
            data = data.userdata,
            expanded = data.expanded,
        }
        table.insert(items, item)
    end
    return items
end

--- Get the parent ID of a node (or nil if it's a root node)
---@param id any
---@return any|nil parent_id
function TreeBuffer:get_parent_id(id)
    return self._tree:get_parent_id(id)
end

---@return loop.comp.TreeBuffer.Item?
function TreeBuffer:get_parent_item(id)
    local par_id = self._tree:get_parent_id(id)
    if not par_id then return nil end

    ---@type loop.comp.TreeBuffer.ItemData
    local itemdata = self._tree:get_data(par_id)
    if not itemdata then return nil end

    return { id = par_id, data = itemdata.userdata, expanded = itemdata.expanded }
end

---@return any, loop.comp.TreeBuffer.ItemData?
function TreeBuffer:_get_cur_item()
    local buf = self:get_buf()
    if buf <= 0 then return end
    local winid = vim.fn.bufwinid(buf)
    if winid <= 0 then return end
    local cursor = vim.api.nvim_win_get_cursor(winid)
    local id = self._flat_ids[cursor[1]]
    if not id then return end
    return id, self:_get_data(id)
end

function TreeBuffer:set_cursor_by_id(id)
    local buf = self:get_buf()
    if buf <= 0 then return end
    local winid = vim.fn.bufwinid(buf)
    if winid <= 0 then return end
    local idx = -1
    for i, id2 in ipairs(self._flat_ids) do
        if id == id2 then
            idx = i
            break
        end
    end
    if idx > 0 then
        vim.api.nvim_win_set_cursor(winid, { idx, 0 })
    end
end

---@return loop.comp.TreeBuffer.Item?
function TreeBuffer:get_cur_item()
    local id, itemdata = self:_get_cur_item()
    if not id or not itemdata then return nil end
    return { id = id, data = itemdata.userdata, expanded = itemdata.expanded }
end

---@param parent_id any
---@param children loop.comp.TreeBuffer.ItemDef[]
function TreeBuffer:set_children(parent_id, children)
    local baseitems = {}
    for _, c in ipairs(children) do
        table.insert(baseitems, { id = c.id, data = _itemdef_to_itemdata(c) })
    end

    -- 2. Update the tree data
    local old_size = self._tree:tree_size(parent_id, _filter)
    self._tree:set_children(parent_id, baseitems)

    if parent_id == nil then
        self:_full_render()
        return
    end

    local buf = self:get_buf()
    if buf > 0 then
        -- 1. Find the parent in current flat view
        local parent_idx = -1
        for i, id in ipairs(self._flat_ids) do
            if id == parent_id then
                parent_idx = i
                break
            end
        end
        if parent_idx == -1 then
            return
        end
        local base_depth = self._tree:get_depth(parent_id)
        -- 3. Flatten only the updated subtree
        local new_flat = self._tree:flatten(parent_id, _filter)
        for _, node in ipairs(new_flat) do
            node.depth = base_depth + node.depth
        end

        local new_lines, new_ids = {}, {}
        local range_hls, range_exts = {}, {}
        local start_row = parent_idx - 1

        for i, flatnode in ipairs(new_flat) do
            local row = start_row + i - 1
            local line, hls, exts = self:_render_node(flatnode, row)

            table.insert(new_lines, line)
            table.insert(new_ids, flatnode.id)
            for _, h in ipairs(hls) do table.insert(range_hls, h) end
            for _, e in ipairs(exts) do table.insert(range_exts, e) end
        end

        -- 4. Buffer Surgery
        vim.bo[buf].modifiable = true

        -- Clear old metadata for the specific range being replaced
        -- (End row is start_row + old_size)
        vim.api.nvim_buf_clear_namespace(buf, _ns_id, start_row, start_row + old_size)

        -- Replace lines
        vim.api.nvim_buf_set_lines(buf, start_row, start_row + old_size, false, new_lines)

        -- Update internal ID tracker
        local tail = table.move(self._flat_ids, parent_idx + old_size, #self._flat_ids, 1, {})
        for i = #self._flat_ids, parent_idx, -1 do table.remove(self._flat_ids, i) end
        for _, id in ipairs(new_ids) do table.insert(self._flat_ids, id) end
        for _, id in ipairs(tail) do table.insert(self._flat_ids, id) end

        -- 5. Apply new metadata
        self:_apply_metadata(buf, range_hls, range_exts)

        vim.bo[buf].modifiable = false
    end
end

function TreeBuffer:toggle_expand(id)
    local data = self:_get_data(id)
    if data then
        if not data.expanded then
            self:expand(id)
        else
            self:collapse(id)
        end
    end
end

---Helper to surgically re-render a specific range in the buffer
---@private
function TreeBuffer:_render_range(start_idx, old_size, new_flat)
    local buf = self:get_buf()
    if buf <= 0 then return end

    local new_lines, new_ids = {}, {}
    local range_hls, range_exts = {}, {}
    local start_row = start_idx - 1

    for i, flatnode in ipairs(new_flat) do
        local row = start_row + i - 1
        local line, hls, exts = self:_render_node(flatnode, row)
        table.insert(new_lines, line)
        table.insert(new_ids, flatnode.id)
        for _, h in ipairs(hls) do table.insert(range_hls, h) end
        for _, e in ipairs(exts) do table.insert(range_exts, e) end
    end

    vim.bo[buf].modifiable = true
    -- 1. Clear old metadata for the range
    vim.api.nvim_buf_clear_namespace(buf, _ns_id, start_row, start_row + old_size)
    -- 2. Replace lines
    vim.api.nvim_buf_set_lines(buf, start_row, start_row + old_size, false, new_lines)
    -- 3. Update internal ID tracking
    local tail = table.move(self._flat_ids, start_idx + old_size, #self._flat_ids, 1, {})
    for i = #self._flat_ids, start_idx, -1 do table.remove(self._flat_ids, i) end
    for _, id in ipairs(new_ids) do table.insert(self._flat_ids, id) end
    for _, id in ipairs(tail) do table.insert(self._flat_ids, id) end
    -- 4. Apply new metadata
    self:_apply_metadata(buf, range_hls, range_exts)
    vim.bo[buf].modifiable = false
end

function TreeBuffer:expand(id)
    local data = self:_get_data(id)
    if not data or data.expanded then return end

    -- 1. Locate node
    local idx = -1
    for i, fid in ipairs(self._flat_ids) do
        if fid == id then
            idx = i; break
        end
    end
    -- 2. State change
    data.expanded = true

    if idx ~= -1 then
        local base_depth = self._tree:get_depth(id)
        -- 3. Generate new flat range for this node + its now-visible children
        local new_subtree_flat = self._tree:flatten(id, _filter)
        for _, node in ipairs(new_subtree_flat) do
            node.depth = base_depth + node.depth
        end
        -- 4. Replace 1 line (the collapsed parent) with N lines (parent + children)
        self:_render_range(idx, 1, new_subtree_flat)
    end

    self:_request_children(id, data)
    self._trackers:invoke("on_toggle", id, data.userdata, true)
end

function TreeBuffer:collapse(id)
    local data = self:_get_data(id)
    if not data or not data.expanded then return end

    -- 1. Locate node
    local idx = -1
    for i, fid in ipairs(self._flat_ids) do
        if fid == id then
            idx = i; break
        end
    end
    if idx == -1 then return end

    -- 2. Calculate current visible size of this branch
    local current_visible_size = 0
    local depth = self._tree:get_depth(id)
    for i = idx + 1, #self._flat_ids do
        local child_id = self._flat_ids[i]
        -- If the next node's depth is <= our depth, it's a sibling or higher
        if self._tree:get_depth(child_id) <= depth then break end
        current_visible_size = current_visible_size + 1
    end

    -- 3. State change
    data.expanded = false

    -- 4. Replace N lines with 1 line (just the collapsed parent)
    local parent_flat = { id = id, data = data, depth = depth }
    self:_render_range(idx, 1 + current_visible_size, { parent_flat })

    self._trackers:invoke("on_toggle", id, data.userdata, false)
end

function TreeBuffer:expand_all(id)
    local data = self:_get_data(id)
    if not data then return end
    if not data.expanded and (self._tree:have_children(id) or data.children_callback) then
        self:expand(id)
    end
    local children = self._tree:get_children(id)
    for _, child in ipairs(children) do
        self:expand_all(child.id)
    end
end

function TreeBuffer:collapse_all(id)
    local data = self:_get_data(id)
    if not data then return end
    if not data.expanded and (self._tree:have_children(id) or data.children_callback) then
        self:collapse(id)
    end
    local children = self._tree:get_children(id)
    for _, child in ipairs(children) do
        self:collapse_all(child.id)
    end
end

---@param parent_id any
---@param item loop.comp.TreeBuffer.ItemDef
function TreeBuffer:add_item(parent_id, item)
    -- 1. Update the logical tree
    local item_data = _itemdef_to_itemdata(item)
    self._tree:add_item(parent_id, item.id, item_data)

    local buf = self:get_buf()

    -- 2. Handle Root Addition (parent_id is nil)
    if parent_id == nil then
        if buf > 0 then
            local insert_row = #self._flat_ids
            local node = {
                id = item.id,
                data = item_data,
                depth = 0
            }
            local line, hls, exts = self:_render_node(node, insert_row)
            vim.bo[buf].modifiable = true
            -- Append to the end of the buffer
            vim.api.nvim_buf_set_lines(buf, insert_row, insert_row, false, { line })
            table.insert(self._flat_ids, item.id)
            self:_apply_metadata(buf, hls, exts)
            vim.bo[buf].modifiable = false
        end
        self:_request_children(item.id, item_data)
        return
    end

    -- 3. Handle Child Addition (parent_id exists)
    local parent_idx = -1
    for i, id in ipairs(self._flat_ids) do
        if id == parent_id then
            parent_idx = i
            break
        end
    end

    -- If parent isn't in the flattened list, it's inside a collapsed branch
    if parent_idx == -1 then
        self:_request_children(item.id, item_data)
        return
    end

    if buf > 0 then
        -- 4. Re-render Parent (it might need a "▼" or "▶" icon now)
        local parent_data = self._tree:get_data(parent_id)
        if parent_data then
            local p_row = parent_idx - 1
            local p_line, p_hls, p_exts = self:_render_node({
                id = parent_id,
                data = parent_data,
                depth = self._tree:get_depth(parent_id)
            }, p_row)

            vim.bo[buf].modifiable = true
            vim.api.nvim_buf_clear_namespace(buf, _ns_id, p_row, p_row + 1)
            vim.api.nvim_buf_set_lines(buf, p_row, p_row + 1, false, { p_line })
            self:_apply_metadata(buf, p_hls, p_exts)
            vim.bo[buf].modifiable = false
        end
        -- 5. Render New Child if Parent is Expanded
        if parent_data and parent_data.expanded ~= false then
            -- Insert at the end of the parent's current visible subtree
            local insert_pos = parent_idx + self._tree:tree_size(parent_id, _filter) - 1
            local node = {
                id = item.id,
                data = item_data,
                depth = self._tree:get_depth(item.id)
            }
            local line, hls, exts = self:_render_node(node, insert_pos)

            vim.bo[buf].modifiable = true
            vim.api.nvim_buf_set_lines(buf, insert_pos, insert_pos, false, { line })
            table.insert(self._flat_ids, insert_pos + 1, item.id)
            self:_apply_metadata(buf, hls, exts)
            vim.bo[buf].modifiable = false
        end
    end
    self:_request_children(item.id, item_data)
end

---Wipes all items from the tree and clears the buffer (preserving header if defined)
function TreeBuffer:clear_items()
    -- 1. Reset the underlying tree structure
    self._tree = Tree:new()

    -- 2. Clear the flattened ID tracker
    self._flat_ids = {}

    -- 3. Trigger a full render to clear the buffer lines and metadata
    self:_full_render()
end

return TreeBuffer
