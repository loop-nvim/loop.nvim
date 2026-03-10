local picker    = require("loop.tools.picker")
local filetools = require("loop.tools.file")
local strtools  = require("loop.tools.strtools")

local M         = {}

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
---@param padding integer?
---@return integer
local function _compute_width(items, padding)
    local cols = vim.o.columns
    local maxw = 0

    for _, item in ipairs(items) do
        maxw = math.max(maxw, vim.fn.strdisplaywidth(item.label) + 1)
        if item.virt_lines then
            for _, vl in ipairs(item.virt_lines) do
                local w = 0
                for _, chunk in ipairs(vl) do
                    w = w + vim.fn.strdisplaywidth(chunk[1])
                end
                maxw = math.max(maxw, w + 1)
            end
        end
    end

    local desired = maxw + (padding or 2)
    return math.max(
        math.floor(cols * 0.2),
        math.min(math.floor(cols * 0.8), desired)
    )
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
    -- If preview is disabled entirely, return nil
    if not opts.file_preview and not opts.formatter then
        return nil
    end

    return function(item_data, _, callback)
        local data = item_data.data -- Access the original item structure

        -- 1. Use Formatter if provided
        if opts.formatter then
            local content, ft = opts.formatter(data)
            callback(content, { filetype = ft })
            return _no_op
        end

        -- 2. Fallback to Async File Loader if filepath exists
        if data.filepath or data.file then
            local path = data.filepath or data.file
            local cancel_fn = filetools.async_load_text_file(
                path,
                { max_size = 50 * 1024 * 1024, timeout = 3000 },
                function(_, content)
                    callback(content, {
                        filepath = path,
                        lnum = data.lnum,
                        col = data.col
                    })
                end
            )
            return cancel_fn
        end

        -- 3. No preview available for this item
        callback(nil)
        return _no_op
    end
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

---@param opts loop.selector.opts
---@param callback loop.SelectorCallback
function M.select(opts, callback)
    local width_ratio
    if not opts.file_preview and not opts.formatter then
        local width = _compute_width(opts.items)
        width_ratio = width / vim.o.columns
    end
    -- Validate and prepare options for the underlying picker
    local picker_opts = {
        prompt        = opts.prompt,
        fetch         = _create_fetcher(opts),
        async_preview = _create_previewer(opts),
        width_ratio   = width_ratio,
        list_wrap     = opts.list_wrap,
    }

    picker.select(picker_opts, callback)

    -- Note: 'initial' index support would require modifying loop.picker
    -- to accept an initial query or selection state.
end

return M
