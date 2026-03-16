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
---@field header {[1]:string,[2]:string,[3]:boolean?}[]?
---@field transient_children_callbacks boolean?

---@class loop.comp.TreeBuffer.Tracker : loop.comp.Tracker
---@field on_selection? fun(id:any,data:any)
---@field on_toggle? fun(id:any,data:any,expanded:boolean)

local _ns_id = vim.api.nvim_create_namespace('LoopPluginTreeBuffer')

local _header_hl_group = "Winbar"
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
    ---@type table<any, number>
    self._id_to_idx = {}

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
        ["<2-LeftMouse>"] = { callbacks.on_enter, "Expand/collapse" },
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

---@param ms number
function TreeBuffer:delay_rendering(ms)
    if not self._redering_suspended then
        self._redering_suspended = true
        vim.defer_fn(function()
            self._redering_suspended = false
            self:_full_render()
        end, ms)
    end
end

function TreeBuffer:_request_children(item_id, item_data)
    if not item_data.expanded or not item_data.children_callback or item_data.reload_children == false then
        return
    end
    item_data.reload_children = false
    item_data.children_loading = true
    local sequence = item_data.load_sequence
    -- Use a closure to capture the specific data object instance
    local target_data = item_data
    vim.schedule(function()
        -- 1. Check if the sequence changed
        -- 2. Check if the node still exists in the tree
        -- 3. Check if the data object in the tree is still the one we started with
        local current_data = self._tree:get_data(item_id)
        if sequence ~= target_data.load_sequence or current_data ~= target_data then
            return
        end
        target_data.children_callback(function(loaded_children)
            vim.schedule(function() -- Ensure buffer operations happen on main thread
                local latest_data = self._tree:get_data(item_id)
                if sequence ~= target_data.load_sequence or latest_data ~= target_data then
                    return
                end
                target_data.children_loading = false
                self:set_children(item_id, loaded_children)
            end)
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
    if buf <= 0 or self._redering_suspended then return end

    local buffer_lines = {}
    local extmarks_data = {}
    local hl_calls = {}
    self._flat_ids = {}
    self._id_to_idx = {}
    local t_insert = table.insert

    -- Handle Header (if exists)
    if self._header then
        local row = 0
        local left_text = ""
        -- Apply the background highlight to the whole line
        t_insert(extmarks_data, { row, 0, { line_hl_group = _header_hl_group } })
        for _, part in ipairs(self._header) do
            local text, hl, right_align = part[1], part[2], part[3]
            if not right_align then
                local start_col = #left_text
                left_text = left_text .. text
                if hl then
                    t_insert(hl_calls, { hl = hl, row = row, s_col = start_col, e_col = #left_text })
                end
            else
                t_insert(extmarks_data, { row, 0, {
                    virt_text = { { text, hl } },
                    virt_text_pos = "right_align",
                    hl_mode = "combine",
                } })
            end
        end
        t_insert(buffer_lines, left_text)
        t_insert(self._flat_ids, {}) -- Header placeholder
    end

    local flat = self._tree:flatten(nil, _filter)

    for _, flatnode in ipairs(flat) do
        local row = #buffer_lines
        local line, n_hls, n_exts = self:_render_node(flatnode, row)

        table.insert(buffer_lines, line)
        table.insert(self._flat_ids, flatnode.id)
        self._id_to_idx[flatnode.id] = #self._flat_ids
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

---Helper to surgically re-render a specific range in the buffer
---@private
function TreeBuffer:_render_range(start_idx, old_size, new_flat)
    local buf = self:get_buf()
    if buf <= 0 or self._redering_suspended then return end

    -- 1. SAVE: Identify which ID the cursor is currently on
    local winid = self:_get_winid()
    local saved_id = nil
    local saved_cursor = nil
    if winid and winid > 0 then
        saved_cursor = vim.api.nvim_win_get_cursor(winid)
        saved_id = saved_cursor and self._flat_ids[saved_cursor[1]] or nil
    end

    local new_lines, new_ids = {}, {}
    local range_hls, range_exts = {}, {}
    local start_row = start_idx - 1

    -- Generate new content
    for i, flatnode in ipairs(new_flat) do
        local row = start_row + i - 1
        local line, hls, exts = self:_render_node(flatnode, row)
        table.insert(new_lines, line)
        table.insert(new_ids, flatnode.id)
        for _, h in ipairs(hls) do table.insert(range_hls, h) end
        for _, e in ipairs(exts) do table.insert(range_exts, e) end
    end

    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_clear_namespace(buf, _ns_id, start_row, start_row + old_size)
    vim.api.nvim_buf_set_lines(buf, start_row, start_row + old_size, false, new_lines)

    -- --- Sync id_to_idx map ---

    -- 1. Remove IDs that are being deleted
    for i = 0, old_size - 1 do
        local old_id = self._flat_ids[start_idx + i]
        if old_id ~= nil then
            self._id_to_idx[old_id] = nil
        end
    end

    -- 2. Update the flat_ids array
    for _ = 1, old_size do
        table.remove(self._flat_ids, start_idx)
    end
    for i, id in ipairs(new_ids) do
        table.insert(self._flat_ids, start_idx + i - 1, id)
    end

    -- 3. Re-index from the point of change to the end
    -- This handles both the new items and the items shifted by the surgery
    for i = start_idx, #self._flat_ids do
        local id = self._flat_ids[i]
        if id ~= nil then
            self._id_to_idx[id] = i
        end
    end

    self:_apply_metadata(buf, range_hls, range_exts)
    vim.bo[buf].modifiable = false

    -- 2. RESTORE: Put the cursor back on the item it was on
    if winid and winid > 0 and saved_id then
        if not self:set_cursor_by_id(saved_id) then
            pcall(vim.api.nvim_win_set_cursor, winid, saved_cursor)
        end
    end
end

---Wipes all items from the tree and clears the buffer (preserving header if defined)
function TreeBuffer:clear_items()
    -- 1. Reset the underlying tree structure
    self._tree = Tree:new()
    -- 2. Clear the flattened ID tracker
    self._flat_ids = {}
    self._id_to_idx = {}
    -- 3. Trigger a full render to clear the buffer lines and metadata
    self:_full_render()
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

---@private
---@return number?
function TreeBuffer:_get_winid()
    local buf = self:get_buf()
    if buf <= 0 or self._redering_suspended then return end
    local winid
    if vim.api.nvim_get_current_buf() == buf then
        winid = vim.api.nvim_get_current_win()
    else
        winid = vim.fn.bufwinid(buf)
    end
    return winid
end

---@return {[1]:number,[2]:number}?
function TreeBuffer:get_cursor()
    local winid = self:_get_winid()
    if not winid or winid <= 0 then return end
    return vim.api.nvim_win_get_cursor(winid)
end

---@param cur {[1]:number,[2]:number}
---@param clamp_row boolean?
---@return boolean,string?
function TreeBuffer:set_cursor(cur, clamp_row)
    local winid = self:_get_winid()
    if not winid or winid <= 0 then return false end
    local buf = self:get_buf()
    if buf <= 0 then return false end
    local line_count = vim.api.nvim_buf_line_count(buf)
    local line, col = cur[1], cur[2]
    if clamp_row ~= false then
        line = math.max(1, math.min(line, line_count))
    end
    local ok, err = pcall(vim.api.nvim_win_set_cursor, winid, { line, col })
    return ok, err and tostring(err)
end

---@return any, loop.comp.TreeBuffer.ItemData?
function TreeBuffer:_get_cur_item()
    local winid = self:_get_winid()
    if not winid or winid <= 0 then return end
    local cursor = vim.api.nvim_win_get_cursor(winid)
    if not cursor then return end
    local id = self._flat_ids[cursor[1]]
    if not id then return end
    return id, self:_get_data(id)
end

---@return boolean
function TreeBuffer:set_cursor_by_id(id)
    local winid = self:_get_winid()
    if not winid or winid <= 0 then return false end
    local idx = self._id_to_idx[id] -- Instant lookup
    if idx then
        local ok, _ = pcall(vim.api.nvim_win_set_cursor, winid, { idx, 0 })
        return ok
    end
    return false
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
    -- 1. Update the logical tree state first
    local baseitems = {}
    for _, c in ipairs(children) do
        table.insert(baseitems, { id = c.id, data = _itemdef_to_itemdata(c) })
    end

    -- We need the size BEFORE updating the tree to know how many lines to remove
    local old_visible_size = self._tree:tree_size(parent_id, _filter)
    self._tree:set_children(parent_id, baseitems)

    -- need to trigger their own data loading (if they were added as expanded)
    for _, item in ipairs(baseitems) do
        if item.data.expanded then
            self:_request_children(item.id, item.data)
        end
    end

    local buf = self:get_buf()
    if buf <= 0 or self._redering_suspended then return end

    -- 2. Handle the "New Root" Case (parent_id is nil)
    if parent_id == nil then
        -- When parent is nil, we replace/append the entire tree content
        -- but we must preserve the header if it exists.
        local header_offset = self._header and 1 or 0
        local new_flat = self._tree:flatten(nil, _filter)

        -- We treat the entire buffer (minus header) as the range to replace
        -- old_visible_size in this context is the current length of flat_ids
        local current_tree_size = #self._flat_ids - header_offset
        if current_tree_size < 0 then current_tree_size = 0 end

        self:_render_range(header_offset + 1, current_tree_size, new_flat)
        return
    end

    -- 2. Find the parent index IMMEDIATELY before buffer surgery
    local parent_idx = self._id_to_idx[parent_id]
    if not parent_idx then return end

    -- 3. Prepare the new subtree lines
    local base_depth = self._tree:get_depth(parent_id)
    local new_flat = self._tree:flatten(parent_id, _filter)
    for _, node in ipairs(new_flat) do
        node.depth = base_depth + node.depth
    end

    -- 4. Perform the surgery
    -- Note: old_visible_size includes the parent.
    -- flatten(parent_id) also includes the parent.
    self:_render_range(parent_idx, old_visible_size, new_flat)
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

function TreeBuffer:expand(id)
    local data = self:_get_data(id)
    if not data or data.expanded then return end

    -- O(1) Lookup instead of loop
    local idx = self._id_to_idx[id]
    data.expanded = true

    if idx then
        local base_depth = self._tree:get_depth(id)
        local new_subtree_flat = self._tree:flatten(id, _filter)
        for _, node in ipairs(new_subtree_flat) do
            node.depth = base_depth + node.depth
        end
        self:_render_range(idx, 1, new_subtree_flat)
    end

    self:_request_children(id, data)
    self._trackers:invoke("on_toggle", id, data.userdata, true)
end

function TreeBuffer:collapse(id)
    local data = self:_get_data(id)
    if not data or not data.expanded then return end

    local idx = self._id_to_idx[id]
    if not idx then return end

    -- 1. Get size while it is still expanded
    local current_visible_size = self._tree:tree_size(id, _filter)

    -- 2. NOW update the state
    data.expanded = false

    -- 3. Prepare the single line (the collapsed parent)
    local depth = self._tree:get_depth(id)
    local parent_flat = { id = id, data = data, depth = depth }

    -- 4. Replace the old expanded range (current_visible_size) with the 1 new line
    self:_render_range(idx, current_visible_size, { parent_flat })

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
    local children = self._tree:get_children(id)
    for _, child in ipairs(children) do
        self:collapse_all(child.id)
    end
    local data = self:_get_data(id)
    if not data then return end
    if data.expanded and self._tree:have_children(id) then
        self:collapse(id)
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
            local insert_idx = #self._flat_ids + 1
            local node = {
                id = item.id,
                data = item_data,
                depth = 0
            }
            -- Replacing 0 lines at the end of flat_ids performs an append
            self:_render_range(insert_idx, 0, { node })
        end
        self:_request_children(item.id, item_data)
        return
    end

    -- 3. Handle Child Addition (parent_id exists)
    local parent_idx = self._id_to_idx[parent_id]

    -- If parent isn't in the flattened list, it's inside a collapsed branch
    if not parent_idx then
        self:_request_children(item.id, item_data)
        return
    end

    if buf > 0 then
        -- 4. Re-render Parent (updates icon to expand/collapse char if it was a leaf)
        local parent_data = self._tree:get_data(parent_id)
        local p_depth = self._tree:get_depth(parent_id)
        self:_render_range(parent_idx, 1, { { id = parent_id, data = parent_data, depth = p_depth } })

        -- 5. Render New Child if Parent is Expanded
        if parent_data and parent_data.expanded ~= false then
            -- tree_size(parent_id) now includes the parent + all visible children
            -- (including the one we just logically added via self._tree:add_item)
            local current_subtree_size = self._tree:tree_size(parent_id, _filter)

            -- The new item is the last one in the parent's subtree.
            -- Its position in flat_ids is (parent_start_index + subtree_size - 1)
            local insert_idx = parent_idx + current_subtree_size - 1

            local node = {
                id = item.id,
                data = item_data,
                depth = self._tree:get_depth(item.id)
            }
            -- Replacing 0 lines at insert_idx performs a clean insertion
            self:_render_range(insert_idx, 0, { node })
        end
    end
    self:_request_children(item.id, item_data)
end

---@return loop.comp.TreeBuffer.Item[]
function TreeBuffer:get_children(parent_id)
    local items = {}
    local tree_items = self._tree:get_children(parent_id)

    for _, treeitem in ipairs(tree_items) do
        ---@type loop.comp.TreeBuffer.ItemData
        local data = treeitem.data
        ---@type loop.comp.TreeBuffer.Item
        local item = {
            id = treeitem.id,
            data = data.userdata,
            expanded = data.expanded
        }
        table.insert(items, item)
    end
    return items
end

---@param id any
---@return boolean
function TreeBuffer:have_item(id)
    return self._tree:have_item(id)
end

---Removes a specific item and all its descendants from the tree and buffer.
---@param id any The ID of the item to remove.
---@return boolean success
function TreeBuffer:remove_item(id)
    if not self._tree:have_item(id) then return false end

    local buf = self:get_buf()
    local parent_id = self._tree:get_parent_id(id)

    -- 1. Determine visual impact
    local idx = self._id_to_idx[id]

    local visible_size = 0
    if idx then
        -- Calculate how many lines this item AND its expanded children occupy
        visible_size = self._tree:tree_size(id, _filter)
    end

    -- 2. Update the logical tree
    self._tree:remove_item(id)

    -- 3. Update the Buffer
    if idx and buf > 0 then
        -- We pass an empty table to delete 'visible_size' lines starting at 'idx'
        self:_render_range(idx, visible_size, {})

        -- 4. Re-render the parent to update its icon (it might now be a leaf node)
        if parent_id ~= nil then
            local p_idx = self._id_to_idx[parent_id]
            if p_idx then
                local p_data = self:_get_data(parent_id)
                local p_depth = self._tree:get_depth(parent_id)
                -- Replace just the 1 parent line with its updated self
                self:_render_range(p_idx, 1, { { id = parent_id, data = p_data, depth = p_depth } })
            end
        end
    end

    return true
end

---Removes all children of a node from the tree and updates the buffer.
---@param id any The ID of the parent node whose children should be removed.
---@return boolean success
function TreeBuffer:remove_children(id)
    if not self._tree:have_item(id) then return false end

    -- 1. Determine how many visible lines to remove
    -- We calculate the size of the subtree (excluding the parent itself)
    local visible_subtree_size = self._tree:tree_size(id, _filter) - 1

    -- 2. Update the logical tree
    self._tree:remove_children(id)

    -- 3. Update the Buffer
    local idx = self._id_to_idx[id]

    -- If the node is visible in the buffer, we need to perform surgery
    if idx then
        local data = self:_get_data(id)
        local depth = self._tree:get_depth(id)

        -- We re-render the parent node (at idx) and replace
        -- (1 + visible_subtree_size) lines with just the 1 parent line.
        local node_flat = { id = id, data = data, depth = depth }
        self:_render_range(idx, 1 + visible_subtree_size, { node_flat })
    end

    return true
end

---@param callback loop.comp.TreeBuffer.ChildrenCallback?
function TreeBuffer:set_children_callback(id, callback)
    ---@type loop.comp.TreeBuffer.ItemData?
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

---@param item loop.comp.TreeBuffer.ItemDef
---@return boolean
function TreeBuffer:update_item(item)
    ---@type loop.comp.TreeBuffer.ItemData
    local existing = self._tree:get_data(item.id)
    if not existing then return false end

    -- 1. Update logical data
    existing.userdata = item.data
    existing.children_callback = item.children_callback

    if existing.children_callback then
        existing.reload_children = true
        existing.load_sequence = existing.load_sequence + 1
        -- Note: self:_request_children requires (id, data)
        self:_request_children(item.id, existing)
    else
        self:remove_children(item.id)
    end

    -- 2. Visual Update: Find the node and re-render its line
    local idx = self._id_to_idx[item.id]
    -- If the item is currently visible in the buffer, re-render its line
    if idx then
        local depth = self._tree:get_depth(item.id)
        -- Replace exactly 1 line (the item itself) with its updated version
        self:_render_range(idx, 1, { { id = item.id, data = existing, depth = depth } })
    end

    return true
end

return TreeBuffer
