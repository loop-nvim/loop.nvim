

---@param formatter loop.PreviewFormatter?   (optional custom preview generator)
---@param items loop.SelectorItem[]
---@param cur integer                        current selected index (1-based)
---@param buf integer                        preview buffer handle
---@return fun()? cancel
local function _update_preview(formatter, items, cur, buf)
    -- Guard: no valid item
    local item = items[cur]
    if not item then
        ---@type table?
        local antiflicker_timer = vim.defer_fn(function()
            vim.api.nvim_buf_set_lines(buf, 0, -1, false, {})
            vim.bo[buf].filetype = ""
        end, 200)
        return function()
            antiflicker_timer = fntools.stop_and_close_timer(antiflicker_timer)
        end
    end

    -- ──────────────────────────────────────────────────────────────
    --  File + line → load file contents into the preview buffer
    -- ──────────────────────────────────────────────────────────────
    if item.file then
        local filepath = vim.fs.normalize(item.file)
        local target_lnum = item.lnum and tonumber(item.lnum)
        if vim.fn.filereadable(filepath) ~= 1 then
            vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
                "File not readable:",
                (filepath:gsub("\n", "")),
            })
            vim.bo[buf].filetype = "text"
            return
        end
        local content_set = false
        ---@type table?
        local antiflicker_timer = vim.defer_fn(function()
            if not content_set then
                vim.api.nvim_buf_set_lines(buf, 0, -1, false, {})
            end
        end, 500)
        -- Clear previous content safely
        local cancel_fn = filetools.async_load_text_file(filepath, { max_size = 50 * 1024 * 1024, timeout = 3000 },
            function(load_err, content)
                content_set = true
                if not content then
                    vim.api.nvim_buf_set_lines(buf, 0, -1, false,
                        { ("No preview (%s)"):format(tostring(load_err)) })
                    vim.bo[buf].filetype = "text"
                    return
                end
                -- Instead of split + set_lines:
                local lines = vim.split(content, "\n")
                vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
                vim.api.nvim_buf_set_name(buf, "loopsel://" .. buf .. "/" .. item.file)
                -- Set lines and trigger filetype detection
                vim.api.nvim_buf_call(buf, function()
                    -- Trigger Neovim's filetype detection
                    vim.cmd("filetype detect") -- auto-detects based on buffer name and content
                end)
                if target_lnum and target_lnum > 0 then
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
                    -- Highlight the target line fully (works for single-line too)
                    vim.api.nvim_buf_clear_namespace(buf, NS_PREVIEW, 0, -1)
                    vim.api.nvim_buf_set_extmark(buf, NS_PREVIEW, target_lnum - 1, 0, {
                        end_row = target_lnum, -- makes it "multiline" → enables hl_eol
                        hl_group = "CursorLine",
                        hl_eol = true,
                        hl_mode = "blend",
                    })
                end
            end)
        return function()
            antiflicker_timer = fntools.stop_and_close_timer(antiflicker_timer)
            cancel_fn()
        end
    end

    -- ──────────────────────────────────────────────────────────────
    --  Custom formatter has highest priority
    -- ──────────────────────────────────────────────────────────────
    if formatter then
        local ok, text, ft = pcall(formatter, item.data, item)
        if not ok then
            vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
                "Formatter error:",
                (vim.inspect(text):gsub("\n", "")), -- error message
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