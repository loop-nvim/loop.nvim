local M = {}

local views = require("loop.ui.views")

local KEY_MARKER = "LoopPlugin_SideWin"
local INDEX_MARKER = "LoopPlugin_SideWinlIdx"

local _resize_auto_group = vim.api.nvim_create_augroup("LoopPlugin_SideBarResize", { clear = true })
local _buffers_auto_group = vim.api.nvim_create_augroup("LoopPlugin_SideBarBuffers", { clear = true })

-- ======================================
-- State
-- ======================================

---@type table<string, loop.SidebarPreset>
local _presets = {}

---@type string|nil
local _active_preset = nil

---@type {buffer:boolean}
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

---@param ratios number[]
local function _on_vim_resize(ratios)
    local wins = get_managed_windows()
    local d = _presets[_active_preset]
    if not d then
        return
    end
    if #wins == #ratios then
        apply_ratios(wins, ratios, d.width_ratio)
    end
end
local function _destroy_buffers()
    for bufnr, _ in pairs(_active_buffers) do
        if vim.api.nvim_buf_is_valid(bufnr) then
            vim.api.nvim_buf_delete(bufnr, { force = true })
        end
    end
    _active_buffers = {}
end

-- ======================================
-- Registration
-- ======================================

function M.clear_presets_defs()
    M.hide()
    _presets = {}
    _active_preset = nil
end

function M.reset_preset_defs()
    M.register_preset("files", {
        views = { { name = "files", ratio = 1 } }
    })
end

---@param name string
---@param def loop.SidebarPreset
function M.register_preset(name, def)
    assert(not _presets[name], "Preset already registered: " .. name)
    _presets[name] = def
    if not _active_preset then
        _active_preset = name
    end
end

---@return boolean
function M.have_views()
    return next(_presets) ~= nil
end

---@return string[]
function M.preset_names()
    return vim.fn.sort(vim.tbl_keys(_presets))
end

-- ======================================
-- Show
-- ======================================

---@param name string?
function M.show(name)
    if not name then
        name = _active_preset
    end
    if not name then
        vim.notify("No side panel available", vim.log.levels.ERROR)
        return
    end
    local def = _presets[name]

    if not def then
        vim.notify("Unknown view: " .. name, vim.log.levels.ERROR)
        return
    end

    local wins = get_managed_windows()

    if not name or name == _active_preset then
        if #wins > 0 then
            return
        end
    end

    _destroy_buffers()
    if #wins > 0 then
        M.hide()
    end

    _active_preset = name

    local width_ratio = 0.20

    local buffers = {}
    local ratios = {}
    local default_ratio = 1 / math.max(#def.views, 1)
    for _, view in ipairs(def.views) do
        local provider = views.get_view(view.name)
        if provider then
            local bufnr = provider.create_buffer()
            if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
                table.insert(buffers, bufnr)
                table.insert(ratios, view.ratio or default_ratio)
            end
        end
    end
    if #buffers == 0 then
        return
    end

    vim.api.nvim_clear_autocmds({ group = _buffers_auto_group })
    for i, buf in ipairs(buffers) do
        _active_buffers[buf] = true
        -- Detect if buffer is deleted externally
        vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
            buffer = buf,
            once = true,
            group = _buffers_auto_group,
            callback = function(args)
                _active_buffers[args.buf] = nil
            end,
        })
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
        vim.api.nvim_win_set_buf(win, buf)
        vim.wo[win].winfixbuf = true
    end

    apply_ratios(windows, ratios, width_ratio)

    if vim.api.nvim_win_is_valid(original) then
        vim.api.nvim_set_current_win(original)
    end

    -- Resize handling
    vim.api.nvim_clear_autocmds({ group = _resize_auto_group })
    vim.api.nvim_create_autocmd("VimResized", {
        group = _resize_auto_group,
        callback = function()
            _on_vim_resize(ratios)
        end,
    })
end

function M.is_visible()
    local wins = get_managed_windows()
    return #wins > 0
end

function M.hide()
    local wins = get_managed_windows()
    vim.api.nvim_clear_autocmds({ group = _resize_auto_group })
    -- destroy_buffers()
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
