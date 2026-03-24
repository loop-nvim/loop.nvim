local M = {}

local extensions = require('loop.extensions')
local taskproviders = require('loop.task.providers')
local filetools = require('loop.utils.file')
local jsoncodec = require('loop.json.codec')
local views = require('loop.ui.views')
local sidebar = require('loop.ui.sidebar')

---@class loop.ExtentionContext
---@field expired boolean
---@field ext_name string
---@field page_groups table<string,loop.PageGroup>
---@field state table
---@field cmd_providers table<string,loop.UserCommandProvider>
---@
---@type table<string,loop.ExtentionContext>
local _extension_contexts = {}

---@type table<string,loop.ExtensionAPI>
local _extension_api = {}

local _reserved_cmd_providers = {
	workspace = true,
	statuspanel = true,
	sidebar = true,
	page = true,
	logs = true,
	help = true,
	task = true,
	var = true
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

local function _make_unique_id(ext_name, name, category)
	if name:match("^[a-zA-Z0-9%-_]+$") == nil then
		error(string.format("Invalid %s name: '%s'. IDs must only contain alphanumeric characters, '-', or '_'.",
			category, name))
	end
	return ("%s:%s"):format(ext_name, name)
end

---@param ext_name string
---@param preset loop.SidebarPreset
---@return loop.ui.SidebarPresetView[]
local function _convert_views(ext_name, preset)
	local preset_views = {}
	for _, v in ipairs(preset.views) do
		---@type loop.ui.SidebarPresetView
		local item = { id = _make_unique_id(ext_name, v.name), name = v.name, ratio = v.ratio }
		table.insert(preset_views, item)
	end
	return preset_views
end

---@param state table
---@return loop.ExtensionStorage
local function _make_storage_handler(state)
	---@type loop.ExtensionStorage
	local handler = {
		set = function(fieldname, fieldvalue) state[fieldname] = fieldvalue end,
		get = function(fieldname) return state[fieldname] end,
		keys = function() return vim.tbl_keys(state) end
	}
	return handler
end

---@param config_dir string
---@param ext_name string
---@return table
local function _load_state(config_dir, ext_name)
	assert(ext_name and ext_name:match("[_%a][_%w]*") ~= nil, "invalid input")
	local data = {}
	local filepath = vim.fs.joinpath(config_dir, "state." .. ext_name .. ".json")
	if filetools.file_exists(filepath) then
		local decoded, data_or_err = jsoncodec.load_from_file(filepath)
		assert(decoded, "failed to load state file for " .. ext_name)
		return data_or_err or {}
	else
		return {}
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

---@param start_args loop.utils.TermProc.StartArgs
---@param ext_context loop.ExtentionContext
---@param page_manager loop.PageManager
---@return  loop.utils.TermProc?,string?
local function _run_process_for_ext(start_args, ext_context, page_manager)
	local name = start_args.name or ext_context.ext_name
	local group = ext_context.page_groups[name] ---@type loop.PageGroup?
	if group and group.is_expired() then
		group.delete_group()
		ext_context.page_groups[name] = nil
		group = nil
	end
	if group then
		return nil, "task already running"
	end
	group = page_manager.add_page_group(name)
	if not group then
		return nil, "Failed to create term page"
	end
	ext_context.page_groups[name] = group
	local start_args_cpy = vim.fn.copy(start_args)
	start_args_cpy.on_exit_handler = function(code)
		group.expire()
		if start_args then
			start_args.on_exit_handler(code)
		end
	end
	local page_data, err_str = group.add_page({
		label = name,
		type = "term",
		term_args = start_args_cpy,
		activate = true,
	})
	if not page_data or not page_data.term_proc then
		group.expire()
		return nil, err_str
	end
	return page_data.term_proc, nil
end

---@param ext_context loop.ExtentionContext
---@param lead_cmd string
---@param provider loop.UserCommandProvider
local function _register_cmd_provider(ext_context, lead_cmd, provider)
	assert(type(lead_cmd) == 'string' and lead_cmd:match("[_%a][_%w]*") ~= nil,
		"Invalid cmd lead: " .. tostring(lead_cmd))
	assert(not _reserved_cmd_providers[lead_cmd], "cmd lead is reserved: " .. lead_cmd)
	assert(#lead_cmd >= 2, "cmd lead too short: " .. lead_cmd)
	ext_context.cmd_providers[lead_cmd] = provider
end

---@return string[]
function M.lead_commands()
	local leads = {}
	for _, ext in pairs(_extension_contexts) do
		for lead, _ in pairs(ext.cmd_providers) do
			leads[lead] = true
		end
	end
	local ret = vim.tbl_keys(leads)
	table.sort(ret)
	return ret
end

---@param lead_cmd string
---@return loop.UserCommandProvider?
function M.get_cmd_provider(lead_cmd)
	for _, ext in pairs(_extension_contexts) do
		local provider = ext.cmd_providers[lead_cmd]
		if provider then
			return provider
		end
	end
end

---@param wsinfo loop.ws.WorkspaceInfo
---@param page_manager loop.PageManager
function M.on_workspace_load(wsinfo, page_manager)
	assert(next(_extension_contexts) == nil)
	local names = extensions.ext_names()
	for _, ext_name in ipairs(names) do
		---@type loop.ExtentionContext
		local ext_context = {
			expired = false,
			ext_name = ext_name,
			state = _load_state(wsinfo.config_dir, ext_name),
			page_groups = {},
			cmd_providers = {}
		}
		local function assert_ws()
			assert(not ext_context.expired, "using extension API but workspace is closed")
		end
		_extension_contexts[ext_name] = ext_context
		local storage_handler = _make_storage_handler(ext_context.state)
		---@type loop.ExtensionAPI
		local ext_api = {
			ws_dir = wsinfo.ws_dir,
			get_config_file_path = function(key, fileext)
				assert_ws()
				return _get_config_file_path(wsinfo.config_dir, ext_name, key, fileext)
			end,
			get_storage = function()
				assert_ws()
				return storage_handler
			end,
			register_user_command = function(lead_cmd, provider)
				assert_ws()
				return _register_cmd_provider(ext_context, lead_cmd, provider)
			end,
			register_view = function(view_name, provider)
				assert_ws()
				local id = _make_unique_id(ext_name, view_name, "view")
				return views.register_view(id, view_name, provider)
			end,
			register_sidebar_preset = function(name, preset)
				assert_ws()
				local id = _make_unique_id(ext_name, name, "preset")
				local preset_views = _convert_views(ext_name, preset)
				sidebar.register_preset(id, name, preset_views)
			end,
			show_sidebar_preset = function(name)
				assert_ws()
				local id = _make_unique_id(ext_name, name, "preset")
				return sidebar.show_by_id(id)
			end,
			register_task_type = function(type, provider)
				assert_ws()
				return _register_task_type_provider(type, provider)
			end,
			register_task_templates = function(category, provider)
				assert_ws()
				return _register_task_template_provider(category, provider)
			end,
			run_process = function(start_args)
				assert_ws()
				return _run_process_for_ext(start_args, ext_context, page_manager)
			end
		}
		_extension_api[ext_name] = ext_api
		local ext = extensions.get_extension(ext_name)
		if ext then
			assert(ext.on_workspace_load and ext.on_workspace_unload,
				"required function missing in extention: " .. ext_name)
			ext.on_workspace_load(ext_api)
		end
	end
end

function M.on_workspace_unload()
	local names = extensions.ext_names()
	for _, name in ipairs(names) do
		local ext_api = _extension_api[name]
		assert(ext_api)
		local ext = extensions.get_extension(name)
		if ext then
			ext.on_workspace_unload(ext_api)
		end
	end
	for _, ext in pairs(_extension_contexts) do
		ext.expired = true
	end
	_extension_api = {}
	_extension_contexts = {}
end

---@param config_dir string
function M.on_save(config_dir)
	local names = extensions.ext_names()
	for _, name in ipairs(names) do
		local ext_api = _extension_api[name]
		local state = _extension_contexts[name].state
		assert(ext_api)
		assert(state)
		local ext = extensions.get_extension(name)
		if ext and ext.on_state_will_save then
			ext.on_state_will_save(ext_api)
		end
		local filepath = vim.fs.joinpath(config_dir, "state." .. name .. ".json")
		jsoncodec.save_to_file(filepath, state)
	end
end

function M.clean_page_groups()
	for _, ext_context in pairs(_extension_contexts) do
		local group_names = vim.tbl_keys(ext_context.page_groups)
		for _, name in ipairs(group_names) do
			local group = ext_context.page_groups[name]
			if group.is_deleted() then
				ext_context.page_groups[name] = nil
			end
		end
	end
end

return M
