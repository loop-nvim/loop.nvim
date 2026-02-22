local coreproviders = require("loop.coretasks.coreproviders")

---@type string[]  -- keeps registration order
local _task_types = {}

---@type table<string,loop.TaskTypeProvider>
local _task_type_providers = {}

---@type {category:string,provider:loop.TaskTemplateProvider}[]
local _template_providers = {}

local M = {}

---@param ws_dir string
function M.reset_to_default(ws_dir)
    _task_type_providers = {
        process   = coreproviders.get_process_task_provider(ws_dir),
        composite = coreproviders.get_composite_task_provider(),
    }
    _task_types = { "process", "composite" }
    _template_providers = {
        { category = "Process", provider = coreproviders.get_process_templates_provider() },
        { category = "Composite",     provider = coreproviders.get_composite_templates_provider() },
    }
end

---@return string[]
function M.task_types()
    return _task_types
end

---@param task_type string
---@param provider loop.TaskTypeProvider
function M.register_task_provider(task_type, provider)
    assert(type(task_type) == 'string' and task_type:match("[_%a][_%w]*") ~= nil,
        "Invalid task type: " .. tostring(task_type))
    assert(not _task_type_providers[task_type], "task type is already registered: " .. task_type)
    assert(#task_type >= 2, "ext task type too short: " .. task_type)
    _task_type_providers[task_type] = provider
    table.insert(_task_types, task_type)
end

---@param category string
---@param provider loop.TaskTemplateProvider
function M.register_template_provider(category, provider)
    table.insert(_template_providers, { category = category, provider = provider })
end

---@param name string
---@return loop.TaskTypeProvider|nil
function M.get_task_type_provider(name)
    return _task_type_providers[name]
end

---@return {category:string,provider:loop.TaskTemplateProvider}[]
function M.get_task_template_providers()
    return _template_providers
end

return M
