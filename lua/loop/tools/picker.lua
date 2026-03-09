local filetools  = require("loop.tools.file")
local fntools    = require('loop.tools.fntools')
local throttle   = require('loop.tools.throttle')
local Spinner    = require("loop.tools.Spinner")

---@mod loop.picker
---@brief Simple floating picker with fuzzy filtering and optional preview.

---@class loop.Picker.Item
---@field label        string?             main displayed text (optional if label_chunks used)
---@field label_chunks {[1]:string, [2]:string?}[]?  optional, allows chunked labels with highlights
---@field virt_lines? {[1]:string, [2]:string?}[][] chunks: { { "text", "HighlightGroup?" }, ... }
---@field data         any                payload returned on select

---@alias loop.Picker.Callback fun(data:any|nil)

---@alias loop.Picker.Previewer fun(data:any):(string, string|nil)
--- Returns preview text and optional filetype

local M          = {}

local NS_CURSOR  = vim.api.nvim_create_namespace("LoopSelectorCursor")
local NS_VIRT    = vim.api.nvim_create_namespace("LoopSelectorVirtText")
local NS_SPINNER = vim.api.nvim_create_namespace("LoopSelectorSpinner")
local NS_PREVIEW = vim.api.nvim_create_namespace("LoopSelectorPreview")

--------------------------------------------------------------------------------
-- Utility functions
--------------------------------------------------------------------------------

---@param lwin number
---@param lbuf integer
local function _render_cursor(lwin, lbuf)
    vim.api.nvim_buf_clear_namespace(lbuf, NS_CURSOR, 0, -1)
    if vim.api.nvim_buf_line_count(lbuf) == 1 then
        local first = vim.api.nvim_buf_get_lines(lbuf, 0, 1, false)[1]
        if first == "" then
            return
        end
    end
    local row = vim.api.nvim_win_get_cursor(lwin)[1]
    vim.api.nvim_buf_set_extmark(lbuf, NS_CURSOR, row - 1, 0, {
        virt_text = { { "> ", "Special" } },
        virt_text_pos = "overlay",
        priority = 200,
    })
end

---@param lwin number
---@param lbuf number
---@param pbuf number
local function _update_pos_hint(lwin, lbuf, pbuf)
    vim.api.nvim_buf_clear_namespace(pbuf, NS_VIRT, 0, -1)
    local cur = vim.api.nvim_win_get_cursor(lwin)[1]
    local total = vim.api.nvim_buf_line_count(lbuf)
    if cur and total > 0 then
        local count_text = string.format("%d/%d", cur, total)
        -- Set virtual text on the first line of the list window (prompt line is usually separate)
        vim.api.nvim_buf_set_extmark(pbuf, NS_VIRT, 0, 0, {
            virt_text = { { count_text, "Comment" } }, -- highlight group
            virt_text_pos = "right_align",
            hl_mode = "blend",
            priority = 1,
        })
    end
end

---@param buf integer
local function _clear_list(buf)
    vim.api.nvim_buf_clear_namespace(buf, NS_VIRT, 0, -1)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {})
end

---@param items loop.Picker.Item[]
---@param lwin number
---@param lbuf integer
local function _add_to_list(items, lwin, lbuf)
    local lines = {}
    local extmarks = {}
    local virt_extmarks = {}
    local prefix = "  "

    local start = vim.api.nvim_buf_line_count(lbuf)
    if start == 1 then
        local first = vim.api.nvim_buf_get_lines(lbuf, 0, 1, false)[1]
        if first == "" then
            start = 0
        end
    end

    for i, item in ipairs(items) do
        lines[i] = prefix .. (item.label:gsub("\n", ""))

        local row = start + i - 1
        local col = #prefix

        if item.label_chunks then
            for _, chunk in ipairs(item.label_chunks) do
                local text, hl = chunk[1], chunk[2]
                if text and #text > 0 then
                    local len = #text
                    if hl then
                        extmarks[#extmarks + 1] = {
                            row       = row,
                            col_start = col,
                            col_end   = col + len,
                            hl_group  = hl
                        }
                    end
                    col = col + len
                end
            end
        end

        if item.virt_lines and #item.virt_lines > 0 then
            local vlines = {}
            for _, line in ipairs(item.virt_lines) do
                local vl = { { prefix } }
                vim.list_extend(vl, line)
                table.insert(vlines, vl)
            end
            virt_extmarks[#virt_extmarks + 1] = {
                row  = row,
                col  = 0,
                opts = { virt_lines = vlines, hl_mode = "blend" }
            }
        end
    end

    -- Append instead of replace
    local cursor = vim.api.nvim_win_get_cursor(lwin)
    vim.api.nvim_buf_set_lines(lbuf, start, start, false, lines)
    vim.api.nvim_win_set_cursor(lwin, cursor)

    for _, mark in ipairs(extmarks) do
        vim.api.nvim_buf_set_extmark(lbuf, NS_VIRT, mark.row, mark.col_start, {
            end_col  = mark.col_end,
            hl_group = mark.hl_group,
        })
    end

    for _, mark in ipairs(virt_extmarks) do
        vim.api.nvim_buf_set_extmark(lbuf, NS_VIRT, mark.row, mark.col, mark.opts)
    end
end

---@param max integer Total number of items
---@param cur integer Current 1-based index
---@param delta integer Direction (-1 for up, 1 for down)
---@return integer
local function _move_wrap(max, cur, delta)
    if max <= 0 then return 1 end
    local new_pos = cur + delta
    if new_pos < 1 then
        return max -- Wrap from top to bottom
    elseif new_pos > max then
        return 1   -- Wrap from bottom to top
    end
    return new_pos
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

---@param items loop.Picker.Item[]
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

---@class loop.Picker.Layout
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

---@param opts {has_preview:boolean,height_ratio:number?,width_ratio:number?,list_ratio:number?}
---@return loop.Picker.Layout
local function _compute_horizontal_layout(opts)
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

    local container_ratio = clamp(opts.width_ratio or 0.8, 0, 1)
    width = math.floor(cols * container_ratio)

    local list_ratio = clamp(opts.list_ratio or (has_preview and 0.5 or 1), 0, 1)
    list_width = math.floor(width * list_ratio)

    if has_preview then
        prev_width = clamp(width - list_width - spacing, 1, width)
    end


    list_width = clamp(list_width, 1, cols)
    prev_width = clamp(prev_width, 0, cols)

    local used_width = list_width + spacing + prev_width

    -------------------------------------------------
    -- HEIGHT
    -------------------------------------------------

    local height_ratio = clamp(opts.height_ratio or .7, 0, 1)
    local height = math.floor(lines * height_ratio)

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

    ---@type loop.Picker.Layout
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

---@class loop.Picker.AsyncFetcherOpts
---@field list_width number
---@fiel list_height number

---@class loop.Picker.AsyncPreviewOpts
---@field preview_width number
---@fiel preview_height number

---@alias loop.Picker.AsyncFetcher (fun(query:string,  opts:loop.Picker.AsyncFetcherOpts, callback:fun(new_items:loop.Picker.Item[]?)):fun())?
---@alias loop.Picker.AsyncPreviewLoader (fun(item_data:any, opts:loop.Picker.AsyncPreviewOpts, callback:fun(preview:string?)):fun())?

---@class loop.Picker.opts
---@field prompt string
---@field async_fetch loop.Picker.AsyncFetcher
---@field async_preview loop.Picker.AsyncPreviewLoader?
---@field height_ratio number?
---@field width_ratio number?
---@field preview_ratio number?
---@field list_wrap boolean?

---@param opts loop.Picker.opts
---@param callback loop.Picker.Callback
function M.select(opts, callback)
    assert(type(opts.async_fetch) == "function")
    local prompt = opts.prompt
    local title = (prompt and prompt ~= "") and (" %s "):format(prompt) or ""
    local has_preview = opts.async_preview ~= nil and type(opts.async_preview) == "function"

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

    local layout = _compute_horizontal_layout({
        has_preview = has_preview,
        height_ratio = opts.height_ratio,
        width_ratio = opts.width_ratio,
        preview_ratio = opts.preview_ratio,
    })

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

    local items_data = {} ---@type any[]
    local closed = false
    local async_preview_cancel
    local async_fetch_cancel
    local async_fetch_context = 0
    local vimreisze_autocmd_id
    local spinner

    local function render_spinner(frame)
        if not vim.api.nvim_buf_is_valid(pbuf) then
            return
        end
        vim.api.nvim_buf_clear_namespace(pbuf, NS_SPINNER, 0, -1)
        vim.api.nvim_buf_set_extmark(pbuf, NS_SPINNER, 0, 0, {
            virt_text = { { frame .. " ", "Comment" } },
            virt_text_pos = "right_align",
            hl_mode = "blend",
            priority = 2,
        })
    end
    local function start_spinner()
        if spinner then return end
        spinner = Spinner:new({
            interval = 80,
            on_update = function(frame)
                render_spinner(frame)
            end
        })
        spinner:start()
    end
    local function stop_spinner()
        if spinner then
            spinner:stop()
            spinner = nil
        end
        if vim.api.nvim_buf_is_valid(pbuf) then
            vim.api.nvim_buf_clear_namespace(pbuf, NS_SPINNER, 0, -1)
        end
    end

    local function close(result)
        stop_spinner()
        if vimreisze_autocmd_id then
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

    local function get_cursor()
        return vim.api.nvim_win_get_cursor(lwin)[1]
    end

    local function move_cursor(cur, force)
        if not force then
            local pos = vim.api.nvim_win_get_cursor(lwin)
            if cur == pos[1] then return end
        end
        vim.api.nvim_win_set_cursor(lwin, { cur, 0 })
        _render_cursor(lwin, lbuf)

        vim.api.nvim_win_call(lwin, function()
            local win_height = vim.api.nvim_win_get_height(0)
            local current_winline = vim.fn.winline()

            if current_winline <= 1 then
                vim.cmd("normal! zt")
            elseif current_winline >= win_height then
                vim.cmd("normal! zb")
            end
        end)

        if vbuf and vim.api.nvim_buf_is_valid(vbuf) then
            if async_preview_cancel then
                async_preview_cancel()
                async_preview_cancel = nil
            end
            local data = items_data[cur]
            if not data then
                vim.api.nvim_buf_set_lines(vbuf, 0, -1, false, {})
            else
                async_preview_cancel = opts.async_preview(data, {
                        preview_width = layout.prev_width,
                        prev_width = layout.prev_height,
                    },
                    function(preview)
                        local lines = preview and vim.fn.split(preview, "\n") or {}
                        vim.api.nvim_buf_set_lines(vbuf, 0, -1, false, lines)
                    end)
            end
        end
    end

    local function on_vim_resize()
        assert(not closed) -- import to detect bugs with non deleted auto cmds
        -- 1. Recalculate layout based on new screen dimensions
        layout = _compute_horizontal_layout({
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
    end

    vimreisze_autocmd_id = vim.api.nvim_create_autocmd("VimResized", {
        callback = function()
            vim.schedule(on_vim_resize)
        end,
    })

    local key_opts = { buffer = pbuf, nowait = true, silent = true }

    vim.keymap.set("i", "<CR>", function()
        close(items_data[get_cursor()])
    end, key_opts)

    vim.keymap.set("i", "<Esc>", function() close(nil) end, key_opts)
    vim.keymap.set("i", "<C-c>", function() close(nil) end, key_opts)

    vim.keymap.set("i", "<Down>", function()
        move_cursor(_move_wrap(#items_data, get_cursor(), 1))
    end, key_opts)

    vim.keymap.set("i", "<C-n>", function()
        move_cursor(_move_wrap(#items_data, get_cursor(), 1))
    end, key_opts)

    vim.keymap.set("i", "<Up>", function()
        move_cursor(_move_wrap(#items_data, get_cursor(), -1))
    end, key_opts)

    vim.keymap.set("i", "<C-p>", function()
        move_cursor(_move_wrap(#items_data, get_cursor(), -1))
    end, key_opts)

    local page = math.max(1, math.floor(layout.list_height / 2))
    vim.keymap.set("i", "<C-d>", function()
        move_cursor(_move_clamp(#items_data, get_cursor(), page))
    end, key_opts)

    vim.keymap.set("i", "<C-u>", function()
        move_cursor(_move_clamp(#items_data, get_cursor(), -page))
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

            local query = sanitized

            local clear_items = function()
                items_data = {}
                _clear_list(lbuf)
                move_cursor(1, true)
                _update_pos_hint(lwin, lbuf, pbuf)
            end

            -- Async incremental fetch
            if async_fetch_cancel then
                async_fetch_cancel()
                async_fetch_cancel = nil
            end
            stop_spinner()

            if query == "" then
                clear_items()
                return
            end

            async_fetch_context = async_fetch_context + 1

            ---@type number?
            local context = async_fetch_context
            local waiting_first = true

            start_spinner()
            async_fetch_cancel = opts.async_fetch(query, {
                    list_width = math.max(1, layout.list_width - 3),
                    list_height = math.max(1, layout.list_height),
                },
                function(new_items)
                    if closed or context ~= async_fetch_context then return end
                    if waiting_first then
                        waiting_first = false
                        clear_items()
                    end
                    if new_items == nil then
                        context = nil
                        stop_spinner()
                        return
                    end
                    local was_empty = #items_data == 0
                    _process_labels(new_items)
                    for _, item in ipairs(new_items) do
                        table.insert(items_data, item.data)
                    end
                    _add_to_list(new_items, lwin, lbuf)
                    if was_empty then
                        move_cursor(1, true)
                    end
                    _update_pos_hint(lwin, lbuf, pbuf)
                end)
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
end

return M
