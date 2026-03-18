local M = {}

local views = require("loop.ui.views")

local KEY_MARKER = "LoopPlugin_SideWin"
local INDEX_MARKER = "LoopPlugin_SideWinlIdx"

local _resize_auto_group = vim.api.nvim_create_augroup("LoopPlugin_SideBarResize", { clear = true })
local _buffers_auto_group = vim.api.nvim_create_augroup("LoopPlugin_SideBarBuffers", { clear = true })

-- ======================================
-- State
-- ======================================

---@type table<number, loop.SidebarPreset>
local _presets = {}
local _next_id = 1

---@type number?
local _active_preset_id = nil

---@type {buffer:boolean}
local _active_buffers = {}

---@type boolean
local _workspace_open = false

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
    local d = _presets[_active_preset_id]
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

---@param id number?
---@return boolean
local function _show(id)
    if not id then
        id = _active_preset_id
    end
    if not id then
        return false
    end
    local def = _presets[id]

    if not def then
        return false
    end

    local wins = get_managed_windows()

    if not id or id == _active_preset_id then
        if #wins > 0 then
            return true
        end
    end

    _destroy_buffers()
    if #wins > 0 then
        M.hide()
    end

    _active_preset_id = id

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
        return false
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

    return true
end


-- ======================================
-- Public API
-- ======================================

function M.on_workspace_close()
    M.hide()
    _presets = {}
    _next_id = 1
    _active_preset_id = nil
end

function M.on_workspace_open()
    M.register_preset({
        name = "files",
        views = { { name = "files", ratio = 1 } }
    })
    _workspace_open = true
    _show()
end

---@param def loop.SidebarPreset
---@return number -- id
function M.register_preset(def)
    local id = _next_id
    _next_id = _next_id + 1

    -- Resolve naming conflicts
    local original_name = def.name
    local counter = 1
    local is_duplicate = true

    while is_duplicate do
        is_duplicate = false
        for _, existing in pairs(_presets) do
            if existing.name == def.name then
                def.name = original_name .. "_" .. counter
                counter = counter + 1
                is_duplicate = true
                break
            end
        end
    end

    _presets[id] = def

    if not _active_preset_id then
        _active_preset_id = id
    end

    return id
end

---@param id number
function M.show_by_id(id)
    if _presets[id] then
        _show(id)
    end
end

---@return boolean
function M.have_views()
    return next(_presets) ~= nil
end

---@return string[]
function M.preset_names()
    local names = {}
    for _, p in pairs(_presets) do table.insert(names, p.name) end
    table.sort(names)
    return names
end

---@param name string?
function M.show(name)
    if not _workspace_open then
        vim.notify("[loop.nvim] No active workspace", vim.log.levels.ERROR)
        return
    end
    if not name then
        return _show()
    end
    for id, info in pairs(_presets) do
        if name == info.name then
            return _show(id)
        end
    end
    vim.notify("[loop.nvim] Invalid sidebar name: " .. tostring(name), vim.log.levels.WARN)
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
            -- avoid error when closing last window on vim exit
            pcall(vim.api.nvim_win_close, win)
        end
    end
    _destroy_buffers()
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
