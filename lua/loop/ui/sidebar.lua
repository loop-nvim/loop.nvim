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
-- State
-- ======================================

local _state = {
    is_visible = false,
    width_ratio = nil,
    ---@type table<string, number[]> -- Maps preset name to array of vertical ratios
    ratios = {}
}

-- ======================================
-- Window Helpers
-- ======================================

local function _is_managed_window(win)
    if not vim.api.nvim_win_is_valid(win) then
        return false
    end

    local ok, val = pcall(function()
        return vim.w[win][KEY_MARKER]
    end)

    return ok and val == true
end


local function _get_window_index(win)
    local ok, val = pcall(function()
        return vim.w[win][INDEX_MARKER]
    end)

    return ok and val or nil
end


local function _get_managed_windows()
    local wins = {}

    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        if _is_managed_window(win) then
            table.insert(wins, win)
        end
    end

    table.sort(wins, function(a, b)
        return (_get_window_index(a) or 1) < (_get_window_index(b) or 1)
    end)

    return wins
end

---@param win number
local function _set_custom_win_flags(win)
    vim.wo[win].wrap = false
    vim.wo[win].spell = false
    vim.wo[win].winfixbuf = true
    vim.wo[win].winfixheight = true
    vim.wo[win].winfixwidth = true
end

-- Validate that windows are stacked vertically
local function _are_windows_stacked_vertically(wins)
    if #wins <= 1 then return true end

    local first_win_pos = vim.api.nvim_win_get_position(wins[1])
    local first_col = first_win_pos[2] -- [row, col]

    for i = 2, #wins do
        local pos = vim.api.nvim_win_get_position(wins[i])
        -- If any window starts at a different column, they aren't in a single vertical stack
        if pos[2] ~= first_col then
            return false
        end
    end
    return true
end

local function _save_current_layout_to_state()
    if not _active_preset_id then return end
    local wins = _get_managed_windows()
    if #wins == 0 then return end

    local preset = _presets[_active_preset_id]
    if not preset then return end

    local total_w = vim.o.columns
    local total_h = vim.o.lines - vim.o.cmdheight

    -- Save Global Width Ratio
    local actual_w = vim.api.nvim_win_get_width(wins[1])
    _state.width_ratio = actual_w / total_w

    -- Save Vertical Ratios for this specific preset name
    local current_ratios = {}
    for _, win in ipairs(wins) do
        local actual_h = vim.api.nvim_win_get_height(win)
        table.insert(current_ratios, actual_h / total_h)
    end
    _state.ratios[preset.name] = current_ratios
end

local function _apply_ratios()
    ---@type loop.SidebarPreset?
    local preset = _presets[_active_preset_id]
    if not preset then
        return
    end

    local windows = _get_managed_windows()
    if #preset.views ~= #windows then
        -- "sidebar window were altered, skipping resize"
        return
    end

    if not _are_windows_stacked_vertically(windows) then
        -- sidebar window are not stacked vertically, skipping resize
        return
    end

    local active_ratios = _state.ratios[preset.name]
    
    local width_ratio = _state.width_ratio or 0.2
    local ratios = {}
    for i, viewdef in ipairs(preset.views) do
        local view = views.get_view_info(viewdef.view_id)
        local r = (active_ratios and active_ratios[i]) or view and viewdef.ratio or 0
        table.insert(ratios, r)
    end


    local num_wins = #windows
    if num_wins == 0 then return end

    -- 1. Handle Global Sidebar Width
    local total_ui_width = vim.o.columns
    local target_width = math.floor(total_ui_width * (width_ratio or .2))

    -- 2. Calculate Vertical Heights
    local total_ui_height = vim.o.lines - vim.o.cmdheight -- account for status/cmd line
    local fixed_ratio_sum = 0
    local nil_count = 0

    for _, r in ipairs(ratios) do
        if r and r > 0 then
            fixed_ratio_sum = fixed_ratio_sum + r
        else
            nil_count = nil_count + 1
        end
    end

    -- If ratio sum is > 1, we normalize it; if < 1, nils take the remainder
    local remaining_ratio = math.max(0, 1 - fixed_ratio_sum)
    local ratio_per_nil = nil_count > 0 and (remaining_ratio / nil_count) or 0

    -- 3. Apply Dimensions
    for i = num_wins, 1, -1 do
        local win = windows[i]
        if vim.api.nvim_win_is_valid(win) then
            -- Set Width (Consistent for all sidebar windows)
            vim.api.nvim_win_set_width(win, target_width)

            -- Set Height
            local r = ratios[i]
            if not r or r <= 0 then r = ratio_per_nil end
            local target_height = math.floor(total_ui_height * r)

            -- Ensure at least 1 line height to avoid errors
            vim.api.nvim_win_set_height(win, math.max(target_height, 1))
        end
    end
end

local function _fix_layout()
    local windows = _get_managed_windows()
    if #windows <= 0 then return end
    if not _are_windows_stacked_vertically(windows) then
        return
    end
    -- 1. Setup the Anchor (Move first window to far left)
    local anchor_win = windows[1]
    local width = vim.api.nvim_win_get_width(anchor_win)
    -- Force the anchor to the FAR LEFT using the layout-breaking command
    vim.api.nvim_win_call(anchor_win, function()
        vim.cmd("wincmd H")
    end)
    vim.api.nvim_win_set_width(anchor_win, width)
    -- 2. Move existing windows into the stack
    local last_win = anchor_win
    for i = 2, #windows do
        local win = windows[i]
        vim.fn.win_splitmove(win, last_win, { vertical = false, rightbelow = true })
        last_win = win
    end
    _apply_ratios()
end

local function _on_vim_resize(r)
    _apply_ratios()
end
local function _destroy_buffers()
    for bufnr, _ in pairs(_active_buffers) do
        if vim.api.nvim_buf_is_valid(bufnr) then
            vim.api.nvim_buf_delete(bufnr, { force = true })
        end
    end
    _active_buffers = {}
end

local function _hide()
    local wins = _get_managed_windows()
    if #wins > 0 then
        _save_current_layout_to_state()
    end
    vim.api.nvim_clear_autocmds({ group = _resize_auto_group })
    -- destroy_buffers()
    for _, win in ipairs(wins) do
        if vim.api.nvim_win_is_valid(win) then
            -- avoid error when closing last window on vim exit
            pcall(vim.api.nvim_win_close, win)
        end
    end
    _destroy_buffers()
    _state.is_visible = true
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

    local wins = _get_managed_windows()

    if not id or id == _active_preset_id then
        if #wins > 0 then
            return true
        end
    end

    _destroy_buffers()
    if #wins > 0 then
        _hide()
    end

    _active_preset_id = id
    _state.is_visible = true

    local buffers = {}
    for _, viewdef in ipairs(def.views) do
        local view = views.get_view_info(viewdef.view_id)
        if view and view.provider then
            local bufnr = view.provider.create_buffer()
            if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
                table.insert(buffers, bufnr)
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
        _set_custom_win_flags(win)
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

    _apply_ratios()

    if vim.api.nvim_win_is_valid(original) then
        vim.api.nvim_set_current_win(original)
    end

    -- Resize handling
    vim.api.nvim_clear_autocmds({ group = _resize_auto_group })
    vim.api.nvim_create_autocmd("VimResized", {
        group = _resize_auto_group,
        callback = function()
            _on_vim_resize()
        end,
    })

    return true
end

-- ======================================
-- Public API
-- ======================================

function M.on_workspace_close()
    _hide()
    _presets = {}
    _active_preset_id = nil
    -- don't reset _next_id so that old ids expire
end

function M.on_workspace_open()
    local FileTree = require("loop.ui.FileTree")
    local tree = FileTree:new()
    ---@type loop.ViewProvider
    local provider = {
        create_buffer = function()
            local buf = tree:get_compbuffer():get_or_create_buf()
            return buf
        end,
    }
    local view_id = views.register_view("files", provider)
    M.register_preset({
        name = "files",
        views = { { view_id = view_id, ratio = 1 } }
    })
    _workspace_open = true
    if _state.is_visible ~= false then
        _show()
    end
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
    local wins = _get_managed_windows()
    return #wins > 0
end

function M.hide()
    _hide()
end

function M.toggle()
    local wins = _get_managed_windows()
    if #wins > 0 then
        _hide()
    else
        _show()
    end
end

function M.save_layout()
    _save_current_layout_to_state()
end

function M.fix_layout()
    return _fix_layout()
end

return M
