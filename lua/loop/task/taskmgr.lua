local M = {}

local JsonEditor = require('loop.json.JsonEditor')
local uitools = require('loop.tools.uitools')
local strtools = require('loop.tools.strtools')
local jsoncodec = require('loop.json.codec')
local jsonvalidator = require('loop.json.validator')
local filetools = require('loop.tools.file')
local providers = require("loop.task.providers")
local selector = require("loop.tools.selector")
local logs = require("loop.logs")

---@return table
local function _build_taskfile_schema()
    local schema_data = require("loop.task.tasksschema")
    local base_schema = schema_data.base_schema
    local base_items = schema_data.base_items

    local schema = vim.deepcopy(base_schema)
    local oneOf = schema.properties.tasks.items.oneOf

    local task_types = providers.task_types()
    for _, task_type in ipairs(task_types) do
        local provider = providers.get_task_type_provider(task_type)
        if provider then
            assert(provider.get_task_schema, "get_task_schema() not implemented for: " .. task_type)
            local provider_schema = provider.get_task_schema()
            if provider_schema then
                local providers_props = provider_schema.properties or {}
                assert(type(providers_props) == "table")
                for name, _ in pairs(providers_props) do
                    assert(not base_items.properties[name], ("task provider '%' defines a reserved property: '%s'"))
                end
                local oneOfItem = {
                    type = "object",
                    properties = vim.tbl_extend("error", base_items.properties, providers_props),
                    required = vim.deepcopy(base_items.required),
                    ["x-order"] = base_items["x-order"] or {},
                }
                oneOfItem.__name = task_type
                if provider_schema["x-order"] then vim.list_extend(oneOfItem["x-order"], provider_schema["x-order"]) end
                oneOfItem.properties.type = { const = task_type, description = base_items.properties.type.description }
                oneOfItem.additionalProperties = false -- providers are not allowed to change this
                for _, req in ipairs(provider_schema.required or {}) do
                    table.insert(oneOfItem.required, req)
                end
                table.insert(oneOf, oneOfItem)
            end
        end
    end
    return schema
end

---@param task_type  string
---@return table|nil
local function _get_single_task_schema(task_type)
    local provider = providers.get_task_type_provider(task_type)
    if not provider then
        return nil
    end
    assert(provider.get_task_schema, "get_task_schema() not implemented for: " .. task_type)

    local base_items = require("loop.task.tasksschema").base_items

    local schema = vim.deepcopy(base_items)

    local provider_schema = provider.get_task_schema()
    if provider_schema then
        if provider_schema["x-order"] then vim.list_extend(schema["x-order"], provider_schema["x-order"]) end
        schema.properties = vim.tbl_extend("error", schema.properties, provider_schema.properties or {})
        --schema.additionalProperties = provider_schema.additionalProperties or false
        for _, req in ipairs(provider_schema.required or {}) do
            table.insert(schema.required, req)
        end
    end
    return schema
end


---@params task loop.Task
---@return string,string
local function _task_preview(task)
    local provider = providers.get_task_type_provider(task.type)
    if provider then
        local schema = _get_single_task_schema(task.type)
        return jsoncodec.to_string(task, schema), "json"
    end
    return "", ""
end

---@param content string
---@param tasktype_to_schema table<string,table>
---@return loop.Task[]|nil
---@return string[]|nil
local function _load_tasks_from_str(content, tasktype_to_schema)
    if content == "" then
        return {}, nil
    end
    local loaded, data_or_err = jsoncodec.from_string(content)
    if not loaded or type(data_or_err) ~= 'table' then
        return nil, { data_or_err }
    end

    local data = data_or_err
    do
        local schema = require("loop.task.tasksschema").base_schema
        local errors = jsonvalidator.validate(schema, data)
        if errors and #errors > 0 then
            local strs = jsonvalidator.errors_to_string_arr(errors)
            table.insert(strs, 1, "Failed to load tasks schema")
            return nil, strs
        end
        if not data or not data.tasks then
            return nil, { "Parsing error" }
        end
    end

    ---@type loop.Task[]
    local tasks = data.tasks
    for _, task in ipairs(tasks) do
        local schema = tasktype_to_schema[task.type]
        if not schema then
            return nil, { "No schema for task type: " .. task.type }
        end
        local errors = jsonvalidator.validate(schema, task)
        if errors and #errors > 0 then
            local strs = jsonvalidator.errors_to_string_arr(errors)
            table.insert(strs, 1, "Failed to load task: " .. task.name)
            return nil, strs
        end
    end

    return data.tasks, nil
end

---@param filepath string
---@param tasktype_to_schema table<string,table>
---@return loop.Task[]|nil
---@return string[]|nil
local function _load_tasks_file(filepath, tasktype_to_schema)
    local loaded, contents_or_err = uitools.smart_read_file(filepath)
    if not loaded then
        if not filetools.file_exists(filepath) then
            return {}, nil -- not an error
        end
        return nil, { contents_or_err }
    end
    return _load_tasks_from_str(contents_or_err, tasktype_to_schema)
end


---@param config_dir string
---@return loop.Task[]?,string[]?
local function _load_tasks(config_dir)
    local tasktype_to_schema = {}
    for _, tasktype in ipairs(providers.task_types()) do
        tasktype_to_schema[tasktype] = _get_single_task_schema(tasktype)
    end
    local filepath = vim.fs.joinpath(config_dir, "tasks.json")
    local tasks, errors = _load_tasks_file(filepath, tasktype_to_schema)
    if not tasks then
        return nil, strtools.indent_errors(errors, "error(s) in: " .. filepath)
    end

    local byname = {}
    for _, task in ipairs(tasks) do
        if byname[task.name] ~= nil then
            return nil, { "error in: " .. filepath, "  duplicate task name: " .. task.name }
        end
        byname[task.name] = task
    end

    return tasks, nil
end

---@param ws_dir string
function M.reset_provider_list(ws_dir)
    providers.reset_to_default(ws_dir)
end

---@param name string
---@param config_dir string
function M.save_last_task_name(name, config_dir)
    local filepath = vim.fs.joinpath(config_dir, "last.json")
    local data = { task = name }
    jsoncodec.save_to_file(filepath, data)
end

---@param config_dir string
function M.configure_tasks(config_dir)
    local tasks_file_schema = _build_taskfile_schema()
    local filepath = vim.fs.joinpath(config_dir, "tasks.json")

    if not filetools.file_exists(filepath) then
        local schema_filepath = vim.fs.joinpath(config_dir, 'tasksschema.json')
        if not filetools.file_exists(schema_filepath) then
            jsoncodec.save_to_file(schema_filepath, tasks_file_schema)
        end
        local data = {}
        data["$schema"] = './tasksschema.json'
        data["tasks"] = {}
        jsoncodec.save_to_file(filepath, data)
    end

    local editor = JsonEditor:new({
        name = "Tasks editor",
        filepath = filepath,
        schema = tasks_file_schema,
    })

    editor:set_new_array_item_handler(function(path, callback)
        if path:match("^/tasks$") then
            local category_choices = {}
            for _, elem in ipairs(providers.get_task_template_providers()) do
                ---@type loop.SelectorItem
                local item = {
                    label = elem.category,
                    data = elem.provider,
                }
                table.insert(category_choices, item)
            end
            selector.select({
                prompt = "Task category",
                items = category_choices,
                callback = function(provider)
                    if provider then
                        local templates = provider.get_task_templates()
                        local choices = {}
                        for _, template in pairs(templates) do
                            ---@type loop.SelectorItem
                            local item = {
                                label = template.name,
                                data = template.task,
                            }
                            table.insert(choices, item)
                        end
                        selector.select({
                            prompt = "Select template",
                            items = choices,
                            formatter = _task_preview,
                            callback = function(task)
                                if task then callback(task) end
                            end
                        })
                    end
                end
            })
        elseif path:match("^/tasks/[0-9]*/depends_on$") then
            local task_path = path:match("^(/tasks/[0-9]*/)")
            local cur_name_path = task_path .. "name"
            local cur_name = editor:value_at(cur_name_path)
            local tasks = _load_tasks(config_dir)
            if not tasks then
                vim.notify("Failed to load tasks")
                callback(nil)
            else
                local choices = {}
                for _, task in pairs(tasks) do
                    if cur_name ~= task.name then
                        ---@type loop.SelectorItem
                        local item = { label = task.name, data = task.name }
                        table.insert(choices, item)
                    end
                end
                if #choices == 0 then
                    callback(nil)
                else
                    selector.select({
                        prompt = "Select dependency",
                        items = choices,
                        callback = function(name)
                            if name then callback(name) end
                        end
                    })
                end
            end
        else
            callback(nil)
        end
    end)

    editor:open()
end

---@class loop.SelectTaskArgs
---@field tasks loop.Task[]
---@field prompt string

---@param args loop.SelectTaskArgs
---@param task_handler fun(task : loop.Task)
local function _select_task(args, task_handler)
    if #args.tasks == 0 then
        return
    end
    local choices = {}
    for _, task in ipairs(args.tasks) do
        ---@type loop.SelectorItem
        local item = {
            label = tostring(task.name),
            data = task,
        }
        table.insert(choices, item)
    end
    selector.select({
        prompt = args.prompt,
        items = choices,
        formatter = _task_preview,
        callback = function(task)
            if task then
                task_handler(task)
            end
        end
    })
end

---@param config_dir string
---@return string|nil
local function _load_last_task_name(config_dir)
    local filepath = vim.fs.joinpath(config_dir, "last.json")
    local ok, payload = jsoncodec.load_from_file(filepath)
    if not ok then
        return nil
    end
    return payload and payload.task or nil
end

---@param config_dir string
---@param mode "task"|"repeat"
---@param task_name string|nil
---@param handler fun(main_task:string|nil,all_tasks:loop.Task[]|nil)
function M.get_or_select_task(config_dir, mode, task_name, handler)
    if mode == "repeat" then
        task_name = _load_last_task_name(config_dir)
    end

    local tasks, task_errors = _load_tasks(config_dir)
    if (not tasks) or task_errors then
        vim.notify("Failed to load tasks")
        logs.log(task_errors or "Error while loading tasks", vim.log.levels.ERROR)
        handler(nil)
        return
    end

    if task_name and task_name ~= "" then
        local task = vim.iter(tasks):find(function(t) return t.name == task_name end)
        if not task then
            vim.notify("No task found with name: " .. task_name, vim.log.levels.ERROR)
            handler(nil)
            return
        end
        handler(task_name, tasks)
        return
    end

    ---@type loop.SelectTaskArgs
    local select_args = {
        tasks = tasks or {},
        prompt = "Select task"
    }
    _select_task(select_args, function(task)
        if not task then
            handler(nil)
            return
        end
        handler(task.name, tasks)
    end)
end

---@param task loop.Task
---@param page_group loop.PageGroup
---@param exit_handler loop.TaskExitHandler
---@return loop.TaskControl|nil, string|nil
function M.run_one_task(task, page_group, exit_handler)
    assert(task.type)
    local provider = providers.get_task_type_provider(task.type)
    if not provider then
        vim.notify("Invalid task type: " .. tostring(task.type))
        return nil, "Invalid task type"
    end
    return provider.start_one_task(task, page_group, exit_handler)
end

return M
