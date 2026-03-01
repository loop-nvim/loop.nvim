local class    = require('loop.tools.class')
local uitools  = require('loop.tools.uitools')
local strtools = require('loop.tools.strtools')

---@class loop.tools.TermProc
---@field new fun(self: loop.tools.TermProc) : loop.tools.TermProc
---@field is_running fun(self: loop.tools.TermProc):boolean
---@field terminate fun(self: loop.tools.TermProc)
local TermProc = class()

---Initializes the TermProc instance.
function TermProc:init()
	---@type number
	self.job_id = -1
end

---@return boolean
function TermProc:is_running()
	return self.job_id ~= -1
end

function TermProc:close_stdin()
	if self.job_id ~= -1 then
		vim.fn.chanclose(self.job_id, "stdin")
	end
end

function TermProc:terminate()
	if self.job_id ~= -1 then
		vim.fn.jobstop(self.job_id)
	end
end

function TermProc:get_pid()
	return vim.fn.jobpid(self.job_id)
end

---@class loop.tools.TermProc.StartArgs
---@field name string
---@field command string|string[]
---@field env table<string,string>|nil
---@field cwd string|nil
---@field output_handler fun(stream: "stdout"|"stderr", data: string[])|nil
---@field on_exit_handler fun(code : number)|nil

---Starts a new terminal job.
---@param bufnr number
---@param args loop.tools.TermProc.StartArgs
---@return boolean success
---@return string|nil error msg or nil
function TermProc:start(bufnr, args)
	if self.job_id ~= -1 then
		return false, "already started"
	end

	assert(args.on_exit_handler)
	assert(type(args.command) == 'string' or type(args.command) == 'table')
	assert(not args.env or type(args.env) == 'table')

	-- get the real path (no symlinks etc..., important for cmake)
	local cwd = args.cwd and vim.fn.fnamemodify(vim.fn.resolve(args.cwd), ':p')

	---@type table<string,string>
	local env = args.env and vim.deepcopy(args.env) or {}
	if cwd then
		env.PWD = cwd -- required for commands to use cwd in all cases
	end

	---@type string[]
	local cmd_and_args = strtools.cmd_to_string_array(args.command)

	if #cmd_and_args == 0 then
		return false, "command is missing"
	end

	if vim.fn.executable(cmd_and_args[1]) == 0 then
		return false, "command is not an executable: " .. cmd_and_args[1]
	end

	local ok, err
	vim.api.nvim_buf_call(bufnr, function()
		ok, err = self:_start_term_job(cmd_and_args, env, cwd, args.output_handler,
			args.on_exit_handler)
	end)
	return ok, err
end

---@param cmd_and_args string[]
---@param env table<string,string>|nil
---@param cwd string|nil
---@param output_handler fun(stream: "stdout"|"stderr", data: string[])|nil
---@param on_exit_handler fun(code : number)
---@return boolean, string|nil
function TermProc:_start_term_job(cmd_and_args, env, cwd, output_handler, on_exit_handler)
	assert(type(cmd_and_args) ~= 'string')
	self.job_id = vim.fn.jobstart(cmd_and_args, {
		term = true,
		pty = true,
		cwd = cwd,
		env = env,
		on_stdout = function(_, data, _)
			if output_handler then
				output_handler("stdout", data)
			end
		end,
		on_stderr = function(_, data, _)
			if output_handler then
				output_handler("stderr", data)
			end
		end,
		on_exit = function(_, code, _)
			self.job_id = -1
			on_exit_handler(code)
		end,
	})

	if self.job_id <= 0 then
		self.job_id = -1
		return false, "Failed to start terminal job"
	end

	local full_cmd = table.concat(cmd_and_args, " ")
	vim.api.nvim_chan_send(self.job_id, string.format("%s\r\n", full_cmd))

	return true, nil
end

return TermProc
