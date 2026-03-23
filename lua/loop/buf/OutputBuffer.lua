local class = require('loop.utils.class')
local strtools = require('loop.utils.strtools')
local BaseBuffer = require('loop.buf.BaseBuffer')

---@class loop.comp.OutputBuffer:loop.comp.BaseBuffer
---@field new fun(self: loop.comp.OutputBuffer,opts:loop.comp.BaseBufferOpts): loop.comp.OutputBuffer
---@field _auto_scroll boolean
local OutputBuffer = class(BaseBuffer)

---@param opts loop.comp.BaseBufferOpts
function OutputBuffer:init(opts)
    BaseBuffer.init(self, opts)
    self._auto_scroll = true
    self._max_lines = 10000
end

function OutputBuffer:destroy()
    BaseBuffer.destroy(self)
end

---@return loop.OutputBufferController
function OutputBuffer:make_controller()
    ---@type loop.OutputBufferController
    return {
        add_keymap = function(...) return self:add_keymap(...) end,
        disable_change_events = function() return self:disable_change_events() end,
        set_user_data = function(...) return self:set_user_data(...) end,
        get_user_data = function() return self:get_user_data() end,
        set_max_lines = function(n)
            self._max_lines = (type(n) == "number" and n > 0) and n or self._max_lines
        end,
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
    if bufnr < 0 then return end

    if type(lines) == "string" then
        lines = { lines }
    end

    lines = strtools.prepare_buffer_lines(lines)

    vim.bo[bufnr].modifiable = true

    local on_last_line, winid = self:_is_on_last_line()

    local line_count = vim.api.nvim_buf_line_count(bufnr)

    -- ------------------------------------------------------------
    -- 1. REMOVE excess lines FIRST (preserve trailing empty line)
    -- ------------------------------------------------------------
    local total_after_add = line_count - 1 + #lines + 1 -- replace empty + add new empty
    if total_after_add > self._max_lines then
        local excess = total_after_add - self._max_lines

        -- never delete the trailing empty line
        local delete_to = math.min(excess, line_count - 1)

        if delete_to > 0 then
            vim.api.nvim_buf_set_lines(bufnr, 0, delete_to, false, {})

            -- adjust cursor if needed
            local win = vim.fn.bufwinid(bufnr)
            if win ~= -1 then
                local cursor = vim.api.nvim_win_get_cursor(win)
                local new_line = math.max(1, cursor[1] - delete_to)
                vim.api.nvim_win_set_cursor(win, { new_line, cursor[2] })
            end
        end

        line_count = vim.api.nvim_buf_line_count(bufnr)
    end

    -- ------------------------------------------------------------
    -- 2. REPLACE the trailing empty line with new content
    -- ------------------------------------------------------------
    local insert_at = line_count - 1
    vim.api.nvim_buf_set_lines(bufnr, insert_at, line_count, false, lines)

    -- ------------------------------------------------------------
    -- 3. ALWAYS append a new empty line at the end
    -- ------------------------------------------------------------
    vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, { "" })

    vim.bo[bufnr].modifiable = false

    -- ------------------------------------------------------------
    -- 4. Auto-scroll (only if user was already at bottom)
    -- ------------------------------------------------------------
    if self._auto_scroll and on_last_line and winid > 0 then
        local new_count = vim.api.nvim_buf_line_count(bufnr)
        vim.api.nvim_win_set_cursor(winid, { new_count, 0 })
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
