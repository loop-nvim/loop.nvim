local class = require('loop.utils.class')
local strtools = require('loop.utils.strtools')
local uitools = require('loop.utils.uitools')
local BaseBuffer = require('loop.buf.BaseBuffer')

---@class loop.comp.ReplBuffer : loop.comp.BaseBuffer
---@field new fun(self: loop.comp.ReplBuffer, opts:loop.comp.BaseBufferOpts): loop.comp.ReplBuffer
---@field private _chan number|nil The terminal channel ID
---@field private _current_line string Current raw string in the input buffer
---@field private _cursor_pos number 1-indexed position of the cursor
---@field private _history string[] List of submitted commands
---@field private _history_idx number Navigation index for history
---@field private _prompt string The shell prompt with ANSI colors
---@field private _completion loop.ReplCompletionState Internal completion state
---@field private _input_handler fun(input: string)|nil Handler for Enter key
---@field private _completion_handler loop.ReplCompletionHandler|nil Provider for Tab suggestions
local ReplBuffer = class(BaseBuffer)

---@class loop.ReplCompletionState
---@field request_counter number Unique ID for the latest async request
---@field current_request number The ID of the request currently being waited on
---@field cycle_list string[] List of strings to cycle through
---@field cycle_idx number Current index in the cycle_list
---@field line_before_cycle string The left-hand side of the line before cycling started
---@field tail_after_cycle string The right-hand side of the line before cycling started
---@field has_shown_grid boolean Whether the first tab has already been processed

---@type table<string, string>
local COLORS = {
	RESET = "\27[0m",
	BOLD  = "\27[1m",
	GREEN = "\27[32m",
	BLUE  = "\27[34m",
	RED   = "\27[31m",
	CYAN  = "\27[36m",
}

---@param opts loop.comp.BaseBufferOpts
function ReplBuffer:init(opts)
	BaseBuffer.init(self, opts)
	self._chan = nil
	self._current_line = ""
	self._cursor_pos = 1
	self._history = {}
	self._history_idx = 0
	self._max_history = 100
	self._prompt = COLORS.BOLD .. COLORS.GREEN .. "> " .. COLORS.RESET

	self._completion = {
		request_counter = 0,
		current_request = -1,
		cycle_list = {},
		cycle_idx = 0,
		line_before_cycle = "",
		tail_after_cycle = "",
		has_shown_grid = false,
	}

	self._input_handler = nil
	self._completion_handler = nil
end

---@return loop.ReplController
function ReplBuffer:make_controller()
	return {
		set_input_handler = function(handler) self._input_handler = handler end,
		set_completion_handler = function(handler) self._completion_handler = handler end,
		add_output = function(text) self:send_line(text) end
	}
end

---Sends output text to the buffer and redraws the prompt
---@param text string
function ReplBuffer:send_line(text)
	if self:is_destroyed() then return end
	self:get_or_create_buf() -- ensure initialization to have the channel
	if self._chan then
		local formatted = "\r\27[K" .. text .. "\r\n" .. self._prompt .. self._current_line
		vim.api.nvim_chan_send(self._chan, formatted)
		self:_redraw_line()
		self:request_change_notif()
	end
end

---Redraws the input line and positions the terminal cursor
---@private
function ReplBuffer:_redraw_line()
	local clean_prompt = self._prompt:gsub("\27%[[%d;]*m", "")
	local col = #clean_prompt + self._cursor_pos
	local out = "\r\27[K" .. self._prompt .. self._current_line .. "\27[" .. col .. "G"
	vim.api.nvim_chan_send(self._chan, out)
end

---Resets completion cycling state
---@private
function ReplBuffer:_reset_cycle()
	self._completion.cycle_list = {}
	self._completion.cycle_idx = 0
	self._completion.line_before_cycle = ""
	self._completion.tail_after_cycle = ""
	self._completion.has_shown_grid = false
end

---Sets up terminal buffer and keymaps
---@private
function ReplBuffer:_setup_buf()
	BaseBuffer._setup_buf(self)
	local buf = self:get_buf()
	vim.keymap.set('t', '<Esc>', function() vim.cmd('stopinsert') end, { buffer = buf })
	vim.keymap.set('t', '<Tab>', function() self:_handle_raw_input("\t") end, { buffer = buf, silent = true })

	self._chan = vim.api.nvim_open_term(buf, {
		on_input = function(_, _, _, data) self:_handle_raw_input(data) end
	})
	self:_redraw_line()
end

---Executes an async completion request with state validation
---@param line_to_cursor string
---@param callback fun(targets: string[]|table[])
function ReplBuffer:on_complete(line_to_cursor, callback)
	if not self._completion_handler then return callback({}) end

	self._completion.request_counter = self._completion.request_counter + 1
	local request_id = self._completion.request_counter
	local pos_at_request = self._cursor_pos

	self._completion_handler(line_to_cursor, function(targets, err)
		vim.schedule(function()
			local current_left = self._current_line:sub(1, self._cursor_pos - 1)
			if request_id == self._completion.request_counter
				and self._cursor_pos == pos_at_request
				and current_left == line_to_cursor then
				if targets then
					callback(targets)
				elseif err then
					self:send_line(err)
				end
			end
		end)
	end)
end

---Cycles to the next completion candidate in the prompt
---@private
function ReplBuffer:_cycle_next()
	local c = self._completion
	if #c.cycle_list == 0 then return end

	c.cycle_idx = c.cycle_idx + 1
	if c.cycle_idx > #c.cycle_list then
		c.cycle_idx = 1
	end

	local item = c.cycle_list[c.cycle_idx]
	local suggestion = type(item) == "table" and item.text or item

	local original_left = c.line_before_cycle
	local right = c.tail_after_cycle

	local new_before

	-- CASE 0: beginning of line → replace whole line
	if original_left == "" then
		new_before = suggestion

		-- CASE 1: suggestion completes entire left side
	elseif suggestion:sub(1, #original_left) == original_left then
		new_before = suggestion

		-- CASE 2: replace only last word
	else
		local prefix = original_left:match("^(.-)%S*$") or ""
		new_before = prefix .. suggestion
	end

	self._current_line = new_before .. right
	self._cursor_pos = #new_before + 1
	self:_redraw_line()
end

---Primary input state machine
---@private
---@param data string
function ReplBuffer:_handle_raw_input(data)
	-- 1. Ctrl+C (Interrupt)
	if data == "\3" then
		self:_reset_cycle()
		vim.api.nvim_chan_send(self._chan, "^C\r\n")
		self._current_line = ""
		self._cursor_pos = 1
		self:_redraw_line()
		return
	end

	-- 2. Ctrl+A (Start of Line)
	if data == "\1" then
		self:_reset_cycle()
		self._cursor_pos = 1
		self:_redraw_line()
		return
	end

	-- 3. Ctrl+E (End of Line)
	if data == "\5" then
		self:_reset_cycle()
		self._cursor_pos = #self._current_line + 1
		self:_redraw_line()
		return
	end

	-- 4. Ctrl+W (Delete Word Backward)
	if data == "\23" then
		self:_reset_cycle()
		if self._cursor_pos > 1 then
			local left = self._current_line:sub(1, self._cursor_pos - 1)
			local right = self._current_line:sub(self._cursor_pos)
			local new_left = left:gsub("%s*[^%s]+%s*$", "")
			self._current_line = new_left .. right
			self._cursor_pos = #new_left + 1
			self:_redraw_line()
		end
		return
	end

	-- 5. Enter (Submit)
	if data == "\r" or data == "\n" then
		local line = self._current_line
		self:_reset_cycle()
		vim.api.nvim_chan_send(self._chan, "\r\n")
		self._current_line = ""
		self._cursor_pos = 1
		self._history_idx = 0
		if line ~= "" and self._history[#self._history] ~= line then
			table.insert(self._history, line)
			if #self._history > self._max_history then
				table.remove(self._history, 1)
			end
		end
		if line ~= "" and self._input_handler then self._input_handler(line) end
		vim.api.nvim_chan_send(self._chan, "\r\27[K" .. self._prompt)
		return
	end

	-- 6. Tab (Bash Style: Grid first, then Cycle)
	if data == "\t" then
		local c = self._completion

		-- If we have results and already showed the grid, start cycling
		if #c.cycle_list > 0 and c.has_shown_grid then
			self:_cycle_next()
			return
		end

		local is_at_end = self._cursor_pos > #self._current_line
		local char_after = self._current_line:sub(self._cursor_pos, self._cursor_pos)

		if is_at_end or char_after == " " then
			local left = self._current_line:sub(1, self._cursor_pos - 1)
			local right = self._current_line:sub(self._cursor_pos)

			self:on_complete(left, function(targets)
				if #targets == 0 then return end

				local items = {}
				for _, t in ipairs(targets) do
					table.insert(items, type(t) == "table" and t.text or t)
				end

				c.cycle_list = items
				c.line_before_cycle = left
				c.tail_after_cycle = right

				if #items == 1 then
					-- If only one item, Bash completes it immediately
					self:_cycle_next()
				else
					-- Multiple items: Show grid, set flag, do NOT change text yet
					local win_width = uitools.get_window_text_width()
					local grid = strtools.format_grid(items, win_width)
					vim.api.nvim_chan_send(self._chan, "\r\n" .. grid .. "\r\n")
					c.has_shown_grid = true
					self:_redraw_line()
				end
			end)
		end
		return
	end

	-- Any other input breaks completion cycle
	self:_reset_cycle()

	-- 7. History (Up/Ctrl+P, Down/Ctrl+N)
	if data == "\27[A" or data == "\16" then -- Up / Ctrl-P
		if #self._history == 0 then return end
		-- First press from fresh line → go to last entry
		if self._history_idx == 0 then
			self._history_idx = #self._history
		else
			self._history_idx = math.max(1, self._history_idx - 1)
		end
		self._current_line = self._history[self._history_idx]
		self._cursor_pos = #self._current_line + 1
		self:_redraw_line()
		return
	elseif data == "\27[B" or data == "\14" then -- Down / Ctrl-N
		if self._history_idx == 0 then return end
		if self._history_idx < #self._history then
			self._history_idx = self._history_idx + 1
			self._current_line = self._history[self._history_idx]
		else
			-- Past newest → blank line
			self._history_idx = 0
			self._current_line = ""
		end
		self._cursor_pos = #self._current_line + 1
		self:_redraw_line()
		return
	end

	-- 8. Navigation (Left/Right)
	if data == "\27[D" then -- Left
		if self._cursor_pos > 1 then self._cursor_pos = self._cursor_pos - 1 end
		self:_redraw_line()
		return
	elseif data == "\27[C" then -- Right
		if self._cursor_pos <= #self._current_line then self._cursor_pos = self._cursor_pos + 1 end
		self:_redraw_line()
		return
	end

	-- 9. Backspace
	if data == "\b" or data == string.char(127) then
		if self._cursor_pos > 1 then
			local left = self._current_line:sub(1, self._cursor_pos - 2)
			local right = self._current_line:sub(self._cursor_pos)
			self._current_line = left .. right
			self._cursor_pos = self._cursor_pos - 1
			self:_redraw_line()
		end
		return
	end

	-- 10. Regular Input
	if not data:find("^\27") then
		local left = self._current_line:sub(1, self._cursor_pos - 1)
		local right = self._current_line:sub(self._cursor_pos)
		self._current_line = left .. data .. right
		self._cursor_pos = self._cursor_pos + #data
		self:_redraw_line()
		return
	end
end

return ReplBuffer
