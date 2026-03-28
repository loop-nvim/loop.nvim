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
    if bufnr <= 0 then return end

    -- 1. Standardize input
    if type(lines) == "string" then
        lines = { lines }
    end

    lines = strtools.prepare_buffer_lines(lines)
    local num_new_lines = #lines
    if num_new_lines == 0 then return end

    -- 2. Capture state before modification
    local line_count = vim.api.nvim_buf_line_count(bufnr)
    
    -- Check if the buffer is currently just a single empty line
    local is_empty_start = line_count == 1 and vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1] == ""

    local autoscrool_wins
    if self._auto_scroll then
        autoscrool_wins = {}
        local wins = vim.fn.win_findbuf(bufnr)
        for _, win in ipairs(wins) do
            local cursor = vim.api.nvim_win_get_cursor(win)
            -- If cursor is on the last line, mark for scrolling
            if cursor[1] >= line_count then
                autoscrool_wins[win] = true
            end
        end
    end

    -- 3. Handle Overflow (FIFO)
    vim.bo[bufnr].modifiable = true
    if (line_count + num_new_lines) > self._max_lines then
        local excess = (line_count + num_new_lines) - self._max_lines
        local delete_to = math.min(excess, line_count)

        if delete_to > 0 then
            vim.api.nvim_buf_set_lines(bufnr, 0, delete_to, false, {})
            line_count = vim.api.nvim_buf_line_count(bufnr)
            -- If we deleted content, it's no longer a "fresh" empty buffer
            is_empty_start = false
        end
    end

    -- 4. Append or Replace New Lines
    if is_empty_start then
        -- Replace the initial placeholder [""] with the new lines
        vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, lines)
    else
        -- Append to the end of the buffer
        vim.api.nvim_buf_set_lines(bufnr, line_count, -1, false, lines)
    end
    vim.bo[bufnr].modifiable = false

    -- 5. Auto-scroll
    if self._auto_scroll then
        local new_line_count = vim.api.nvim_buf_line_count(bufnr)
        for win, _ in pairs(autoscrool_wins) do
            vim.api.nvim_win_set_cursor(win, { new_line_count, 0 })
        end
    end

    self:request_change_notif()
end

return OutputBuffer
