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

local M = {}

local NS_PREVIEW = vim.api.nvim_create_namespace("LoopSelectorPreview")
local NS_VIRT = vim.api.nvim_create_namespace("LoopSelectorVirtText")

--------------------------------------------------------------------------------
-- Utility functions
--------------------------------------------------------------------------------

---@param items loop.SelectorItem[]
---@param query string
---@return loop.SelectorItem[]
local function fuzzy_filter(items, query)
    if query == "" then
        return vim.deepcopy(items)
    end

    local q = query:lower()
    local res = {}

    for _, item in ipairs(items) do
        if item.label:lower():find(q, 1, true) then
            res[#res + 1] = item
        end
    end

    return res
end

---@param items loop.SelectorItem[]
---@param cur integer
---@param buf integer
---@param win integer
local function update_list(items, cur, buf, win)
    local lines = {}
    local extmarks = {}
    local virt_extmarks = {}
    for i, item in ipairs(items) do
        local prefix = (i == cur) and "> " or "  "
        -- ----------------------------
        -- Efficiently build display_label from label_chunks
        -- ----------------------------
        lines[i] = prefix .. item.label
        -- ----------------------------
        -- Inline highlights
        -- ----------------------------
        local col = #prefix
        if item.label_chunks then
            for _, chunk in ipairs(item.label_chunks) do
                local text, hl = chunk[1], chunk[2]
                if text and #text > 0 then
                    local len = #text
                    if hl then
                        extmarks[#extmarks + 1] = {
                            row       = i - 1,
                            col_start = col,
                            col_end   = col + len,
                            hl_group  = hl
                        }
                    end
                    col = col + len
                end
            end
        end
        -- ----------------------------
        -- Virtual text
        -- ----------------------------
        if item.virt_lines and #item.virt_lines > 0 then
            local space = (" "):rep(vim.fn.strdisplaywidth(prefix))
            local vlines = {}
            for _, line in ipairs(item.virt_lines) do
                local vl = { { space } }
                vim.list_extend(vl, line)
                table.insert(vlines, vl)
            end
            virt_extmarks[#virt_extmarks + 1] = {
                row  = i - 1,
                col  = 0,
                opts = { virt_lines = vlines, hl_mode = "blend" }
            }
        end
    end
    vim.api.nvim_buf_clear_namespace(buf, NS_VIRT, 0, -1)
    -- Apply lines
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    -- Apply inline highlights
    for _, mark in ipairs(extmarks) do
        vim.api.nvim_buf_set_extmark(buf, NS_VIRT, mark.row, mark.col_start, {
            end_col  = mark.col_end,
            hl_group = mark.hl_group,
        })
    end
    -- Apply virtual text extmarks
    for _, mark in ipairs(virt_extmarks) do
        vim.api.nvim_buf_set_extmark(buf, NS_VIRT, mark.row, mark.col, mark.opts)
    end
    -- Move cursor
    if vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_set_cursor(win, { math.max(cur, 1), 0 })
        vim.api.nvim_win_call(win, function()
            vim.cmd("normal! zb")
        end)
    end
end

---@param formatter loop.PreviewFormatter?   (optional custom preview generator)
---@param items loop.SelectorItem[]
---@param cur integer                        current selected index (1-based)
---@param buf integer                        preview buffer handle
local function update_preview(formatter, items, cur, buf)
    -- Guard: no valid item
    local item = items[cur]
    if not item then
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "No selection" })
        vim.bo[buf].filetype = ""
        return
    end

    -- ──────────────────────────────────────────────────────────────
    --  File + line → load file contents into the preview buffer
    -- ──────────────────────────────────────────────────────────────
    if item.file and item.lnum then
        local filepath = vim.fs.normalize(item.file)
        local target_lnum = tonumber(item.lnum)

        if vim.fn.filereadable(filepath) ~= 1 then
            vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
                "File not readable:",
                filepath,
            })
            vim.bo[buf].filetype = "text"
            return
        end

        if not target_lnum or target_lnum < 1 then
            vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
                "Invalid line number:",
                filepath .. ":" .. tostring(item.lnum),
            })
            vim.bo[buf].filetype = "text"
            return
        end

        -- Clear previous content safely
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, {})

        local lines = {}
        -- Load file contents into the buffer using :read (most "native" way)
        local ok, load_err = pcall(function()
            lines = vim.fn.readfile(filepath)
        end)
        if not ok then
            vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
                "Failed to load file into preview buffer:",
                vim.inspect(load_err),
            })
            vim.bo[buf].filetype = "text"
            return
        end

        vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

        -- Enable syntax highlighting
        vim.bo[buf].filetype = vim.filetype.match({ filename = filepath }) or "text"

        if target_lnum > #lines then
            return
        end

        -- Try to position cursor / view at target line
        local preview_win = vim.fn.bufwinid(buf)
        if preview_win ~= -1 then
            local set_ok = pcall(vim.api.nvim_win_set_cursor, preview_win, { target_lnum, 0 })
            if set_ok then
                vim.api.nvim_win_call(preview_win, function()
                    vim.cmd("normal! zz") -- center the target line
                end)
            else
                -- Line might be out of range → fall back to first line
                pcall(vim.api.nvim_win_set_cursor, preview_win, { 1, 0 })
            end
        end

        -- Brief visual feedback: highlight target line
        pcall(vim.api.nvim_buf_clear_namespace, buf, NS_PREVIEW, 0, -1)
        -- Highlight the target line fully (works for single-line too)
        vim.api.nvim_buf_set_extmark(buf, NS_PREVIEW, target_lnum - 1, 0, {
            end_row = target_lnum, -- makes it "multiline" → enables hl_eol
            hl_group = "CursorLine",
            hl_eol = true,
            hl_mode = "blend",
        })
        return
    end

    -- ──────────────────────────────────────────────────────────────
    --  Custom formatter has highest priority
    -- ──────────────────────────────────────────────────────────────
    if formatter then
        local ok, text, ft = pcall(formatter, item.data, item)
        if not ok then
            vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
                "Formatter error:",
                vim.inspect(text), -- error message
            })
            vim.bo[buf].filetype = "lua"
            return
        end

        local lines = type(text) == "string" and vim.split(text, "\n") or { "<empty preview>" }
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
        vim.bo[buf].filetype = ft or ""
        return
    end


    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {})
    vim.bo[buf].filetype = ""
end

---@param items loop.SelectorItem[]
---@param query string
---@param cur integer
---@return loop.SelectorItem[], integer
local function recompute(items, query, cur)
    local filtered = fuzzy_filter(items, query)
    if #filtered == 0 then
        return filtered, 1
    end
    return filtered, math.min(cur, #filtered)
end

---@param max integer
---@param cur integer
---@param delta integer
---@return integer
local function move_wrap(max, cur, delta)
    if max == 0 then
        return cur
    end
    return ((cur - 1 + delta) % max) + 1
end

---@param max integer
---@param cur integer
---@param delta integer
---@return integer
local function move_clamp(max, cur, delta)
    if max == 0 then
        return cur
    end
    return math.min(max, math.max(1, cur + delta))
end

---@param items loop.SelectorItem[]
---@param padding integer?
---@return integer
local function compute_width(items, padding)
    local cols = vim.o.columns
    local maxw = 0

    for _, item in ipairs(items) do
        maxw = math.max(maxw, vim.fn.strdisplaywidth(item.label))
        if item.virt_lines then
            for _, vl in ipairs(item.virt_lines) do
                local w = 0
                for _, chunk in ipairs(vl) do
                    w = w + vim.fn.strdisplaywidth(chunk[1])
                end
                maxw = math.max(maxw, w)
            end
        end
    end

    local desired = maxw + (padding or 2)
    return math.max(
        math.floor(cols * 0.2),
        math.min(math.floor(cols * 0.8), desired)
    )
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

---@class loop.selector.opts
---@field prompt string
---@field items loop.SelectorItem[]
---@field file_preview boolean?
---@field formatter loop.PreviewFormatter|nil
---@field callback loop.SelectorCallback
---@field initial integer? -- 1-based index into items
---@field list_wrap boolean?

---@param opts loop.selector.opts
function M.select(opts)
    local prompt, items, formatter, callback = opts.prompt, opts.items, opts.formatter, opts.callback
    if #items == 0 then
        return
    end
    local title = (prompt and prompt ~= "") and (" %s "):format(prompt) or ""
    local has_preview = opts.file_preview or type(opts.formatter) == "function"

    -- Precompute label from label_chunks
    for _, item in ipairs(items) do
        if item.label_chunks and #item.label_chunks > 0 then
            item.label = table.concat(vim.tbl_map(function(c) return c[1] end, item.label_chunks))
        end
    end
    --------------------------------------------------------------------------
    -- Layout
    --------------------------------------------------------------------------

    local cols = vim.o.columns - 2
    local lines = vim.o.lines
    local spacing = has_preview and 2 or 0

    local max_list_w = math.max(1, (has_preview and math.floor(cols * 0.5) or cols) - spacing)
    local max_prev_w = has_preview and math.floor(cols * 0.4) - spacing or 0

    local list_w = math.min(max_list_w, compute_width(items, 2))

    local preview_w = has_preview and math.max(1, math.min(cols - max_list_w, cols - list_w, max_prev_w)) or 0
    local width = list_w + spacing + preview_w

    local height = math.max(
        math.floor(lines * 0.5),
        math.min(math.floor(lines * 0.8), #items + 2)
    )

    local row = math.floor((lines - height) / 2)
    local col = math.floor((cols - width) / 2)

    --------------------------------------------------------------------------
    -- Buffers & windows
    --------------------------------------------------------------------------

    local pbuf = vim.api.nvim_create_buf(false, true)
    local lbuf = vim.api.nvim_create_buf(false, true)
    local vbuf = has_preview and vim.api.nvim_create_buf(false, true) or nil


    for _, b in ipairs({ pbuf, lbuf, vbuf }) do
        if b then
            vim.bo[b].buftype = "nofile"
            vim.bo[b].bufhidden = "delete"
        end
    end

    vim.cmd("highlight default LoopTransparentBorder guibg=NONE")

    local base_cfg = {
        relative = "editor",
        style = "minimal",
        border = "rounded",
    }

    local pwin = vim.api.nvim_open_win(pbuf, true, vim.tbl_extend("force", base_cfg, {
        row = row - 3,
        col = col,
        width = width,
        height = 1,
        title = title,
        title_pos = "center"
    }))

    local lwin = vim.api.nvim_open_win(lbuf, false, vim.tbl_extend("force", base_cfg, {
        row = row,
        col = col,
        width = list_w,
        height = height,
    }))

    local vwin
    if vbuf then
        vwin = vim.api.nvim_open_win(vbuf, false, vim.tbl_extend("force", base_cfg, {
            row = row,
            col = col + list_w + spacing,
            width = preview_w,
            height = height,
        }))
        vim.wo[vwin].wrap = true
    end

    vim.wo[pwin].wrap = false
    
    vim.wo[lwin].wrap = opts.list_wrap ~= false
    vim.wo[lwin].scrolloff = 0

    local winhl = "NormalFloat:Normal,FloatBorder:LoopTransparentBorder,CursorLine:Visual"
    for _, w in ipairs({ pwin, lwin, vwin }) do
        if w then
            vim.wo[w].winhighlight = winhl
        end
    end

    --------------------------------------------------------------------------
    -- State
    --------------------------------------------------------------------------

    local filtered = vim.deepcopy(items)
    local cur = math.max(1, math.min(opts.initial or 1, #items))
    local closed = false

    local function close(result)
        if closed then return end
        closed = true
        if vim.api.nvim_get_current_win() == pwin then
            vim.cmd("stopinsert")
        end
        vim.schedule(function()
            for _, w in ipairs({ pwin, lwin, vwin }) do
                if w and vim.api.nvim_win_is_valid(w) then
                    vim.api.nvim_win_close(w, true)
                end
            end
            if result ~= nil then
                vim.schedule(function()
                    callback(result)
                end)
            end
        end)
    end

    local function update_content()
        update_list(filtered, cur, lbuf, lwin)
        if vbuf then update_preview(formatter, filtered, cur, vbuf) end
    end

    local key_opts = { buffer = pbuf, nowait = true, silent = true }

    vim.keymap.set("i", "<CR>", function()
        close(filtered[cur] and filtered[cur].data)
    end, key_opts)

    vim.keymap.set("i", "<Esc>", function() close(nil) end, key_opts)
    vim.keymap.set("i", "<C-c>", function() close(nil) end, key_opts)

    vim.keymap.set("i", "<Down>", function()
        cur = move_wrap(#filtered, cur, 1)
        update_content()
    end, key_opts)

    vim.keymap.set("i", "<C-n>", function()
        cur = move_wrap(#filtered, cur, 1)
        update_content()
    end, key_opts)

    vim.keymap.set("i", "<Up>", function()
        cur = move_wrap(#filtered, cur, -1)
        update_content()
    end, key_opts)

    vim.keymap.set("i", "<C-p>", function()
        cur = move_wrap(#filtered, cur, -1)
        update_content()
    end, key_opts)

    local page = math.max(1, math.floor(height / 2))
    vim.keymap.set("i", "<C-d>", function()
        cur = move_clamp(#filtered, cur, page)
        update_content()
    end, key_opts)

    vim.keymap.set("i", "<C-u>", function()
        cur = move_clamp(#filtered, cur, -page)
        update_content()
    end, key_opts)

    vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
        buffer = pbuf,
        callback = function()
            if vim.api.nvim_buf_line_count(pbuf) == 0 then
                vim.api.nvim_buf_set_lines(pbuf, 0, -1, false, { "" })
            end

            local plines = vim.api.nvim_buf_get_lines(pbuf, 0, -1, false)
            local query = plines[1] or ""
            -- now recompute filtered list
            filtered, cur = recompute(items, query, cur)
            update_content()
        end,
    })

    vim.api.nvim_create_autocmd("BufLeave", {
        buffer = pbuf,
        once = true,
        callback = function() close(nil) end,
    })

    vim.api.nvim_set_current_win(pwin)
    vim.schedule(function()
        if vim.api.nvim_win_is_valid(pwin)
            and vim.api.nvim_get_current_win() == pwin
            and vim.fn.mode() ~= "i" then
            vim.cmd("startinsert!")
        end
    end)

    update_content()
end

return M
