local class = require('loop.tools.class')
local BaseBuffer = require('loop.buf.BaseBuffer')

---@class loop.comp.OutputBuffer:loop.comp.BaseBuffer
---@field new fun(self: loop.comp.OutputBuffer, type:string, name:string): loop.comp.OutputBuffer
---@field _auto_scroll boolean
local OutputBuffer = class(BaseBuffer)

---@param type string
---@param name string
function OutputBuffer:init(type, name)
    BaseBuffer.init(self, type, name)
    self._auto_scroll = true
end

function OutputBuffer:destroy()
    BaseBuffer.destroy(self)
end

---@return loop.OutputBufferController
function OutputBuffer:make_controller()
    return {
        add_keymap = function(...) return self:add_keymap(...) end,
        disable_change_events = function() return self:disable_change_events() end,
        get_cursor = function() return self:get_cursor() end,
        set_user_data = function(...) return self:set_user_data(...) end,
        get_user_data = function() return self:get_user_data() end,

        add_lines = function(lines)
            assert(getmetatable(self) == OutputBuffer)
            self:add_lines(lines)
        end,

        set_auto_scroll = function(v)
            self._auto_scroll = not not v
        end,
    }
end

function OutputBuffer:_setup_buf()
    BaseBuffer._setup_buf(self)
    local bufnr = self:get_buf()
    assert(bufnr > 0)
    vim.api.nvim_create_autocmd("BufWinEnter", {
        buffer = bufnr,
        callback = function(args)
            local buf = args.buf
            local winid = vim.fn.bufwinid(buf)
            if winid ~= -1 then
                local line_count = vim.api.nvim_buf_line_count(bufnr)
                vim.api.nvim_win_set_cursor(winid, { line_count, 0 })
            end
        end,
    })
end

---@param lines string|string[]
function OutputBuffer:add_lines(lines)
    if self:is_destroyed() then return end
    local bufnr = self:get_or_create_buf()

    if type(lines) == 'string' then
        lines = { lines }
    end

    local line_count = vim.api.nvim_buf_line_count(bufnr)

    local on_last_line, winid = self:_is_on_last_line()

    -- Determine where to insert
    local start_line
    if line_count == 1 and vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1] == "" then
        -- replace first empty line
        start_line = 0
        vim.bo[bufnr].modifiable = true
        vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, lines)
        vim.bo[bufnr].modifiable = false
    else
        -- append at end
        start_line = line_count
        vim.bo[bufnr].modifiable = true
        vim.api.nvim_buf_set_lines(bufnr, start_line, start_line, false, lines)
        vim.bo[bufnr].modifiable = false
    end

    if self._auto_scroll and on_last_line and winid > 0 then
        line_count = vim.api.nvim_buf_line_count(bufnr)
        vim.api.nvim_win_set_cursor(winid, { line_count, 0 })
    end

    self:request_change_notif()
end

---@return boolean,number
function OutputBuffer:_is_on_last_line()
    local win = vim.fn.bufwinid(self._buf)
    if win == -1 then return false, -1 end -- no visible window

    local last_line = vim.api.nvim_buf_line_count(self._buf)
    local cur_line = vim.api.nvim_win_get_cursor(win)[1]

    if cur_line < last_line then
        return false, -1
    end
    return true, win
end

return OutputBuffer
