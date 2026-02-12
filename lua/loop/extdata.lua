local M = {}

local extensions = require('loop.extensions')
local taskproviders = require('loop.task.providers')
local filetools = require('loop.tools.file')
local jsoncodec = require('loop.json.codec')

---@type table<string,table>
local _extension_states = {}

---@type table<string,loop.ExtensionData>
local _extension_data = {}

---@type table<string,loop.UserCommandProvider>
local _cmd_providers = {}
local _reserved_cmd_providers = {
	workspace = true,
	ui = true,
	page = true,
	logs = true,
	help = true,
	task = true,
	var = true
}

---@type table<string,string>
local _task_providers = {}
local _reserved_task_types = {
	composite = true, build = true, run = true
}

---@param config_dir string
---@param ext_name string
---@param key string
---@param fileext string?
---@return string
local function _get_config_file_path(config_dir, ext_name, key, fileext)
	fileext = fileext or "json"
	assert(type(key) == 'string' and key:match("[_%a][_%w]*") ~= nil,
		"Invalid configuration key: " .. tostring(key))
	assert(type(fileext) == 'string' and fileext:match("[_%a][_%w]*") ~= nil,
		"Invalid configuration fileext: " .. tostring(fileext))
	return vim.fs.joinpath(config_dir, ("ext.%s.%s.%s"):format(ext_name, key, fileext))
end


---@param ext_name  string
---@return loop.ExtensionState
local function _make_state_handler(ext_name)
	local data = _extension_states[ext_name]
	assert(data)
	---@type loop.ExtensionState
	local state = {
		set = function(fieldname, fieldvalue) data[fieldname] = fieldvalue end,
		get = function(fieldname) return data[fieldname] end,
		keys = function() return vim.tbl_keys(data) end
	}
	return state
end

---@param config_dir string
---@param ext_name string
local function _load_state(config_dir, ext_name)
	assert(ext_name and ext_name:match("[_%a][_%w]*") ~= nil, "invalid input")
	local data = {}
	local filepath = vim.fs.joinpath(config_dir, "state." .. ext_name .. ".json")
	if filetools.file_exists(filepath) then
		local decoded, data_or_err = jsoncodec.load_from_file(filepath)
		assert(decoded, "failed to load state file for " .. ext_name)
		_extension_states[ext_name] = data_or_err or {}
	else
		_extension_states[ext_name] = {}
	end
end

---@param task_type string
---@param provider loop.TaskTypeProvider
local function _register_task_type_provider(task_type, provider)
	taskproviders.register_task_provider(task_type, provider)
end

---@param category string
---@param provider loop.TaskTemplateProvider
local function _register_task_template_provider(category, provider)
	taskproviders.register_template_provider(category, provider)
end

---@param lead_cmd string
---@param provider loop.UserCommandProvider
local function _register_cmd_provider(lead_cmd, provider)
	assert(type(lead_cmd) == 'string' and lead_cmd:match("[_%a][_%w]*") ~= nil,
		"Invalid cmd lead: " .. tostring(lead_cmd))
	assert(not _reserved_cmd_providers[lead_cmd], "cmd lead is reserved: " .. lead_cmd)
	assert(#lead_cmd >= 2, "cmd lead too short: " .. lead_cmd)
	_cmd_providers[lead_cmd] = provider
end

---@return string[]
function M.lead_commands()
	return vim.fn.sort(vim.tbl_keys(_cmd_providers))
end

---@param lead_cmd string
---@return loop.UserCommandProvider
function M.get_cmd_provider(lead_cmd)
	return _cmd_providers[lead_cmd]
end

---@param wsinfo loop.ws.WorkspaceInfo
function M.on_workspace_load(wsinfo)
	local names = extensions.ext_names()
	for _, name in ipairs(names) do
		_load_state(wsinfo.config_dir, name)
		---@type loop.ExtensionData
		local ext_data = {
			ws_name = wsinfo.name,
			ws_dir = wsinfo.ws_dir,
			get_config_file_path = function(key, fileext)
				return _get_config_file_path(wsinfo.config_dir, name, key, fileext)
			end,
			state = _make_state_handler(name),
			register_user_command = _register_cmd_provider,
			register_task_type = _register_task_type_provider,
			register_task_templates = _register_task_template_provider,
		}
		_extension_data[name] = ext_data
		local ext = extensions.get_extension(name)
		if ext then
			assert(ext.on_workspace_load and ext.on_workspace_unload,
				"required function missing in extention: " .. name)
			ext.on_workspace_load(ext_data)
		end
	end
end

---@param wsinfo loop.ws.WorkspaceInfo
function M.on_workspace_unload(wsinfo)
	local names = extensions.ext_names()
	for _, name in ipairs(names) do
		local ext_data = _extension_data[name]
		assert(ext_data)
		local ext = extensions.get_extension(name)
		if ext then
			ext.on_workspace_unload(ext_data)
		end
	end
	_extension_data = {}
	_extension_states = {}
end

---@param wsinfo loop.ws.WorkspaceInfo
function M.save(wsinfo)
	local names = extensions.ext_names()
	for _, name in ipairs(names) do
		local ext_data = _extension_data[name]
		local state = _extension_states[name]
		assert(ext_data)
		assert(state)
		local ext = extensions.get_extension(name)
		if ext and ext.on_state_will_save then
			ext.on_state_will_save(ext_data)
		end
		local filepath = vim.fs.joinpath(wsinfo.config_dir, "state." .. name .. ".json")
		jsoncodec.save_to_file(filepath, state)
	end
end

return M
