local M = {}

local logs = require('loop.logs')
local uitools = require('loop.tools.uitools')
local strtools = require('loop.tools.strtools')

---@param root string Normalized absolute path
---@param path string Normalized absolute path
local function _is_hidden_in_project(root, path)
	-- Check the file itself
	if vim.fs.basename(path):sub(1, 1) == "." then return true end
	-- Check parents, but STOP before checking the root folder name itself
	for parent in vim.fs.parents(path) do
		if parent == root then
			return false
		end
		if vim.fs.basename(parent):sub(1, 1) == "." then
			return true
		end
	end
	-- we did not reach the root, assume hidden for safety
	return true
end

---@param root string Normalized absolute path
---@param path string Normalized absolute path
local function _is_inside_folder(root, path)
	if path == root then return true end
	for parent in vim.fs.parents(path) do
		if parent == root then return true end
	end
	return false
end

---Generates and displays a notification for the save operation.
---@param saved_count number Total files saved.
---@param excluded_count number Total modified files skipped.
---@param saved_paths string[] List of relative paths that were saved.
local function _report_save_results(saved_count, excluded_count, saved_paths)
	if saved_count == 0 and excluded_count == 0 then return end

	local lines = {}
	if saved_count > 0 then
		table.insert(lines, ("󰄵 Saved %d file%s:"):format(saved_count, saved_count == 1 and "" or "s"))
		for i = 1, math.min(saved_count, 5) do
			table.insert(lines, ("  • %s"):format(saved_paths[i]))
		end
		if saved_count > 5 then
			table.insert(lines, ("  … and %d more"):format(saved_count - 5))
		end
	end

	if excluded_count > 0 then
		table.insert(lines, ("✖ Excluded %d modified file%s"):format(
			excluded_count, excluded_count == 1 and "" or "s"
		))
	end

	local level = saved_count > 0 and vim.log.levels.INFO or vim.log.levels.WARN
	vim.notify(table.concat(lines, '\n'), level)
end

---@param ws_dir string
---@param ws_config loop.WorkspaceConfig
function M.save_workspace_buffers(ws_dir, ws_config)
	local filter = ws_config.save
	-- Get absolute, normalized root
	local root_path = vim.fs.normalize(ws_dir)
	---@diagnostic disable-next-line: undefined-field
	local real_root = vim.uv.fs_realpath(root_path)
	if not real_root then return 0 end

	local saved, excluded, saved_paths = 0, 0, {}

	for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
		if not uitools.is_regular_buffer(bufnr) or not vim.bo[bufnr].modified then
			goto continue
		end

		local bname = vim.api.nvim_buf_get_name(bufnr)
		if bname == "" then goto continue end

		-- Always work with absolute paths for comparison
		local abs_bname = vim.fn.fnamemodify(bname, ":p")
		local norm_path = vim.fs.normalize(abs_bname)

		---@diagnostic disable-next-line: undefined-field
		local real_file_path = vim.uv.fs_realpath(norm_path)
		if not real_file_path then goto continue end

		-- 1. INSIDE CHECK
		if not _is_inside_folder(real_root, real_file_path) then
			excluded = excluded + 1
			goto continue
		end

		-- 2. HIDDEN CHECK (Project-relative)
		if _is_hidden_in_project(real_root, real_file_path) then
			excluded = excluded + 1
			goto continue
		end

		-- 3. SYMLINK CHECK
		-- We compare the normalized absolute path to the realpath
		if not filter.follow_symlinks and (norm_path ~= real_file_path) then
			excluded = excluded + 1
			goto continue
		end

		-- 4. GLOB FILTERS
		local inc = #filter.include > 0 and strtools.matches_any(norm_path, filter.include)
		local exc = #filter.exclude > 0 and strtools.matches_any(norm_path, filter.exclude)

		if (#filter.include > 0 and not inc) or exc then
			excluded = excluded + 1
			goto continue
		end

		-- 5. SAVE
		-- Use "update" instead of "write" to avoid rewriting if timestamp is same,
		local ok = pcall(function()
			vim.api.nvim_buf_call(bufnr, function() vim.cmd("silent update") end)
		end)

		if ok then
			saved = saved + 1
			table.insert(saved_paths, vim.fs.basename(norm_path))
		else
			excluded = excluded + 1
		end

		::continue::
	end

	_report_save_results(saved, excluded, saved_paths)

	-- Log user-friendly save message
	if saved > 0 then
		local msg = string.format("Saved %d file%s", saved, saved == 1 and "" or "s")
		if saved <= 5 then
			local file_list = table.concat(saved_paths, ", ")
			logs.user_log(msg .. ": " .. file_list, "save")
		else
			logs.user_log(msg, "save")
		end
	end

	return saved
end

return M
