local M = {}
local loopconfig = require('loop').config
local Page = require('loop.ui.Page')
local sidebar = require('loop.ui.sidebar')
local throttle = require('loop.utils.throttle')
local uitools = require('loop.utils.uitools')
local strtools = require('loop.utils.strtools')
local selector = require("loop.utils.selector")
local BaseBuffer = require('loop.buf.BaseBuffer')
local OutputBuffer = require('loop.buf.OutputBuffer')
local ReplBuffer = require('loop.buf.ReplBuffer')
local logger = require('loop.log')

---@class loop.TabInfo
---@field label string
---@field pages loop.pages.Page[]
---@field active_page_idx number|nil
---@field changed_pages table<number,boolean>

---@type boolean
local _init_done = false
local _init_err_msg = "init() not called"

---@type number
local _loop_win = -1

---@type number
local _loop_win_height_ratio
---@type fun(action: "next"|"prev")
local _cycle_pages

---@type loop.TabInfo[]
local _tabs_arr = {}

---@type number
local _active_tab_idx = 1

---@type loop.pages.Page
local _placeholder_page

---@type string
local _status_text

---@return number
local function _get_placeholder_buf()
    _placeholder_page = _placeholder_page or Page:new(BaseBuffer:new({
        name = "",
        filetype = "loop-empty",
        listed = false,
        wipe_when_hidden = false,
    }))
    local buf = _placeholder_page:get_or_create_buf()
    return buf
end

---@param win number
---@param active_tab loop.TabInfo?
---@param page_idx number
local function _assign_buffer(win, active_tab, page_idx)
    local page_assigned = false
    for arr_idx, tab in ipairs(_tabs_arr) do
        if active_tab == tab then
            _active_tab_idx = arr_idx
            local page = tab.pages[page_idx]
            if page then
                local buf = page:get_or_create_buf()
                vim.wo[win].winfixbuf = false
                vim.api.nvim_win_set_buf(win, buf)
                vim.wo[win].winfixbuf = true
                page_assigned = true
            end
        end
    end

    if not page_assigned then
        local buf = _get_placeholder_buf()
        vim.wo[win].winfixbuf = false
        vim.api.nvim_win_set_buf(win, buf)
        vim.wo[win].winfixbuf = true
    end
end

---@param width number
---@param active_tab loop.TabInfo
---@param page_idx number
---@return string
local function _build_winbar(width, active_tab, page_idx)
    local symbols = loopconfig.statuspanel.symbols
    local winbar_data = { { 3, "%#LoopPluginInactiveTab#" } }
    local tabidx = 0

    for arr_idx, tab in ipairs(_tabs_arr) do
        local is_active_tab = active_tab == tab
        if #tab.pages > 0 then
            tabidx = tabidx + 1
            table.insert(winbar_data, { 2, ' ' })
            if #tab.pages > 1 then
                if is_active_tab then table.insert(winbar_data, { 3, "%#LoopPluginActiveTab#" }) end
                table.insert(winbar_data,
                    { 3, string.format("%%%d@v:lua._LoopPluginGlobalState.wbc@", arr_idx * 1000) })
                table.insert(winbar_data, { 1, tab.label })
                if is_active_tab then table.insert(winbar_data, { 3, "%#LoopPluginInactiveTab#" }) end
                table.insert(winbar_data, { 2, " " })
            end
            for idx, page in ipairs(tab.pages) do
                local name = #tab.pages > 1 and page:get_name() or tab.label
                local is_active_page = is_active_tab and idx == page_idx
                local change_flag = tab.changed_pages[idx] and symbols.change or ''
                local uiflags = (change_flag or "") .. (page:get_ui_flags() or "")
                uiflags = uiflags ~= "" and (' ' .. uiflags) or uiflags
                if is_active_page then table.insert(winbar_data, { 3, "%#LoopPluginActiveTab#" }) end
                table.insert(winbar_data,
                    { 3, string.format("%%%d@v:lua._LoopPluginGlobalState.wbc@", arr_idx * 1000 + idx) })
                table.insert(winbar_data, { 2, '[' })
                table.insert(winbar_data, { 1, name })
                table.insert(winbar_data, { 2, uiflags .. ']' })
                if is_active_page then table.insert(winbar_data, { 3, "%#LoopPluginInactiveTab#" }) end
            end
        end
    end

    local visible_len = 0
    local croppable_len = 0
    local nb_croppable = 0
    for _, item in ipairs(winbar_data) do
        if item[1] ~= 3 then
            local len = vim.fn.strdisplaywidth(item[2])
            visible_len = visible_len + len
            if item[1] == 1 then
                croppable_len = croppable_len + len
                nb_croppable = nb_croppable + 1
            end
        end
    end

    if visible_len == 0. then
        return ""
    end

    local winbar_parts = {}
    if visible_len > width and nb_croppable > 0 then
        local overflow = visible_len - width
        local base_reduce = math.floor(overflow / nb_croppable)
        local remainder = overflow % nb_croppable
        local croppable_index = 0
        for _, item in ipairs(winbar_data) do
            local is_croppable = item[1] == 1
            local text = item[2]
            if is_croppable then
                croppable_index = croppable_index + 1
                local reduce = base_reduce
                if croppable_index <= remainder then
                    reduce = reduce + 1
                end
                local current_w = vim.fn.strdisplaywidth(text)
                local target_w = math.max(current_w - reduce, 1)
                if target_w < current_w then
                    text = strtools.crop_string_for_ui(text, target_w)
                end
            end
            table.insert(winbar_parts, text)
        end
    else
        for _, item in ipairs(winbar_data) do
            table.insert(winbar_parts, item[2])
        end
    end
    return table.concat(winbar_parts, "")
end

local function _setup_tabs()
    if _loop_win == -1 then
        return
    end
    local win = _loop_win

    local active_tab = _tabs_arr[_active_tab_idx]
    if not active_tab or vim.tbl_isempty(active_tab.pages) then
        for i, t in ipairs(_tabs_arr) do
            if #t.pages > 0 then
                active_tab = t
                _active_tab_idx = i
                break
            end
        end
    end
    local page_idx = 1
    if active_tab and active_tab.pages[active_tab.active_page_idx] then
        page_idx = active_tab.active_page_idx or page_idx
    end
    if active_tab then
        active_tab.changed_pages[page_idx] = false
    end

    _assign_buffer(win, active_tab, page_idx)

    local width = vim.api.nvim_win_get_width(win)
    local status_text = _status_text or ""
    local status = "%#LoopPluginStatusText#" .. status_text .. "%#Winbar# "

    local remaining_with = math.max(width - #status_text - 1, 1)
    local winbar = _build_winbar(remaining_with, active_tab, page_idx)

    local full_winbar
    if winbar ~= "" or status_text ~= "" then
        full_winbar = ("%s %%=%s"):format(winbar, status)
    end
    -- set the winbar
    vim.wo[win].winbar = full_winbar
end

local _throttled_setup_tabs = throttle.throttle_wrap(100, _setup_tabs)

---@param req_tabidx number
---@param req_pageidx number|nil
local function _set_active_tab(req_tabidx, req_pageidx)
    local req_tab = _tabs_arr[req_tabidx]
    assert(req_tab)
    if not req_tab or #req_tab.pages == 0 then
        return
    end
    _active_tab_idx = req_tabidx
    if req_pageidx and req_pageidx > 0 and req_pageidx <= #req_tab.pages then
        req_tab.active_page_idx = req_pageidx
    end
    _setup_tabs()
end

---@param action "next"|"prev"
_cycle_pages = function(action)
    if vim.api.nvim_get_current_win() ~= _loop_win then return end

    local tabidx = _active_tab_idx
    local tab = _tabs_arr[tabidx]
    local pageidx = tab.active_page_idx or 1

    local dir = action == "next" and 1 or -1

    if (#tab.pages > 0) then
        pageidx = pageidx + dir
    end

    -- if page goes out of bounds, move to next/prev tab with pages
    if pageidx < 1 or pageidx > #tab.pages then
        local start_idx = tabidx
        repeat
            tabidx = (tabidx - 1 + dir) % #_tabs_arr + 1
            tab = _tabs_arr[tabidx]
        until (tab.pages and #tab.pages > 0) or (tabidx == start_idx)
        pageidx = dir == 1 and 1 or #tab.pages
    end

    _set_active_tab(tabidx, pageidx)
end

---@param next boolean
function M.cycle_pages(next)
    _cycle_pages(next and "next" or "prev")
end

---@param tab loop.TabInfo
local function _delete_tab_pages(tab)
    local cur_buf = nil
    if _loop_win ~= -1 then
        cur_buf = vim.api.nvim_win_get_buf(_loop_win)
    end
    for _, page in ipairs(tab.pages) do
        if cur_buf and page:get_buf() == cur_buf then
            local buf = _get_placeholder_buf()
            vim.wo[_loop_win].winfixbuf = false
            vim.api.nvim_win_set_buf(_loop_win, buf)
            vim.wo[_loop_win].winfixbuf = true
        end
        page:destroy()
    end
    tab.pages = {}
    tab.active_page_idx = nil
end

---@param tab loop.TabInfo
local function _get_tab_index(tab)
    for idx, t in ipairs(_tabs_arr) do
        if t == tab then return idx end
    end
    return 0
end

---@param tab loop.TabInfo
local function _delete_tab(tab)
    local index = _get_tab_index(tab)
    assert(index > 0)
    _delete_tab_pages(tab)
    table.remove(_tabs_arr, index)
    if _active_tab_idx > index and _active_tab_idx > 1 then
        _active_tab_idx = _active_tab_idx - 1
    end
    vim.schedule(_setup_tabs)
end

function M.winbar_click(id, clicks, button, mods)
    local tab_idx = math.floor(id / 1000)
    local page_idx = id % 1000
    _set_active_tab(tab_idx, page_idx)
end

local function _create_window()
    if _loop_win ~= -1 then
        return
    end

    local prev_win = vim.api.nvim_get_current_win()

    sidebar.save_layout()
    vim.cmd('bot 1split') -- Open a bottom split.
    sidebar.fix_layout()

    -- Get the new window ID.
    _loop_win = vim.api.nvim_get_current_win()

    vim.wo[_loop_win].winfixbuf = true
    if _loop_win_height_ratio then
        vim.api.nvim_win_set_height(_loop_win, math.floor(vim.o.lines * _loop_win_height_ratio))
    else
        vim.api.nvim_win_set_height(_loop_win, math.floor(vim.o.lines * 0.17))
    end

    vim.api.nvim_set_option_value('winfixheight', true, { scope = 'local', win = _loop_win })
    vim.api.nvim_set_current_win(prev_win)
    vim.wo[_loop_win].spell = false

    _setup_tabs()
end

local function _apply_window_height()
    if _loop_win ~= -1 and _loop_win_height_ratio then
        if not uitools.is_win_full_height(_loop_win) then
            vim.api.nvim_win_set_height(_loop_win, math.floor(vim.o.lines * _loop_win_height_ratio))
        end
    end
end

-- remove winbar after split
local function _check_winbar()
    local winid = vim.api.nvim_get_current_win()
    local buf = vim.api.nvim_win_get_buf(winid)
    if winid ~= _loop_win then
        local winbar = vim.wo[winid].winbar
        if type(winbar) == 'string' and winbar:match('v:lua._LoopPluginGlobalState.wbc') then
            vim.wo[winid].winbar = nil
        end
    end
end

---@param target_winid? number|nil
---@param tabidx number
---@param pageidx number|nil
local function _show_page(target_winid, tabidx, pageidx)
    if not target_winid or target_winid == _loop_win then
        _set_active_tab(tabidx, pageidx)
        _create_window()
    else
        local req_tab = _tabs_arr[tabidx]
        local page_idx = pageidx or 1
        if req_tab and req_tab.pages[page_idx] then
            local buf = req_tab.pages[page_idx]:get_or_create_buf()
            if buf and buf > 0 then
                vim.api.nvim_win_set_buf(target_winid, buf)
            end
        end
    end
end

---@param target_winid? number|nil
local function _select_and_show_page(target_winid)
    local choices = {}
    local initial
    for tabidx, tab in ipairs(_tabs_arr) do
        for pageidx, page in ipairs(tab.pages) do
            local label = tab.label
            if #tab.pages > 1 then
                label = label .. ' - ' .. page:get_name()
            end
            ---@type loop.SelectorItem
            local item = {
                label = label,
                data = { tabidx = tabidx, pageidx = pageidx },
            }
            table.insert(choices, item)
            if tabidx == _active_tab_idx and pageidx == tab.active_page_idx then
                initial = #choices
            end
        end
    end
    if #choices == 0 then
        vim.notify("No pages to show")
        return
    end
    selector.select({
            prompt = "Select page",
            items = choices,
            initial = initial,
        },
        function(data)
            if data and data.tabidx then
                _show_page(target_winid, data.tabidx, data.pageidx)
            end
        end
    )
end

function M.show_window()
    assert(_init_done, _init_err_msg)
    _create_window()
end

function M.hide_window()
    assert(_init_done, _init_err_msg)
    if _loop_win and vim.api.nvim_win_is_valid(_loop_win) then
        vim.api.nvim_win_close(_loop_win, false)
        _loop_win = -1
    end
end

---@return boolean
function M.is_visible()
    assert(_init_done, _init_err_msg)
    return _loop_win ~= -1
end

function M.switch_page()
    assert(_init_done, _init_err_msg)
    _select_and_show_page()
end

---@param target_winid number?
---@param group_label string|nil
---@param page_label string|nil
function M.open_page(target_winid, group_label, page_label)
    assert(_init_done, _init_err_msg)
    if not group_label then
        _select_and_show_page(target_winid)
        return
    end
    local tab_idx
    for ti, t in ipairs(_tabs_arr) do
        if group_label == t.label then
            tab_idx = ti
            break
        end
    end
    if not tab_idx then
        vim.notify('Page not found: ' .. tostring(group_label))
        return
    end
    if not page_label then
        _show_page(target_winid, tab_idx, nil)
        return
    end
    local tab = _tabs_arr[tab_idx]
    if not tab then return end

    local page_idx
    for pi, p in ipairs(tab.pages) do
        if page_label == p:get_name() then
            page_idx = pi
            break
        end
    end
    if not page_idx then
        vim.notify('Page not found: ' .. tostring(group_label) .. ' - ' .. page_label)
        return
    end
    _show_page(target_winid, tab_idx, page_idx)
end

---@return string[]
function M.get_pagegroup_names()
    local ret = {}
    for _, t in ipairs(_tabs_arr) do
        table.insert(ret, t.label)
    end
    return ret
end

---@param group_label string
---@return string[]
function M.get_page_names(group_label)
    local tab_idx
    for ti, t in ipairs(_tabs_arr) do
        if group_label == t.label then
            if #t.pages == 1 then
                return {}
            end
            return vim.tbl_map(function(p)
                return p:get_name()
            end, t.pages)
        end
    end
    return {}
end

---@param page loop.pages.Page
---@param args loop.utils.TermProc.StartArgs
---@return loop.utils.TermProc|nil,string|nil
local function _create_term(page, args)
    _create_window()
    assert(_loop_win ~= -1)

    ---@type loop.utils.TermProc.StartArgs
    ---@diagnostic disable-next-line: missing-fields
    local args_cpy = {}
    for k, v in pairs(args) do args_cpy[k] = v end

    args_cpy.on_exit_handler = function(code)
        args.on_exit_handler(code)
        local symbols = loopconfig.statuspanel.symbols
        page:set_ui_flags(code == 0 and symbols.success or symbols.failure)
        local buf = page:get_buf()
        if buf ~= -1 then
            if _loop_win > 0
                and vim.api.nvim_get_current_win() == _loop_win
                and vim.api.nvim_win_get_buf(_loop_win) == buf then
                vim.api.nvim_buf_call(buf, function() vim.cmd.stopinsert() end)
            end
            uitools.disable_insert_mappings(buf)
        end
    end

    local bufnr = page:get_or_create_buf()

    local do_scroll = true
    args_cpy.output_handler = function(stream, data)
        if args.output_handler then
            args.output_handler(stream, data)
        end
        page:request_change_notif()
        if do_scroll and _loop_win > 0 then
            local b = vim.api.nvim_win_get_buf(_loop_win)
            if b == bufnr then -- if we have output, bufnr is still valid
                if vim.api.nvim_get_current_win() == _loop_win then
                    do_scroll = false
                else
                    local last = vim.api.nvim_buf_line_count(b)
                    vim.api.nvim_win_set_cursor(_loop_win, { last, 0 })
                end
            end
        end
    end

    local TermProc = require('loop.utils.TermProc')

    logger.log({ "Starting term proc", vim.inspect(args_cpy) }, vim.log.levels.DEBUG)

    local proc = TermProc:new()
    local proc_ok, proc_err = proc:start(bufnr, args_cpy)

    if not proc_ok then
        local existing = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        local is_empty = (#existing == 0) or (#existing == 1 and existing[1] == "")
        if is_empty then
            local lines = proc_err and vim.fn.split(proc_err, "\n") or { "Unknown error" }
            vim.bo[bufnr].modifiable = true
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
            vim.bo[bufnr].modifiable = false
        end
        return nil, proc_err
    end

    vim.keymap.set('t', '<Esc>', function() vim.cmd('stopinsert') end, { buffer = bufnr })

    return proc, nil
end

---@param label string
---@return loop.TabInfo
local function _add_tab(label)
    ---@type loop.TabInfo
    local tab = {
        label = label,
        pages = {},
        changed_pages = {},
    }
    table.insert(_tabs_arr, tab)
    return tab
end

---@param tab loop.TabInfo
---@param page loop.pages.Page
---@param activate boolean|nil
---@return number idx
local function _assign_tab_page(tab, page, activate)
    --page:add_keymaps(get_page_keymap())
    table.insert(tab.pages, page)
    local page_idx = #tab.pages
    if activate then
        _active_tab_idx = _get_tab_index(tab)
        tab.active_page_idx = page_idx
    end
    page:add_tracker({
        on_change = function()
            if tab.changed_pages[page_idx] ~= true then
                tab.changed_pages[page_idx] = true
                _throttled_setup_tabs()
            end
        end,
        on_ui_flags_update = _throttled_setup_tabs
    })
    vim.schedule(function()
        if activate then
            M.show_window()
        end
        _setup_tabs()
    end)
    return page_idx
end


---@param tab loop.TabInfo
---@param opts loop.PageOpts
---@return loop.PageData?,string?
local function _add_tab_page(tab, opts)
    if opts.type == "term" then
        local basebuf = BaseBuffer:new({ filetype = "loop-term", name = opts.label, listed = false, wipe_when_hidden = false, })
        local page = Page:new(basebuf)
        _assign_tab_page(tab, page, opts.activate)
        local proc, err = _create_term(page, opts.term_args)
        if not proc then
            return nil, err
        end
        ---@type loop.PageData
        return { page = page:make_controller(), term_proc = proc }
    end
    if opts.type == "output" then
        local output_buf = OutputBuffer:new({
            filetype = "loop-output",
            name = opts.label,
            listed = false,
            wipe_when_hidden = false,
        })
        local page = Page:new(output_buf)
        _assign_tab_page(tab, page, opts.activate)
        local ctrl = output_buf:make_controller()
        ---@type loop.PageData
        return { page = page:make_controller(), base_buf = ctrl, output_buf = ctrl }
    end
    if opts.type == "repl" then
        local repl_buf = ReplBuffer:new({ filetype = "loop-repl", name = opts.label, listed = false, wipe_when_hidden = false, })
        local page = Page:new(repl_buf)
        _assign_tab_page(tab, page, opts.activate)
        ---@type loop.PageData
        return { page = page:make_controller(), repl_buf = repl_buf:make_controller() }
    end
    return nil, "Invalid page type"
end


---@return loop.PageManager
local function _create_page_manager()
    assert(_init_done, "init not done")

    ---@param tab loop.TabInfo
    ---@return loop.PageGroup
    local function make_page_group(tab)
        local expired, deleted = false, false
        ---@type loop.PageGroup
        return {
            have_pages = function()
                return #tab.pages > 0
            end,
            is_expired = function()
                return expired
            end,
            is_deleted = function()
                return deleted
            end,
            add_page = function(opts)
                if expired or deleted then return nil end
                local page_data, err = _add_tab_page(tab, opts)
                return page_data, err
            end,
            delete_pages = function()
                _delete_tab_pages(tab)
            end,
            delete_group = function()
                if deleted then return end
                _delete_tab(tab)
                expired, deleted = true, true
            end,
            expire = function(delete_pages)
                expired = true
            end
        }
    end

    ---@type loop.PageGroup[]
    local groups = {}
    local is_expired = false

    ---@type loop.PageManager
    return {
        is_expired = function()
            return is_expired
        end,
        add_page_group = function(label)
            if is_expired then return nil end
            local tab = _add_tab(label)
            local group = make_page_group(tab)
            table.insert(groups, group)
            return group
        end,
        delete_groups = function()
            for _, grp in ipairs(groups) do
                grp.delete_group()
            end
            groups = {}
        end,
        delete_expired_groups = function()
            local remaining = {}
            for _, grp in ipairs(groups) do
                if grp.is_expired() then
                    grp.delete_group()
                else
                    table.insert(remaining, grp)
                end
            end
            groups = remaining
        end,
        expire = function()
            is_expired = true
        end
    }
end

---@param text string
function M.set_status_text(text)
    _status_text = text
    _throttled_setup_tabs()
end

---@return loop.PageManager
function M.create_page_manager()
    return _create_page_manager()
end

function M.init()
    if _init_done then
        error('Loop.nvim: init() cannot be called more than once')
        return
    end
    -- init only once
    _init_done = true

    vim.api.nvim_set_hl(0, "LoopPluginActiveTab", {
        bg = (function()
            local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = "WinBar", link = false })
            if not ok then return nil end
            return hl.bg
        end)(),
        fg = (function()
            local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = "Title", link = false })
            if not ok then return nil end
            return hl.fg
        end)(),
    })

    do
        vim.api.nvim_set_hl(0, "LoopPluginInactiveTab", { link = "WinBar" })
        vim.api.nvim_set_hl(0, "LoopPluginStatusText", { link = "LoopPluginActiveTab" })
    end

    vim.api.nvim_create_autocmd("WinNew", {
        callback = function(args)
            local new_winid = vim.api.nvim_get_current_win()
            if vim.api.nvim_win_get_config(new_winid).relative ~= "" then
                return -- ignore floating windows
            end
            vim.schedule(function()
                _apply_window_height()
            end)
        end,
    })

    vim.api.nvim_create_autocmd("WinClosed", {
        callback = function(args)
            local closed_winid = tonumber(args.match)
            if closed_winid == _loop_win then
                _loop_win = -1
            end
            if not closed_winid or vim.api.nvim_win_get_config(closed_winid).relative ~= "" then
                return -- ignore floating windows
            end
            vim.schedule(function()
                _apply_window_height()
            end)
        end,
    })

    vim.api.nvim_create_autocmd("WinEnter", { callback = _check_winbar })

    vim.api.nvim_create_autocmd("BufEnter", {
        callback = function()
            local win = vim.api.nvim_get_current_win()
            if win ~= _loop_win then
                _check_winbar()
            end
        end,
    })

    vim.api.nvim_create_autocmd("WinResized", {
        callback = function()
            if _loop_win ~= -1 then
                _throttled_setup_tabs()
            end
        end,
    })

    vim.api.nvim_create_autocmd("VimResized", {
        callback = function()
            _apply_window_height()
        end,
    })
end

return M
