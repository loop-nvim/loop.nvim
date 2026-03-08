local filetools  = require("loop.tools.file")
local fntools    = require('loop.tools.fntools')
local throttle   = require('loop.tools.throttle')
local strtools   = require('loop.tools.strtools')

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

local M          = {}

local NS_PREVIEW = vim.api.nvim_create_namespace("LoopSelectorPreview")
local NS_VIRT    = vim.api.nvim_create_namespace("LoopSelectorVirtText")

--------------------------------------------------------------------------------
-- Utility functions
--------------------------------------------------------------------------------

---@param items loop.SelectorItem[]
---@param query string
---@return loop.SelectorItem[]
local function _fuzzy_filter(items, query)
    if query == "" then
        return items
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

---@param pbuf number
---@param total number
---@param cur number
local function _update_pos_hint(pbuf, total, cur)
    vim.api.nvim_buf_clear_namespace(pbuf, NS_VIRT, 0, -1)
    -- Right-padded virtual count (Telescope-style)
    if total > 0 then
        local count_text = string.format("%d/%d", cur, total)
        -- Set virtual text on the first line of the list window (prompt line is usually separate)
        vim.api.nvim_buf_set_extmark(pbuf, NS_VIRT, 0, 0, {
            virt_text = { { count_text, "Comment" } }, -- highlight group
            virt_text_pos = "right_align",
            hl_mode = "blend",
        })
    end
end

---@param items loop.SelectorItem[]
---@param cur integer
---@param buf integer
---@param win integer
---@param list_width number
local function _update_list(items, cur, buf, win, list_width)
    local lines = {}
    local extmarks = {}
    local virt_extmarks = {}
    local prefix_space = "  "
    for i, item in ipairs(items) do
        local prefix = (i == cur) and "> " or prefix_space
        -- ----------------------------
        -- Efficiently build display_label from label_chunks
        -- ----------------------------
        lines[i] = prefix .. strtools.smart_crop_path((item.label:gsub("\n", "")), list_width - 3)
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
            local vlines = {}
            for _, line in ipairs(item.virt_lines) do
                local vl = { { prefix_space } }
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
            local cursor_line = vim.fn.winline()
            local win_height = vim.api.nvim_win_get_height(0)

            if cursor_line < 1 then
                vim.cmd("normal! zt") -- scroll cursor to top
            elseif cursor_line >= win_height then
                local item = items[cursor_line]
                local extra_lines = item and item.virt_lines and #item.virt_lines or 0
                if extra_lines > 0 then
                    -- Scroll enough to show extra virtual lines
                    local scroll_count = math.min(extra_lines, win_height - 1)
                    vim.cmd(string.format("normal! %dzb", scroll_count))
                else
                    vim.cmd("normal! zb") -- scroll cursor to bottom
                end
            end
        end)
    end
end

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
        end, 500)
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
                        { ("Failed to load preview (%s)"):format(tostring(load_err)) })
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

---@param max integer
---@param cur integer
---@param delta integer
---@return integer
local function _move_wrap(max, cur, delta)
    if max <= 0 then return 1 end
    -- Standard 1-based modulo wrapping
    local result = ((cur - 1 + delta) % max) + 1
    return result < 1 and max or result
end

---@param max integer
---@param cur integer
---@param delta integer
---@return integer
local function _move_clamp(max, cur, delta)
    if max == 0 then
        return cur
    end
    return math.min(max, math.max(1, cur + delta))
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

---@param items loop.SelectorItem[]
local function _process_labels(items)
    -- Precompute label from label_chunks
    for _, item in ipairs(items) do
        if item.label_chunks and #item.label_chunks > 0 then
            item.label = table.concat(vim.tbl_map(function(c) return c[1] end, item.label_chunks))
        end
        if item.label then
            item.label = item.label:gsub("\n", "")
        else
            item.label = ""
        end
    end
end

---@class loop.SelectorLayout
---@field prompt_row number
---@field prompt_col number
---@field prompt_width number
---@field prompt_height number
---@field list_row number
---@field list_col number
---@field list_width number
---@field list_height number
---@field prev_row number
---@field prev_col number
---@field prev_width number
---@field prev_height number

---@param items loop.SelectorItem[]
---@param opts {has_preview:boolean,height_ratio:number?,width_ratio:number?,list_ratio:number?}
---@return loop.SelectorLayout
local function _compute_horizontal_layout(items, opts)
    local cols        = vim.o.columns
    local lines       = vim.o.lines

    local has_preview = opts.has_preview
    local spacing     = has_preview and 2 or 0

    local function clamp(v, min, max)
        return math.max(min, math.min(max, v))
    end
    -------------------------------------------------
    -- WIDTH COMPUTATION
    -------------------------------------------------
    local width
    local list_width
    local prev_width = 0

    local ratio_mode = opts.height_ratio ~= nil or opts.width_ratio ~= nil or opts.list_ratio ~= nil

    if ratio_mode then
        -- ratio mode (ignore items)
        local container_ratio = clamp(opts.width_ratio or 0.8, 0, 1)
        width = math.floor(cols * container_ratio)

        local list_ratio = clamp(opts.list_ratio or (has_preview and 0.5 or 1), 0, 1)
        list_width = math.floor(width * list_ratio)

        if has_preview then
            prev_width = clamp(width - list_width - spacing, 1, width)
        end
    else
        -- dynamic mode
        if has_preview then
            prev_width = math.floor(cols / 3)
        end

        if #items > 0 then
            list_width = _compute_width(items, 2)
        else
            list_width = math.floor(cols / 3)
        end

        width = list_width + spacing + prev_width
    end

    list_width = clamp(list_width, 1, cols)
    prev_width = clamp(prev_width, 0, cols)

    local used_width = list_width + spacing + prev_width

    -------------------------------------------------
    -- HEIGHT
    -------------------------------------------------

    local height_ratio = clamp(opts.height_ratio or .7, 0, 1)
    local height = math.floor(lines * height_ratio)

    if not ratio_mode and #items > 0 then
        height = math.min(height, #items + 2)
    end

    height = clamp(height, math.floor(lines * 0.3), lines)

    -------------------------------------------------
    -- CENTERING
    -------------------------------------------------

    local total_height = height + 3
    local row = math.floor((lines - total_height) / 2)
    local col = math.floor((cols - used_width) / 2)

    local list_row = row + 3
    local max_height = lines - list_row
    height = clamp(height, 1, max_height)

    -------------------------------------------------

    ---@type loop.SelectorLayout
    return {
        prompt_row = row,
        prompt_col = col,
        prompt_width = used_width,
        prompt_height = 1,

        list_row = list_row,
        list_col = col,
        list_width = list_width,
        list_height = height,

        prev_row = list_row,
        prev_col = col + list_width + spacing,
        prev_width = prev_width,
        prev_height = height,
    }
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

---@class loop.selector.AsyncFetcherOpts
---@field list_width number
---@fiel list_height number

---@alias loop.selector.AsyncFetcher (fun(query:string,  opts:loop.selector.AsyncFetcherOpts, callback:fun(new_items:loop.SelectorItem[])):fun())?

---@class loop.selector.opts
---@field prompt string
---@field items loop.SelectorItem?
---@field async_fetch loop.selector.AsyncFetcher?
---@field file_preview boolean?
---@field formatter loop.PreviewFormatter|nil
---@field initial integer? -- 1-based index into items
---@field height_ratio number?
---@field width_ratio number?
---@field preview_ratio number?
---@field list_wrap boolean?

---@param opts loop.selector.opts
---@param callback loop.SelectorCallback
function M.select(opts, callback)
    local prompt, formatter = opts.prompt, opts.formatter
    if (not opts.items or #opts.items == 0) and not opts.async_fetch then
        return
    end

    local title = (prompt and prompt ~= "") and (" %s "):format(prompt) or ""
    local has_preview = opts.file_preview or type(opts.formatter) == "function"

    local original_items = opts.items or {}
    _process_labels(original_items)

    --------------------------------------------------------------------------
    -- Layout
    --------------------------------------------------------------------------
    local layout = _compute_horizontal_layout(original_items, -- use original items
        {
            has_preview = has_preview,
            height_ratio = opts.height_ratio,
            width_ratio = opts.width_ratio,
            preview_ratio = opts.preview_ratio,
        })

    --------------------------------------------------------------------------
    -- Buffers & windows
    --------------------------------------------------------------------------

    local pbuf = vim.api.nvim_create_buf(false, true)
    local lbuf = vim.api.nvim_create_buf(false, true)
    local vbuf = has_preview and vim.api.nvim_create_buf(false, true) or nil


    for _, b in ipairs({ pbuf, lbuf, vbuf }) do
        if b then
            vim.bo[b].buftype = "nofile"
            vim.bo[b].bufhidden = "wipe"
            vim.bo[b].undolevels = -1
            vim.bo[b].swapfile = false
        end
    end

    vim.cmd("highlight default LoopTransparentBorder guibg=NONE")

    local base_cfg = {
        relative = "editor",
        style = "minimal",
        border = "rounded",
    }

    local pwin = vim.api.nvim_open_win(pbuf, true, vim.tbl_extend("force", base_cfg, {
        row = layout.prompt_row,
        col = layout.prompt_col,
        width = layout.prompt_width,
        height = layout.prompt_height,
        title = title,
        title_pos = "center"
    }))

    local lwin = vim.api.nvim_open_win(lbuf, false, vim.tbl_extend("force", base_cfg, {
        row = layout.list_row,
        col = layout.list_col,
        width = layout.list_width,
        height = layout.list_height,
    }))

    local vwin
    if vbuf then
        vwin = vim.api.nvim_open_win(vbuf, false, vim.tbl_extend("force", base_cfg, {
            row = layout.prev_row,
            col = layout.prev_col,
            width = layout.prev_width,
            height = layout.prev_height,
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

    local query = "" ---@type string
    local items = original_items ---@type loop.SelectorItem[]
    local filtered = items ---@type loop.SelectorItem[]
    local cur = math.max(1, math.min(opts.initial or 1, #items))
    local closed = false
    local async_preview_cancel
    local async_fetch_cancel
    local vimreisze_autocmd_id

    local function close(result)
        if vimreisze_autocmd_id then
            vim.notify("deleted resize auto cmd")
            vim.api.nvim_del_autocmd(vimreisze_autocmd_id)
            vimreisze_autocmd_id = nil
        end
        if async_preview_cancel then
            async_preview_cancel()
            async_preview_cancel = nil
        end
        if async_fetch_cancel then
            async_fetch_cancel()
            async_fetch_cancel = nil
        end
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

    local last_preview_item = nil
    local function update_content()
        if vim.api.nvim_buf_is_valid(pbuf) then
            _update_pos_hint(pbuf, #filtered, cur)
        end
        if vim.api.nvim_buf_is_valid(lbuf) and vim.api.nvim_win_is_valid(lwin) then
            _update_list(filtered, cur, lbuf, lwin, layout.list_width)
        end
        if vbuf and vim.api.nvim_buf_is_valid(vbuf) then
            local item = filtered[cur]
            if item == last_preview_item then
                return
            end
            last_preview_item = item
            if async_preview_cancel then
                async_preview_cancel()
                async_preview_cancel = nil
            end
            async_preview_cancel = _update_preview(formatter, filtered, cur, vbuf)
        end
    end

    local refilter = throttle.trailing_fixed_wrap(100,
        function()
            if not closed then
                filtered = _fuzzy_filter(items, query)
                cur = math.min(cur, #filtered)
                update_content()
            end
        end)

    local function on_vim_resize()
        assert(not closed)
        -- 1. Recalculate layout based on new screen dimensions
        layout = _compute_horizontal_layout(original_items, {
            has_preview = has_preview,
            height_ratio = opts.height_ratio,
            width_ratio = opts.width_ratio,
            preview_ratio = opts.preview_ratio,
        })
        -- 2. Apply new config to windows
        local wins = {
            { win = pwin, row = layout.prompt_row, col = layout.prompt_col, w = layout.prompt_width, h = layout.prompt_height },
            { win = lwin, row = layout.list_row,   col = layout.list_col,   w = layout.list_width,   h = layout.list_height },
        }
        if vwin and vim.api.nvim_win_is_valid(vwin) then
            table.insert(wins,
                {
                    win = vwin,
                    row = layout.prev_row,
                    col = layout.prev_col,
                    w = layout.prev_width,
                    h = layout
                        .prev_height
                })
        end
        for _, cfg in ipairs(wins) do
            if vim.api.nvim_win_is_valid(cfg.win) then
                vim.api.nvim_win_set_config(cfg.win, {
                    relative = "editor", row = cfg.row, col = cfg.col, width = cfg.w, height = cfg.h,
                })
            end
        end
        -- Update content to ensure virtual text and list are correctly positioned
        update_content()
    end

    vimreisze_autocmd_id = vim.api.nvim_create_autocmd("VimResized", {
        callback = function()
            vim.schedule(on_vim_resize)
        end,
    })

    local key_opts = { buffer = pbuf, nowait = true, silent = true }

    vim.keymap.set("i", "<CR>", function()
        close(filtered[cur] and filtered[cur].data)
    end, key_opts)

    vim.keymap.set("i", "<Esc>", function() close(nil) end, key_opts)
    vim.keymap.set("i", "<C-c>", function() close(nil) end, key_opts)

    vim.keymap.set("i", "<Down>", function()
        cur = _move_wrap(#filtered, cur, 1)
        update_content()
    end, key_opts)

    vim.keymap.set("i", "<C-n>", function()
        cur = _move_wrap(#filtered, cur, 1)
        update_content()
    end, key_opts)

    vim.keymap.set("i", "<Up>", function()
        cur = _move_wrap(#filtered, cur, -1)
        update_content()
    end, key_opts)

    vim.keymap.set("i", "<C-p>", function()
        cur = _move_wrap(#filtered, cur, -1)
        update_content()
    end, key_opts)

    local page = math.max(1, math.floor(layout.list_height / 2))
    vim.keymap.set("i", "<C-d>", function()
        cur = _move_clamp(#filtered, cur, page)
        update_content()
    end, key_opts)

    vim.keymap.set("i", "<C-u>", function()
        cur = _move_clamp(#filtered, cur, -page)
        update_content()
    end, key_opts)

    vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
        buffer = pbuf,
        callback = function()
            if vim.api.nvim_buf_line_count(pbuf) == 0 then
                vim.api.nvim_buf_set_lines(pbuf, 0, -1, false, { "" })
            end
            local plines = vim.api.nvim_buf_get_lines(pbuf, 0, -1, false)
            -- If user somehow created multiple lines (pasting, C-j),
            -- flatten them into one line and strip control chars.
            local raw_query = table.concat(plines, " ")
            local sanitized = raw_query:gsub("%c", "") -- Strip control chars
            -- If the buffer looks different than the sanitized version, force-reset it
            if #plines > 1 or raw_query ~= sanitized then
                vim.api.nvim_buf_set_lines(pbuf, 0, -1, false, { sanitized })
                -- Put cursor at the end of the line
                vim.api.nvim_win_set_cursor(pwin, { 1, #sanitized })
            end
            query = sanitized
            items = opts.items or {}
            refilter()
            -- Async incremental fetch
            if async_fetch_cancel then
                async_fetch_cancel()
                async_fetch_cancel = nil
            end
            if opts.async_fetch then
                async_fetch_cancel = opts.async_fetch(query, {
                        list_width = math.max(1, layout.list_width - 3),
                        list_height = math.max(1, layout.list_height),
                    },
                    function(new_items)
                        if closed then return end
                        _process_labels(new_items)
                        vim.list_extend(items, new_items)
                        refilter()
                    end)
            end
        end,
    })

    vim.api.nvim_create_autocmd("BufLeave", {
        buffer = pbuf,
        once = true,
        callback = function() close(nil) end,
    })

    for _, buf in ipairs({ pbuf, lbuf, vbuf }) do
        if buf and buf > 0 then
            vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
                buffer = buf,
                once = true,
                callback = function()
                    -- Ensure we don't try to access the specific buffer again
                    if buf == pbuf then pbuf = -1 end
                    if buf == lbuf then lbuf = -1 end
                    if buf == vbuf then vbuf = -1 end
                    -- close() is idempotent, so calling it multiple times is safe
                    vim.schedule(close)
                end
            })
        end
    end

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
