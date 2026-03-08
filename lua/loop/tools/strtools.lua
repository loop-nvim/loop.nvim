local M = {}

---@return string
function M.special_marker1()
	-- this is a special UTF sequence that never appear in any text
	return "\240\159\188\128" -- U+EFF00
end

---@return string
function M.special_marker2()
	-- this is a special UTF sequence that never appear in any text
	return "\240\159\188\129"
end

---@return string
function M.special_marker3()
	-- this is a special UTF sequence that never appear in any text
	return "\240\159\188\130"
end

---@param lines string[] list of strings (may contain newlines)
---@return string[] flattened list of strings (no embedded newlines)
function M.prepare_buffer_lines(lines)
	local out = {}
	for _, line in ipairs(lines) do
		vim.list_extend(out, vim.fn.split(line, "\n", true))
	end
	return out
end

---@param str string
---@param max_len number
---@return string preview
---@return boolean is_different
function M.crop_string_for_ui(str, max_len)
	assert(type(str) == 'string', str)
	max_len = max_len > 2 and max_len or 2
	if #str <= max_len then return str, false end
	return str:sub(1, max_len - 1) .. "…", true
end

---@param path string
---@param max_len number
---@return string preview
---@return boolean is_different
function M.smart_crop_path(path, max_len)
	max_len = math.max(max_len, 0)
	local len = #path
	if len <= max_len then return path, false end
	-- Pre-calculate limit to avoid repeated math
	-- We need space for the ellipsis (1 byte)
	local limit = max_len - 1
	local sep = package.config:sub(1, 1)
	-- Find the last separator within the allowed limit from the end
	-- We look for the separator in the substring that fits
	local tail = path:sub(-limit)
	local sep_pos = tail:find(sep)
	if sep_pos then
		-- Return from the first separator found in the tail to the end
		return "…" .. tail:sub(sep_pos), true
	end
	-- Fallback: If no separator in the tail, just do a hard crop
	return "…" .. tail, true
end

---Helper to check if a path matches a list of glob patterns
---@param path string
---@param patterns string[]
---@return boolean
function M.matches_any(path, patterns)
	for _, pattern in ipairs(patterns) do
		-- Convert glob to Lua regex: **/*.lua -> .*/.*%.lua
		local regex = vim.fn.glob2regpat(pattern)
		if vim.fn.match(path, regex) ~= -1 then
			return true
		end
	end
	return false
end

---@param str string
---@return string
function M.human_case(str)
	-- Replace underscores with spaces
	str = str:gsub("_", " ")

	-- Insert space before uppercase letters (camelCase -> camel Case)
	str = str:gsub("(%l)(%u)", "%1 %2")

	-- Capitalize first letter of each word
	str = str:gsub("(%a)([%w']*)", function(first, rest)
		return first:upper() .. rest:lower()
	end)

	return str
end

-- Escape a single argument only if necessary
local function _escape_shell_arg(arg)
	arg = arg or ""
	-- Only escape if it contains shell-special characters or spaces
	if arg:match('[%s;&|$`"\'<>]') then
		-- Wrap in single quotes and escape existing single quotes
		arg = "'" .. (arg:gsub("'", "'\\''")) .. "'"
	end
	return arg
end

---@param cmd_and_args string[]
---@return string
function M.get_shell_command(cmd_and_args)
	local parts = {}
	-- Replace nils and escape each part as needed
	for i, str in ipairs(cmd_and_args) do
		table.insert(parts, _escape_shell_arg(str))
	end
	return table.concat(parts, " ")
end

---@param errors string[]|nil
---@return string[]
function M.indent_errors(errors, parent_msg)
	errors = errors or {}
	errors = vim.tbl_map(function(v)
		if type(v) == 'string' then
			return '  ' .. v
		else
			return '  ' .. vim.inspect(v)
		end
	end, errors or {})
	table.insert(errors, 1, parent_msg)
	return errors
end

---@param str string
---@return string[]
function M.split_shell_args(str)
	local args = {}
	local i = 1
	local len = #str

	local function skip_ws()
		while i <= len and str:sub(i, i):match("%s") do
			i = i + 1
		end
	end

	local function add(part)
		if part ~= "" then table.insert(args, part) end
	end

	while i <= len do
		skip_ws()
		if i > len then break end

		local part = {}
		local in_quote = nil

		while i <= len do
			local c = str:sub(i, i)
			local nxt = str:sub(i + 1, i + 1)

			-- whitespace ends token (unless inside quotes)
			if not in_quote and c:match("%s") then break end

			-- start quoted section
			if not in_quote and (c == '"' or c == "'") then
				in_quote = c
				i = i + 1
				goto continue
			end

			-- end quote
			if in_quote and c == in_quote then
				in_quote = nil
				i = i + 1
				goto continue
			end

			-- handle backslash escapes
			if c == "\\" and i + 1 <= len then
				local esc = nxt
				-- include escaped char literally
				if esc == "\n" then
					i = i + 2 -- line continuation
				else
					table.insert(part, esc)
					i = i + 2
				end
				goto continue
			end

			table.insert(part, c)
			i = i + 1
			::continue::
		end

		-- unterminated quote → keep literal opening quote
		if in_quote then
			table.insert(part, 1, in_quote)
		end

		add(table.concat(part))
	end

	return args
end

---@param cmd string|string[]
---@return string[]
function M.cmd_to_string_array(cmd)
	if type(cmd) == "string" then
		local arr = M.split_shell_args(cmd)
		assert(type(arr) == "table")
		return arr
	elseif type(cmd) == "table" then
		return cmd
	end
	return {}
end

function M.clean_and_split_lines(lines)
	local result = {}
	for _, line in ipairs(lines) do
		-- remove all \r
		line = line:gsub("\r", "")
		-- split on \n
		for part in line:gmatch("([^\n]*)\n?") do
			if part ~= "" then
				table.insert(result, part)
			end
		end
	end
	return result
end

local function _value_to_string(t, indent, seen)
	indent = indent or 0
	seen = seen or {}
	local lines = {}
	local function indent_str(level)
		return string.rep("  ", level)
	end
	local function is_seen(tbl)
		for _, v in ipairs(seen) do
			if v == tbl then return true end
		end
		return false
	end
	if type(t) ~= "table" then
		return indent_str(indent) .. tostring(t)
	end
	if is_seen(t) then
		return indent_str(indent) .. "*recursive table*"
	end
	table.insert(seen, t)
	table.insert(lines, indent_str(indent) .. "{")
	for k, v in pairs(t) do
		local keyStr = "[" .. tostring(k) .. "]"
		local valueStr

		if type(v) == "table" then
			valueStr = _value_to_string(v, indent + 1, seen)
		elseif type(v) == "string" then
			valueStr = '"' .. v .. '"'
		else
			valueStr = tostring(v)
		end

		table.insert(lines, indent_str(indent + 1) .. keyStr .. " = " .. valueStr)
	end
	table.insert(lines, indent_str(indent) .. "}")
	return table.concat(lines, "\n")
end


---@param val any
function M.to_pretty_str(val)
	return _value_to_string(val)
end

function M.format_grid(items, width)
	if #items == 0 then return "" end

	local max_len = 0
	for _, item in ipairs(items) do
		max_len = math.max(max_len, #item)
	end

	local col_width = max_len + 2 -- Add padding
	local num_cols = math.max(1, math.floor(width / col_width))
	local num_rows = math.ceil(#items / num_cols)

	local lines = {}
	for r = 1, num_rows do
		local row_items = {}
		for c = 1, num_cols do
			local idx = (c - 1) * num_rows + r
			if items[idx] then
				-- Pad the string to the column width
				table.insert(row_items, items[idx] .. string.rep(" ", col_width - #items[idx]))
			end
		end
		table.insert(lines, table.concat(row_items))
	end
	return table.concat(lines, "\r\n")
end

return M
