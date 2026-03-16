local picker      = require("loop.tools.picker")
local filetools   = require("loop.tools.file")
local strtools    = require("loop.tools.strtools")
local pickertools = require("loop.tools.pickertools")

local M           = {}

---@mod loop.selector
---@brief Simple floating selector with fuzzy filtering and optional preview.

---@class loop.SelectorItem
---@field label        string?             main displayed text (optional if label_chunks used)
---@field label_chunks {[1]:string, [2]:string?}[]?  optional, allows chunked labels with highlights
---@field file         string?
---@field lnum         number?
---@field virt_lines? {[1]:string, [2]:string?}[][] chunks: { { "text", "HighlightGroup?" }, ... }
---@field data         any                payload returned on select

---@alias loop.SelectorCallback fun(data:any|nil)

---@alias loop.PreviewFormatter fun(data:any):(string, string|nil)
--- Returns preview text and optional filetype

---@class loop.selector.opts
---@field prompt string
---@field items loop.SelectorItem?
---@field file_preview boolean?
---@field formatter loop.PreviewFormatter|nil
---@field initial integer? -- 1-based index into items
---@field list_wrap boolean?

--------------------------------------------------------------------------------
-- Implementation Details
--------------------------------------------------------------------------------

local function _no_op()
end

---@param items loop.SelectorItem[]
---@return number,number
local function _compute_dimentions(items)
    local maxw, height = 0, 0
    for _, item in ipairs(items) do
        if item.label then
            maxw = math.max(maxw, vim.fn.strdisplaywidth(item.label))
            height = height + 1
        end
        if item.label_chunks then
            height = height + 1
            local w = 0
            for _, chunk in ipairs(item.label_chunks) do
                w = w + vim.fn.strdisplaywidth(chunk[1])
            end
            maxw = math.max(maxw, w)
        end
        if item.virt_lines then
            for _, vl in ipairs(item.virt_lines) do
                height = height + 1
                local w = 0
                for _, chunk in ipairs(vl) do
                    w = w + vim.fn.strdisplaywidth(chunk[1])
                end
                maxw = math.max(maxw, w)
            end
        end
    end
    return maxw, height
end
---@param opts loop.selector.opts
---@return loop.Picker.Fetcher
local function _create_fetcher(opts)
    local items = opts.items or {}
    local initial_index = opts.initial or 1

    return function(query)
        local filtered = {}
        local q = query:lower()
        for _, item in ipairs(items) do
            local label = item.label or ""
            if not item.label and item.label_chunks then
                local parts = {}
                for _, chunk in ipairs(item.label_chunks) do
                    if chunk[1] then parts[#parts + 1] = chunk[1] end
                end
                label = table.concat(parts)
            end
            -- fuzzy match returns success, score, positions
            local ok, _, positions = strtools.fuzzy_match(label, q)
            if ok then
                -- build label_chunks for highlighting
                local chunks = item.label_chunks
                if item.label then
                    chunks = {}
                    local last = 0
                    for _, pos in ipairs(positions) do
                        if pos > last + 1 then
                            table.insert(chunks, { label:sub(last + 1, pos - 1) }) -- normal text
                        end
                        table.insert(chunks, { label:sub(pos, pos), "Label" })     -- highlight
                        last = pos
                    end
                    if last < #label then
                        table.insert(chunks, { label:sub(last + 1) })
                    end
                end
                table.insert(filtered, {
                    label_chunks = chunks,
                    virt_lines = item.virt_lines,
                    data = item
                })
            end
        end

        -- return filtered items + initial selection index
        return filtered, initial_index
    end
end

---@param opts loop.selector.opts
---@return loop.Picker.AsyncPreviewLoader|nil
local function _create_previewer(opts)
    if opts.file_preview then
        return function(data, opts, callback)
            return pickertools.default_file_preview(data.file, {
                lnum = data.lnum,
            }, callback)
        end
    end
    if opts.formatter then
        return function(data, _, callback)
            local content, ft = opts.formatter(data.data)
            callback(content, { filetype = ft })
            return _no_op
        end
    end
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

---@param opts loop.selector.opts
---@param callback loop.SelectorCallback
function M.select(opts, callback)
    local list_width, list_height = _compute_dimentions(opts.items)
    local height_ratio
    if not opts.formatter and not opts.file_preview then
        height_ratio = (list_height + 3) / vim.o.lines
    end
    -- Validate and prepare options for the underlying picker
    ---@type loop.Picker.opts
    local picker_opts = {
        prompt        = opts.prompt,
        fetch         = _create_fetcher(opts),
        async_preview = _create_previewer(opts),
        list_width    = list_width,
        list_wrap     = opts.list_wrap,
        height_ratio  = height_ratio
    }

    picker.select(picker_opts, function(item)
        callback(item and item.data)
    end)

    -- Note: 'initial' index support would require modifying loop.picker
    -- to accept an initial query or selection state.
end

return M
