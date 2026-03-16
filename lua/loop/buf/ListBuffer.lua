local class = require('loop.tools.class')
local BaseBuffer = require('loop.buf.BaseBuffer')

---@class loop.comp.ListBuffer.Item
---@field id any
---@field data any

---@class loop.comp.ListBuffer.ItemData
---@field userdata any

---@alias loop.comp.ListBuffer.FormatterFn fun(id:any, data:any):string[][],string[][]

---@class loop.comp.ListBufferOpts
---@field base_opts loop.comp.BaseBufferOpts
---@field formatter loop.comp.ListBuffer.FormatterFn
---@field header string[][]?
---@field current_item_prefix string?

local _ns_id = vim.api.nvim_create_namespace('LoopPluginListBuffer')
local _header_hl_group = "Winbar"

---@class loop.comp.ListBuffer:loop.comp.BaseBuffer
---@field new fun(self:loop.comp.ListBuffer,opts:loop.comp.ListBufferOpts):loop.comp.ListBuffer
local ListBuffer = class(BaseBuffer)

---@param opts loop.comp.ListBufferOpts
function ListBuffer:init(opts)
    BaseBuffer.init(self, opts.base_opts)

    self._formatter = opts.formatter
    self._header = opts.header
    self._prefix = (opts.current_item_prefix or ">") .. " "
    self._current_id = nil

    ---@type table<any, number>
    self._items_map = {}

    ---@type any[]
    self._ids = {}

    ---@type loop.comp.ListBuffer.ItemData[]
    self._items_data = {}

    self:_setup_keymaps()
end

function ListBuffer:_setup_buf()
    BaseBuffer._setup_buf(self)
    self:full_render()
end

function ListBuffer:_setup_keymaps()
    self:add_keymap("<CR>", {
        callback = function()
            local id, data = self:get_cursor_item()
            if id then
                self._trackers:invoke("on_selection", id, data)
            end
        end,
        desc = "Select item"
    })
end

function ListBuffer:_header_offset()
    return self._header and 1 or 0
end

function ListBuffer:_row_for_index(index)
    return (index - 1) + self:_header_offset()
end

---@param id any
---@param data any
---@param row number
---@return string line, table hl_calls, table extmark_data
function ListBuffer:_render_item(id, data, row)
    local hl_calls = {}
    local extmark_data = {}
    local text_chunks, virt = self._formatter(id, data)

    -- Handle Prefix Logic
    local is_current = (id == self._current_id)
    local prefix_text = is_current and self._prefix or string.rep(" ", #self._prefix)

    local current_line = prefix_text
    local col = #prefix_text

    -- Optional: Highlight the prefix itself (e.g., using Statement or CursorLineNr)
    if is_current and #self._prefix > 0 then
        table.insert(hl_calls, { hl = "Statement", row = row, s_col = 0, e_col = col })
    end

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

    if virt and #virt > 0 then
        table.insert(extmark_data, { row, 0, { virt_text = virt, hl_mode = "combine" } })
    end

    return current_line, hl_calls, extmark_data
end

function ListBuffer:full_render()
    local buf = self:get_buf()
    if buf <= 0 then return end

    local buffer_lines = {}
    local extmarks_data = {}
    local hl_calls = {}
    local t_insert = table.insert

    if self._header then
        local row = 0
        local left_text = string.rep(" ", #self._prefix)

        t_insert(extmarks_data, { row, 0, { line_hl_group = _header_hl_group } })

        for _, part in ipairs(self._header) do
            local text, hl = part[1], part[2]
            local start_col = #left_text

            left_text = left_text .. text

            if hl then
                t_insert(hl_calls, { hl = hl, row = row, s_col = start_col, e_col = #left_text })
            end
        end

        t_insert(buffer_lines, left_text)
    end

    for i, id in ipairs(self._ids) do
        local row = self:_row_for_index(i)
        local data = self._items_data[i].userdata

        local line, n_hls, n_exts = self:_render_item(id, data, row)

        t_insert(buffer_lines, line)

        for _, h in ipairs(n_hls) do t_insert(hl_calls, h) end
        for _, e in ipairs(n_exts) do t_insert(extmarks_data, e) end
    end

    vim.api.nvim_buf_clear_namespace(buf, _ns_id, 0, -1)

    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, buffer_lines)
    vim.bo[buf].modifiable = false

    for _, h in ipairs(hl_calls) do
        vim.hl.range(buf, _ns_id, h.hl, { h.row, h.s_col }, { h.row, h.e_col })
    end

    for _, d in ipairs(extmarks_data) do
        vim.api.nvim_buf_set_extmark(buf, _ns_id, d[1], d[2], d[3])
    end
end

---@param items {id: any, data: any}[]
function ListBuffer:set_items(items)
    self._ids = {}
    self._items_map = {}
    self._items_data = {}
    
    for i, item in ipairs(items) do
        self._ids[i] = item.id
        self._items_map[item.id] = i
        self._items_data[i] = { userdata = item.data }
    end

    self:full_render()
end

---@param id any
---@param data any
function ListBuffer:add_item(id, data)
    local buf = self:get_buf()
    if buf <= 0 then return end

    if self._items_map[id] then
        return self:update_item(id, data)
    end

    local index = #self._ids + 1

    table.insert(self._ids, id)
    table.insert(self._items_data, { userdata = data })

    self._items_map[id] = index

    local row = self:_row_for_index(index)

    local line, hl_calls, extmarks = self:_render_item(id, data, row)

    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, row, row, false, { line })
    vim.bo[buf].modifiable = false

    for _, h in ipairs(hl_calls) do
        vim.hl.range(buf, _ns_id, h.hl, { h.row, h.s_col }, { h.row, h.e_col })
    end

    for _, d in ipairs(extmarks) do
        vim.api.nvim_buf_set_extmark(buf, _ns_id, d[1], d[2], d[3])
    end
end

---@param id any
---@param data any
function ListBuffer:update_item(id, data)
    local buf = self:get_buf()
    if buf <= 0 then return end

    local index = self._items_map[id]
    if not index then return end

    self._items_data[index].userdata = data

    local row = self:_row_for_index(index)

    local line, hl_calls, extmarks = self:_render_item(id, data, row)

    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, row, row + 1, false, { line })
    vim.api.nvim_buf_clear_namespace(buf, _ns_id, row, row + 1)
    vim.bo[buf].modifiable = false

    for _, h in ipairs(hl_calls) do
        vim.hl.range(buf, _ns_id, h.hl, { h.row, h.s_col }, { h.row, h.e_col })
    end

    for _, d in ipairs(extmarks) do
        vim.api.nvim_buf_set_extmark(buf, _ns_id, d[1], d[2], d[3])
    end
end

---@param id any
function ListBuffer:remove_item(id)
    local buf = self:get_buf()
    if buf <= 0 then return end

    local index = self._items_map[id]
    if not index then return end

    table.remove(self._ids, index)
    table.remove(self._items_data, index)
    self._items_map[id] = nil

    for i = index, #self._ids do
        self._items_map[self._ids[i]] = i
    end

    local row = self:_row_for_index(index)

    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, row, row + 1, false, {})
    vim.api.nvim_buf_clear_namespace(buf, _ns_id, row, row + 1)
    vim.bo[buf].modifiable = false
end

function ListBuffer:clear()
    self._ids = {}
    self._items_map = {}
    self._items_data = {}
    self:full_render()
end

---@return any id, any data
function ListBuffer:get_cursor_item()
    local winid = vim.fn.bufwinid(self:get_buf())
    if winid <= 0 then return nil, nil end

    local cursor = vim.api.nvim_win_get_cursor(winid)
    local row = cursor[1]

    local index = row - self:_header_offset()

    local id = self._ids[index]
    if not id then return nil, nil end

    return id, self._items_data[index].userdata
end

---@param id any|nil
function ListBuffer:set_current_item(id)
    if self._current_id == id then return end

    local old_id = self._current_id
    self._current_id = id

    -- 1. Refresh the old item to remove its prefix
    if old_id and self._items_map[old_id] then
        local old_data = self._items_data[self._items_map[old_id]].userdata
        self:update_item(old_id, old_data)
    end

    -- 2. Refresh the new item to add its prefix
    if id and self._items_map[id] then
        local new_data = self._items_data[self._items_map[id]].userdata
        self:update_item(id, new_data)
    end
end

function ListBuffer:get_current_item()
    return self._current_id
end

---@return {id: any, data: any}[]
function ListBuffer:get_items()
    local items = {}
    for i, id in ipairs(self._ids) do
        table.insert(items, {
            id = id,
            data = self._items_data[i].userdata
        })
    end
    return items
end

return ListBuffer
