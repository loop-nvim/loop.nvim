local class = require("loop.tools.class")
local Scheduler = require("loop.tools.Scheduler")

---@alias loop.TaskScheduler.StartTaskFn fun(task: loop.Task, on_exit: fun(ok:boolean, reason:string|nil)): { terminate:fun() }|nil, string|nil
---@alias loop.TaskScheduler.TaskEventFn fun(taskname: string, event: loop.scheduler.NodeEvent, success:boolean,reason?:string)

---@class loop.TaskTreeNode
---@field name string                       -- Task name
---@field order "sequence"|"parallel"       -- Dependency execution order
---@field deps loop.TaskTreeNode[]           -- Child dependency nodes

local M = {}

---@class loop.TaskScheduler.TaskData
---@field task_id number
---@field task_name string
---@field control loop.TaskControl?
---@field task loop.Task
---@field waiters function[]
---@field sub_control loop.TaskControl?
---@field termination_reason string?
---@field is_terminated boolean?
---@field is_finalized boolean?
---@field exit_callback fun(ok:boolean, reason:string|nil)

---@type number
local _last_plan_id = 0

---@type number
local _last_task_id = 0

---@type table<number, loop.tools.Scheduler>
local _plan_schedulers = {}

---@type table<string, table<number, loop.TaskScheduler.TaskData>>
local _running_tasks = {}

---@param trigger  loop.scheduler.exit_trigger
---@param param string?
local function _get_failure_message(trigger, param)
    if trigger == "cycle" then
        return "Task dependency loop detected in task: " .. tostring(param)
    elseif trigger == "invalid_node" then
        return "Invalid task name: " .. tostring(param)
    elseif trigger == "interrupt" then
        return "Task interrupted"
    elseif trigger == "deps_failed" then
        return "Dependency task failed"
    else
        return param or "Task failed"
    end
end

---@param tasks loop.Task[]
---@param root string
---@return table<string, loop.Task>? name_to_task
---@return loop.scheduler.Node[]? nodes
---@return string? error_msg
local function _validate_and_build_nodes(tasks, root)
    local name_to_task = {}
    local nodes = {}

    for _, task in ipairs(tasks) do
        if name_to_task[task.name] then
            return nil, nil, "Duplicate task name: " .. task.name
        end
        name_to_task[task.name] = task
        table.insert(nodes, {
            id = task.name,
            deps = task.depends_on or {},
            order = task.depends_order or "sequence",
        })
    end

    if not name_to_task[root] then
        return nil, nil, "Root task '" .. root .. "' not found among provided tasks"
    end

    return name_to_task, nodes, nil
end

---@param task_data loop.TaskScheduler.TaskData
local function _finalize_and_wake(task_data, ok)
    if task_data.is_finalized then return end
    task_data.is_finalized = true

    local waiters = task_data.waiters
    task_data.waiters = {}

    -- Remove from running tasks if still present
    local task_runs = _running_tasks[task_data.task_name]
    if task_runs then
        task_runs[task_data.task_id] = nil
        if next(task_runs) == nil then
            _running_tasks[task_data.task_name] = nil
        end
    end

    local reason = task_data.termination_reason

    vim.schedule(function()
        -- print("exit cb for: " .. tostring(task_data.task.name .. ", #waiters: " .. tostring(#waiters)) .. ", id " .. task_data.task_id)
        task_data.exit_callback(ok, reason)
        for _, waiter in ipairs(waiters) do
            waiter()
        end
    end)
end

---@param data loop.TaskScheduler.TaskData
---@param reason string?
local function _terminate_task(data, reason)
    -- print("terminate_task: " .. tostring(data.task.name) .. ", id " .. data.task_id)
    if not data.is_terminated then
        data.is_terminated = true
        data.termination_reason = reason
        if data.sub_control then
            -- print("sub_control terminate: " .. tostring(data.task.name) .. ", id " .. data.task_id)
            data.sub_control.terminate()
        else
            -- print("direct finalize: " .. tostring(data.task.name) .. ", id " .. data.task_id)
            _finalize_and_wake(data, false)
        end
    end
end

---@param task loop.Task
---@param start_task loop.TaskScheduler.StartTaskFn
---@param on_exit fun(ok:boolean, reason:string|nil)
---@return loop.TaskControl?, string?
local function _start_plan_task(task, start_task, on_exit)
    if task.if_running == "refuse" then
        local instances = _running_tasks[task.name]
        if instances and not vim.tbl_isempty(instances) then
            return nil, "Task refused (already running)"
        end
    end

    local task_name = task.name
    _last_task_id = _last_task_id + 1
    local task_id = _last_task_id

    ---@type loop.TaskScheduler.TaskData
    local task_data = {
        task_id = task_id,
        task_name = task_name,
        task = task,
        control = nil,
        sub_control = nil,
        waiters = {},
        is_terminated = false,
        is_finalized = false,
        exit_callback = on_exit,
    }

    -- Register the control early so it can be waited on by others
    _running_tasks[task_name] = _running_tasks[task_name] or {}
    if _running_tasks[task_name][task_id] then return nil, "Internal error (task id already used)" end
    _running_tasks[task_name][task_id] = task_data

    ---@type loop.TaskControl
    local control = {
        terminate = function()
            _terminate_task(task_data, "Interrupted")
        end
    }
    task_data.control = control

    local start_and_attach_control = function()
        if not task_data.is_terminated then
            local sub_err
            -- print("effective task start: " .. task_name .. ", id " .. task_id)
            -- run the task now
            task_data.sub_control, sub_err = start_task(task, function(ok, reason)
                task_data.termination_reason = task_data.termination_reason or reason
                _finalize_and_wake(task_data, ok)
            end)
            if not task_data.sub_control then
                _terminate_task(task_data, sub_err)
            end
        end
    end

    ---@type loop.TaskScheduler.TaskData[]
    local blockers = {}

    -- same task concurrency
    if task.if_running ~= "parallel" then
        local instances = _running_tasks[task_name]
        if instances then
            for id, data in pairs(instances) do
                if task_id ~= id and not data.is_finalized then
                    table.insert(blockers, data)
                end
            end
        end
    end

    -- dependants that require stopping
    for _, instances in pairs(_running_tasks) do
        for id, data in pairs(instances) do
            if task_id ~= id
                and not data.is_finalized
                and data.task.stop_on_dependency_change
                and data.task.depends_on
                and vim.tbl_contains(data.task.depends_on, task_name) then
                table.insert(blockers, data)
            end
        end
    end

    if #blockers > 0 then
        -- print("new task: " .. task_name .. ", #blockers " .. tostring(#blockers) .. ", id " .. task_id)
        local nb_running = #blockers
        local on_task_ended = function()
            nb_running = nb_running - 1
            -- print("on_task_ended in the context of " .. task_name .. ", remaining " .. tostring(nb_running) .. ", id " .. task_id)
            if nb_running == 0 then
                start_and_attach_control()
            end
        end
        for _, data in ipairs(blockers) do
            table.insert(data.waiters, on_task_ended)
            local reason
            if task_name == data.task.name then
                reason = "Interrupted by restart"
            else
                reason = ("Interrupted by task: '%s'"):format(task_name)
            end
            _terminate_task(data, reason)
        end
    else
        -- print("start direct: " .. task_name .. ", id " .. task_id)
        start_and_attach_control()
    end

    return control
end

---@param tasks loop.Task[]
---@param root string
---@param start_task loop.TaskScheduler.StartTaskFn
---@param on_task_event loop.TaskScheduler.TaskEventFn
---@param on_exit? fun(success:boolean, reason?:string)
function M.run_plan(tasks, root, start_task, on_task_event, on_exit)
    local call_on_exit = function(success, reason)
        if on_exit then on_exit(success, reason) end
    end

    local name_to_task, nodes, validation_err = _validate_and_build_nodes(tasks, root)
    if validation_err or not name_to_task or not nodes then
        vim.schedule_wrap(call_on_exit)(false, validation_err)
        return
    end

    _last_plan_id = _last_plan_id + 1
    local plan_id = _last_plan_id

    ---@type loop.scheduler.StartNodeFn
    local start_node = function(id, on_node_exit)
        local task = name_to_task[id] --[[@as loop.Task]]
        assert(task)
        return _start_plan_task(task, start_task, on_node_exit)
    end

    local scheduler = Scheduler:new()
    _plan_schedulers[plan_id] = scheduler

    ---@type loop.scheduler.NodeEventFn
    local function on_node_event(id, event, success, reason, param)
        local msg = success and "" or _get_failure_message(reason, param)
        on_task_event(id, event, success, msg)
    end

    ---@type loop.scheduler.exit_fn
    local on_schedule_end = function(success, trigger, param)
        -- print("schedule end")
        local msg = success and "" or _get_failure_message(trigger, param)
        vim.schedule(function()
            _plan_schedulers[plan_id] = nil
            call_on_exit(success, msg)
        end)
    end

    scheduler:start(nodes, root, start_node, on_node_event, on_schedule_end)
end

function M.terminate()
    -- the schedules will terminate running tasks
    for _, ps in pairs(_plan_schedulers) do
        ps:terminate()
    end
end

---@return boolean
function M.is_running()
    for _, ps in pairs(_plan_schedulers) do
        if ps:is_running() then return true end
    end
    return false
end

return M
