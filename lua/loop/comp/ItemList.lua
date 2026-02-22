local class = require('loop.tools.class')
local Trackers = require("loop.tools.Trackers")

---@class loop.comp.ItemList.Item
---@field id any
---@field data any

---@class loop.comp.ItemList.Tracker
---@field on_selection? fun(id:any,data:any)
---@field on_open? fun(id:any,data:any)

local _ns_id = vim.api.nvim_create_namespace('LoopPluginItemListComp')

---@alias loop.comp.ItemList.Chunk { [1]: string, [2]: string? }

---@class loop.comp.ItemList.InitArgs
---@field formatter fun(id:any,data): loop.comp.ItemList.Chunk[]
---@field render_delay_ms number|nil
---@field show_current_prefix boolean|nil            # NEW: whether to show ">" prefix on current item
---@field current_prefix string|nil                  # NEW: custom prefix, defaults to "⇒ "
---@field allow_selection boolean?

---@class loop.comp.ItemList
---@field new fun(self: loop.comp.ItemList, args:loop.comp.ItemList.InitArgs): loop.comp.ItemList
---@field _args loop.comp.ItemList.InitArgs
---@field _items loop.comp.ItemList.Item[]
---@field _index table<any,number>
---@field _select_handler fun(item:loop.comp.ItemList.Item|nil)
---@field _trackers loop.tools.Trackers<loop.comp.ItemList.Tracker>
---@field _current_item loop.comp.ItemList.Item|nil   # NEW: currently active item
---@field _current_prefix string                            # NEW: resolved prefix
---@field _linked_buf loop.CompBufferController|nil
local ItemList = class()

---@param args loop.comp.ItemList.InitArgs
function ItemList:init(args)
    assert(args.formatter)
    self._args = args
    self._items = {}
    self._index = {}

    self._trackers = Trackers:new()

    -- NEW: current item tracking
    self._current_item = nil
    if args.show_current_prefix then
        self._current_prefix = (args.current_prefix or ">") .. " "
        self._noncurrent_prefix = (" "):rep(vim.fn.strdisplaywidth(self._current_prefix))
    end
end

---@param buf_ctrl loop.CompBufferController
function ItemList:link_to_buffer(buf_ctrl)
    local get_cur_item = function()
        local cursor = buf_ctrl:get_cursor()
        if not cursor then return nil end
        local row = cursor[1]
        return self._items[row]
    end

    self._linked_buf = buf_ctrl
    self._linked_buf.set_renderer({
        render = function(bufnr)
            return self:render(bufnr)
        end,
        dispose = function()
            return self:dispose()
        end
    })

    local select_handler = function()
        local item = get_cur_item()
        if item then
            self:_set_current_item(item) -- will trigger prefix update if enabled
            self._trackers:invoke("on_selection", item.id, item.data)
        end
    end

    local open_handler = function()
        local item = get_cur_item()
        if item then
            self._trackers:invoke("on_open", item.id, item.data)
        end
    end

    if self._args.allow_selection then
        self._linked_buf.add_keymap('<CR>', { callback = select_handler, desc = "Select item" })
        self._linked_buf.add_keymap('<2-LeftMouse>', { callback = select_handler, desc = "Select item" })
    end

    self._linked_buf.add_keymap('go', { callback = open_handler, desc = "Open details" })

    buf_ctrl:request_refresh()
end

-- NEW: Public API to set current item (used by selection, or externally)
---@param item loop.comp.ItemList.Item|nil
function ItemList:_set_current_item(item)
    if self._current_item == item then return end
    self._current_item = item
    if self._args.show_current_prefix then
        self:refresh_content() -- rebuild lines with updated prefixes
    end
end

function ItemList:dispose()
end

---@param id any
function ItemList:set_current_id(id)
    self:_set_current_item(self:get_item(id))
end

-- NEW: Get current item (cursor fallback if none explicitly set)
---@return loop.comp.ItemList.Item|nil
function ItemList:get_current_item()
    return self._current_item
end

---@param callbacks loop.comp.ItemList.Tracker
---@return loop.TrackerRef
function ItemList:add_tracker(callbacks) return self._trackers:add_tracker(callbacks) end

---@param items loop.comp.ItemList.Item[]
function ItemList:set_items(items)
    self._items = items
    self._index = {}
    for i, item in ipairs(items) do
        assert(not self._index[item.id], "duplicate item id")
        self._index[item.id] = i
    end
    -- Reset current item if it's no longer in the list
    if self._current_item and not self._index[self._current_item.id] then
        self._current_item = nil
    end
    self:_request_render()
end

---@param item loop.comp.ItemList.Item
---@param opts {index:number}|nil
function ItemList:upsert_item(item, opts)
    assert(item and item.id and item.data)

    local idx = self._index[item.id]
    if idx then
        -- Update existing item
        self._items[idx] = item
    else
        -- Insert new item
        if opts and opts.index and opts.index >= 1 and opts.index <= #self._items + 1 then
            table.insert(self._items, opts.index, item)
            -- Rebuild _index after insertion
            for i, it in ipairs(self._items) do
                self._index[it.id] = i
            end
        else
            -- Append to the end
            idx = #self._items + 1
            self._items[idx] = item
            self._index[item.id] = idx
        end
    end

    -- If this item is the current one, keep reference stable
    if self._current_item and self._current_item.id == item.id then
        self._current_item = item
    end

    self:_request_render()
end

---@return loop.comp.ItemList.Item[]
function ItemList:get_items()
    return self._items
end

---@param id any
---@return loop.comp.ItemList.Item
function ItemList:get_item(id)
    local idx = self._index[id]
    return idx and self._items[idx] or nil
end

---@param id any
function ItemList:remove_item(id)
    local idx = self._index[id]
    if not idx then return end

    if self._current_item and self._current_item.id == id then
        self._current_item = nil
    end

    table.remove(self._items, idx)
    self._index[id] = nil
    for i = idx, #self._items do
        self._index[self._items[i].id] = i
    end

    self:_request_render()
end

function ItemList:clear_items()
    self._items = {}
    self._index = {}
    self:_request_render()
end

---@param buf number
---@return boolean
function ItemList:render(buf)
    vim.api.nvim_buf_clear_namespace(buf, _ns_id, 0, -1)

    local lines = {}
    local extmarks = {}

    for _, item in ipairs(self._items) do
        local chunks = self._args.formatter(item.id, item.data) or {}

        -- prefix (current / non-current)
        local prefix = ""
        if self._args.show_current_prefix then
            if self._current_item and self._current_item.id == item.id then
                prefix = self._current_prefix
            else
                prefix = self._noncurrent_prefix
            end
        end

        local line = prefix
        local col = #prefix
        local hls = {}
        for _, chunk in ipairs(chunks) do
            local text = chunk[1]
            local highlight = chunk[2]

            text = (text or ""):gsub("\n", " ")
            local start_col = col

            line = line .. text
            col = col + #text

            if highlight and #text > 0 then
                table.insert(hls, {
                    start_col = start_col,
                    end_col = col,
                    group = highlight,
                })
            end
        end

        table.insert(lines, line)

        local row = #lines - 1

        for _, hl in ipairs(hls) do
            table.insert(extmarks, {
                row = row,
                start_col = hl.start_col,
                mark = {
                    end_col = hl.end_col,
                    hl_group = hl.group,
                    priority = 200,
                }
            })
        end
    end

    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false

    for _, m in ipairs(extmarks) do
        vim.api.nvim_buf_set_extmark(buf, _ns_id, m.row, m.start_col, m.mark)
    end

    return true
end

function ItemList:_request_render()
    if self._linked_buf then
        self._linked_buf.request_refresh()
    end
end

function ItemList:refresh_content()
    self:_request_render()
end

return ItemList
