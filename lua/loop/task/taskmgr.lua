local M = {}

local JsonEditor = require('loop.json.JsonEditor')
local uitools = require('loop.utils.uitools')
local strtools = require('loop.utils.strtools')
local jsoncodec = require('loop.json.codec')
local jsonvalidator = require('loop.json.validator')
local filetools = require('loop.utils.file')
local providers = require("loop.task.providers")
local selector = require("loop.utils.selector")
local log = require("loop.log")

---@return table
local function _build_taskfile_schema()
    local schema_data = require("loop.task.tasksschema")

    -- 1. Deep copy the base structures to avoid polluting the cache
    local base_items = vim.deepcopy(schema_data.base_items)
    local schema = vim.deepcopy(schema_data.base_schema)

    -- Shortcut to the task list items
    local tasks_items = schema.properties.tasks.items
    tasks_items.allOf = tasks_items.allOf or {}

    -- Ensure the base type enum exists
    tasks_items.properties.type.enum = tasks_items.properties.type.enum or {}

    local task_types = providers.task_types()

    for _, task_type in ipairs(task_types) do
        local provider = providers.get_task_type_provider(task_type)

        if provider then
            assert(provider.get_task_schema, "get_task_schema() not implemented for: " .. task_type)

            local raw_provider_schema = provider.get_task_schema()
            if raw_provider_schema then
                -- 2. Defensive copy immediately
                local then_schema = vim.deepcopy(raw_provider_schema)
                local provider_props = then_schema.properties or {}

                -- 3. Validate no reserved property collisions
                for name, _ in pairs(provider_props) do
                    if base_items.properties[name] then
                        error(string.format("task provider '%s' defines reserved property: '%s'", task_type, name))
                    end
                end

                -- 4. Setup 'then' schema metadata
                then_schema.description = ("Definition of a `%s` task"):format(task_type)
                then_schema.additionalProperties = false

                -- 5. Merge Properties: Base items take precedence for core fields
                then_schema.properties = vim.tbl_extend("force", then_schema.properties or {}, base_items.properties)

                -- Fix the 'type' to the specific constant for this branch
                then_schema.properties.type = vim.tbl_extend("force", {}, base_items.properties.type, {
                    const = task_type,
                })

                -- 6. Safe Required Merge
                local combined_required = vim.deepcopy(base_items.required or {})
                for _, req in ipairs(then_schema.required or {}) do
                    if not vim.tbl_contains(combined_required, req) then
                        table.insert(combined_required, req)
                    end
                end
                then_schema.required = combined_required

                -- 7. Compose x-order
                local x_order = {}
                vim.list_extend(x_order, base_items["x-order"] or {})
                vim.list_extend(x_order, raw_provider_schema["x-order"] or {})
                then_schema["x-order"] = x_order

                -- 8. Inherit value selector from the task item level
                then_schema["x-valueSelector"] = tasks_items["x-valueSelector"]

                -- 9. Register task type in the main enum
                if not vim.tbl_contains(tasks_items.properties.type.enum, task_type) then
                    table.insert(tasks_items.properties.type.enum, task_type)
                end

                -- 10. Add the conditional branch
                table.insert(tasks_items.allOf, {
                    ["if"] = {
                        type = "object",
                        properties = { type = { const = task_type } }
                    },
                    ["then"] = then_schema
                })
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
---@return loop.Task[]|nil
---@return string[]|nil
local function _load_tasks_from_str(content)
    if content == "" then
        return {}, nil
    end
    local loaded, data_or_err = jsoncodec.from_string(content)
    if not loaded or type(data_or_err) ~= 'table' then
        return nil, { data_or_err }
    end

    local data = data_or_err
    do
        local schema = _build_taskfile_schema()
        local valid, errors = jsonvalidator.validate(schema, data)
        if not valid then
            local strs = jsonvalidator.errors_to_string_arr(errors)
            table.insert(strs, 1, "Failed to load tasks")
            return nil, strs
        end
        if not data or not data.tasks then
            return nil, { "Parsing error" }
        end
    end
    local byname = {}
    for _, task in ipairs(data.tasks) do
        if byname[task.name] ~= nil then
            return nil, { "Duplicate task name: " .. task.name }
        end
        byname[task.name] = task
    end
    return data.tasks, nil
end

---@param filepath string
---@return loop.Task[]|nil
---@return string[]|nil
local function _load_tasks_file(filepath)
    local loaded, contents_or_err = filetools.read_content(filepath)
    if not loaded then
        if not filetools.file_exists(filepath) then
            return {}, nil -- not an error
        end
        return nil, { contents_or_err }
    end
    return _load_tasks_from_str(contents_or_err)
end


---@param config_dir string
---@return loop.Task[]?,string[]?
local function _load_tasks(config_dir)
    local filepath = vim.fs.joinpath(config_dir, "tasks.json")
    local tasks, errors = _load_tasks_file(filepath)
    if not tasks then
        return nil, strtools.indent_errors(errors, "error(s) in: " .. filepath)
    end
    return tasks, nil
end

function M.clear_providers()
    providers.clear_all()
end

---@param ws_dir string
function M.reset_providers(ws_dir)
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
    local existing_editor = JsonEditor.get_existing(filepath)
    if existing_editor then
        existing_editor:open()
        return
    end
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
        name = "Task List Editor",
        filepath = filepath,
        schema = tasks_file_schema,
    })

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
        },
        function(task)
            if task then
                task_handler(task)
            end
        end
    )
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

---@params handler fun(task:loop.Task?)
function M.select_task_template(handler)
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
        },
        function(provider)
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
                    },
                    function(task)
                        if task then handler(task) end
                    end
                )
            end
        end
    )
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
        log.log(task_errors or "Error while loading tasks", vim.log.levels.ERROR)
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
