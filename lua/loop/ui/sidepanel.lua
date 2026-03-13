local M = {}

local KEY_MARKER = "LoopPlugin_SideWin"
local INDEX_MARKER = "LoopPlugin_SideWinlIdx"

local _ui_auto_group = vim.api.nvim_create_augroup("LoopPlugin_SideView", { clear = true })

-- ======================================
-- State
-- ======================================

---@class loop.SideViewDef
---@field get_comp_buffers fun():loop.comp.BaseBuffer[]
---@field get_ratio fun():number[]
---@field ratios? number[]
---@field width_ratio? number

---@type table<string, loop.SideViewDef>
local _views = {}

---@type string|nil
local _active_view = nil

---@type loop.comp.BaseBuffer[]
local _active_buffers = {}

-- ======================================
-- Window Helpers
-- ======================================

local function is_managed_window(win)
    if not vim.api.nvim_win_is_valid(win) then
        return false
    end

    local ok, val = pcall(function()
        return vim.w[win][KEY_MARKER]
    end)

    return ok and val == true
end


local function get_window_index(win)
    local ok, val = pcall(function()
        return vim.w[win][INDEX_MARKER]
    end)

    return ok and val or 1
end


local function get_managed_windows()
    local wins = {}

    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        if is_managed_window(win) then
            table.insert(wins, win)
        end
    end

    table.sort(wins, function(a, b)
        return get_window_index(a) < get_window_index(b)
    end)

    return wins
end

local function apply_ratios(windows, ratios, width_ratio)
    if #windows == 0 then
        return
    end

    local total = 0

    for _, win in ipairs(windows) do
        total = total + vim.api.nvim_win_get_height(win)
    end

    local heights = {}
    local used = 0

    for i = 1, #windows - 1 do
        local r = ratios[i] or (1 / #windows)
        local h = math.floor(total * r)

        heights[i] = h
        used = used + h
    end

    heights[#windows] = total - used

    for i, win in ipairs(windows) do
        if vim.api.nvim_win_is_valid(win) then
            if i == 1 then
                local ratio = width_ratio or 0.20
                vim.api.nvim_win_set_width(win, math.floor(ratio * vim.o.columns))
            end

            vim.api.nvim_win_set_height(win, heights[i])
        end
    end
end

-- ======================================
-- Lifecycle
-- ======================================

local function destroy_buffers()
    for _, buf in ipairs(_active_buffers) do
        if buf.destroy then
            buf:destroy()
        end
    end

    _active_buffers = {}
end

-- ======================================
-- Registration
-- ======================================

function M.clear_view_defs()
    M.hide()
    _views = {}
    _active_view = nil
end

---@param name string
---@param def loop.SideViewDef
function M.register_new_view(name, def)
    assert(not _views[name], "View already registered: " .. name)
    _views[name] = def
    if not _active_view then
        _active_view = name
    end
end

---@return string[]
function M.view_names()
    return vim.fn.sort(vim.tbl_keys(_views))
end

-- ======================================
-- Show
-- ======================================

---@param name string?
function M.show(name)
    if not name then
        name = _active_view
    end
    if not name then
        vim.notify("No side view to show", vim.log.levels.ERROR)
        return
    end
    local def = _views[name]

    if not def then
        vim.notify("Unknown view: " .. name, vim.log.levels.ERROR)
        return
    end

    if not name or name == _active_view then
        local wins = get_managed_windows()
        if #wins > 0 then
            return
        end
    end

    _active_view = name

    if #_active_buffers > 0 then
        M.hide()
    end

    local buffers = def.get_comp_buffers()
    local ratios = def.ratios or def.get_ratio()
    local width_ratio = def.width_ratio

    if #buffers == 0 then
        return
    end

    local original = vim.api.nvim_get_current_win()

    -- Create container
    vim.cmd("topleft 1vsplit")

    local first = vim.api.nvim_get_current_win()

    local windows = { first }

    -- Create stacked windows
    for _ = 2, #buffers do
        vim.cmd("belowright split")
        table.insert(windows, vim.api.nvim_get_current_win())
    end

    -- Configure windows
    for i, win in ipairs(windows) do
        vim.wo[win].wrap = false
        vim.wo[win].spell = false
        vim.wo[win].winfixbuf = true
        vim.wo[win].winfixheight = true
        vim.wo[win].winfixwidth = true

        vim.w[win][KEY_MARKER] = true
        vim.w[win][INDEX_MARKER] = i
    end

    -- Attach buffers
    for i, buf in ipairs(buffers) do
        local win = windows[i]

        vim.wo[win].winfixbuf = false
        vim.api.nvim_win_set_buf(win, (buf:get_or_create_buf()))
        vim.wo[win].winfixbuf = true
    end

    apply_ratios(windows, ratios, width_ratio)

    if vim.api.nvim_win_is_valid(original) then
        vim.api.nvim_set_current_win(original)
    end

    _active_buffers = buffers

    -- Resize handling
    vim.api.nvim_clear_autocmds({ group = _ui_auto_group })
    vim.api.nvim_create_autocmd("VimResized", {
        group = _ui_auto_group,
        callback = function()
            local wins = get_managed_windows()
            local d = _views[_active_view]
            if not d then
                return
            end
            local r = d.ratios or d.get_ratio()
            apply_ratios(wins, r, d.width_ratio)
        end,
    })
end

function M.is_visible()
    local wins = get_managed_windows()
    return #wins > 0
end

function M.hide()
    local wins = get_managed_windows()

    vim.api.nvim_clear_autocmds({ group = _ui_auto_group })

    destroy_buffers()
    for _, win in ipairs(wins) do
        if vim.api.nvim_win_is_valid(win) then
            vim.api.nvim_win_close(win, true)
        end
    end
end

function M.toggle(name)
    local wins = get_managed_windows()
    if #wins > 0 then
        M.hide()
    else
        M.show(name)
    end
end

return M
