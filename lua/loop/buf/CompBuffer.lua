local class = require('loop.tools.class')
local BaseBuffer = require('loop.buf.BaseBuffer')
local throttle = require('loop.tools.throttle')

---@class loop.comp.CompBufferOpts
---@field name string
---@field filetype string
---@field listed boolean?

---@class loop.comp.CompBuffer:loop.comp.BaseBuffer
---@field new fun(self: loop.comp.CompBuffer, opts : loop.comp.CompBufferOpts): loop.comp.CompBuffer
---@field _renderer loop.CompRenderer|nil
---@field _render_schdl_pending boolean?
local CompBuffer = class(BaseBuffer)

---@param opts loop.comp.CompBufferOpts
function CompBuffer:init(opts)
    ---@type loop.comp.BaseBufferOpts
    local base_opts = {
        name = opts.name,
        filetype = opts.filetype,
        listed = opts.listed,
        bufhidden = opts.listed and "" or "wipe"
    }
    BaseBuffer.init(self, base_opts)
    self._throttled_render = throttle.throttle_wrap(100, function()
        self:_immediate_render()
    end)
end

function CompBuffer:destroy()
    BaseBuffer.destroy(self)
    if self._renderer then
        self._renderer.dispose()
    end
end

---@return loop.CompBufferController
function CompBuffer:make_controller()
    ---@type loop.CompBufferController
    return {
        add_keymap = function(...) return self:add_keymap(...) end,
        disable_change_events = function() return self:disable_change_events() end,
        set_cursor = function(cur) self:set_cursor(cur) end,
        get_cursor = function() return self:get_cursor() end,
        set_user_data = function(...) return self:set_user_data(...) end,
        get_user_data = function() return self:get_user_data() end,
        set_renderer = function(renderer) self:set_renderer(renderer) end,
        request_refresh = function() self:render() end,
    }
end

---@return number -- buffer number
---@return boolean refresh_needed
function CompBuffer:get_or_create_buf()
    local bufnr, refresh_needed = BaseBuffer.get_or_create_buf(self)
    vim.bo[bufnr].spelloptions = "noplainbuffer"
    if refresh_needed and self._renderer then
        self._renderer.render(bufnr)
    end
    return bufnr, refresh_needed
end

---@param renderer loop.CompRenderer
function CompBuffer:set_renderer(renderer)
    if self._renderer then
        self._renderer.dispose()
    end
    self._renderer = renderer
end

function CompBuffer:render()
    -- the schedule() improves the first render when it's called multiple times
    if self._render_schdl_pending ~= true then
        self._render_schdl_pending = true
        vim.schedule(function()
            self._render_schdl_pending = false
            self._throttled_render()
        end)
    end
end

function CompBuffer:_immediate_render()
    local buf = self:get_buf()
    if not buf or buf <= 0 then return end
    if not self._renderer then return end

    local changed = self._renderer.render(buf)
    if changed then
        self:request_change_notif()
    end
end

---@return integer[]|nil
function CompBuffer:get_cursor()
    local windid
    if vim.api.nvim_get_current_buf() == self._buf then
        windid = vim.api.nvim_get_current_win()
    else
        windid = vim.fn.bufwinid(self._buf)
    end
    return windid > 0 and vim.api.nvim_win_get_cursor(windid) or nil
end

---@param cur number
function CompBuffer:set_cursor(cur)
    local windid
    if vim.api.nvim_get_current_buf() == self._buf then
        windid = vim.api.nvim_get_current_win()
    else
        windid = vim.fn.bufwinid(self._buf)
    end
    if windid > 0 then
        vim.api.nvim_win_set_cursor(windid, { cur, 0 })
        vim.schedule(function()
            if vim.api.nvim_win_is_valid(windid) then
                vim.api.nvim_win_call(windid, function()
                    vim.cmd("normal! zz")
                end)
            end
        end)
    end
end

return CompBuffer
