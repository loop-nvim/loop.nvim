local class = require("loop.tools.class")
local Scheduler = require("loop.tools.Scheduler")

---@alias loop.TaskScheduler.StartTaskFn fun(task: loop.Task, on_exit: fun(ok:boolean, reason:string|nil)): { terminate:fun() }|nil, string|nil
---@alias loop.TaskScheduler.TaskEventFn fun(taskname: string, event: loop.scheduler.NodeEvent, success:boolean,reason?:string)

---@class loop.TaskTreeNode
---@field name string                       -- Task name
---@field order "sequence"|"parallel"       -- Dependency execution order
---@field deps loop.TaskTreeNode[]           -- Child dependency nodes

local M = {}

---@alias loop.TaskScheduler.PlanTask { control: loop.TaskControl, task: loop.Task, waiters:function[] }
---@alias loop.TaskScheduler.PlanTasks table<string, loop.TaskScheduler.PlanTask>

---@class loop.TaskScheduler.PlanData
---@field base_scheduler loop.tools.Scheduler
---@field running_tasks loop.TaskScheduler.PlanTasks

---@type table<number, loop.TaskScheduler.PlanData>
local _plans = {}

---@type number
local _last_plan_id = 0

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
    elseif trigger == "node" then
        return param or "Task failed"
    else
        return "Task failed (" .. tostring(param) .. ")"
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

---@param plan_id number
---@param task loop.Task
---@param start_task loop.TaskScheduler.StartTaskFn
---@param on_exit fun(ok:boolean, reason:string|nil)):
---@return loop.TaskControl?, string?
local function _start_plan_task(plan_id, task, start_task, on_exit)
    local plan_data = _plans[plan_id]
    assert(plan_data)

    if task.concurrency == "refuse" then
        for _, plan in pairs(_plans) do
            if plan.running_tasks[task.name] then
                return nil, "Task refused (already running)"
            end
        end
    end

    local finalized = false
    local function finalize_and_wake(ok, reason)
        if finalized then return end
        finalized = true
        local plan_task = plan_data.running_tasks[task.name]
        if plan_task then
            plan_data.running_tasks[task.name] = nil
            -- We schedule this to remain thread-safe/async-safe for the UI
            vim.schedule(function()
                on_exit(ok, reason)
                for _, waiter in ipairs(plan_task.waiters) do
                    waiter()
                end
            end)
        end
    end

    local control_ctx = {
        sub_control = nil,
        is_terminated = false,
        terminate_reason = nil,
    }
    ---@type loop.TaskControl
    local control = {
        terminate = function()
            if not control_ctx.is_terminated then
                control_ctx.is_terminated = true
                if control_ctx.sub_control then
                    control_ctx.sub_control.terminate()
                else
                    finalize_and_wake(false, control_ctx.terminate_reason or "Interrupted")
                end
            end
        end
    }

    local start_and_attach_control = function()
        local sub_err
        if not control_ctx.is_terminated then
            -- run the task now
            control_ctx.sub_control, sub_err = start_task(task, finalize_and_wake)
        end
        if not control_ctx.sub_control then
            control_ctx.terminate_reason = sub_err
            control.terminate()
        end
    end

    -- Register the control early so it can be waited on by others
    plan_data.running_tasks[task.name] = { control = control, task = task, waiters = {} }

    ---@type loop.TaskScheduler.PlanTask[]
    local tasks_to_wait = {}

    -- same task concurrency
    if task.concurrency ~= "parallel" then
        for _, plan in pairs(_plans) do
            ---@type loop.TaskScheduler.PlanTask
            local pt = plan.running_tasks[task.name]
            -- Don't terminate our own placeholder
            if pt and pt.control ~= control then
                table.insert(tasks_to_wait, pt)
            end
        end
    end

    -- dependants that require stopping
    for _, plan in pairs(_plans) do
        for _, pt in pairs(plan.running_tasks) do
            if pt.task.stop_on_dependency_change
                and pt.control ~= control
                and pt.task.name ~= task.name
                and vim.tbl_contains(pt.task.depends_on, task.name) then
                table.insert(tasks_to_wait, pt)
            end
        end
    end

    if #tasks_to_wait > 0 then
        local nb_running = #tasks_to_wait
        local on_task_ended = function()
            nb_running = nb_running - 1
            if nb_running == 0 then
                start_and_attach_control()
            end
        end
        for _, pt in ipairs(tasks_to_wait) do
            table.insert(pt.waiters, on_task_ended)
            if task.concurrency ~= "wait" then
                pt.control.terminate()
            end
        end
    else
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
        return _start_plan_task(plan_id, task, start_task, on_node_exit)
    end

    local scheduler = Scheduler:new()
    _plans[plan_id] = {
        base_scheduler = scheduler,
        running_tasks = {},
    }

    ---@type loop.scheduler.NodeEventFn
    local function on_node_event(id, event, success, reason, param)
        local msg = success and "" or _get_failure_message(reason, param)
        on_task_event(id, event, success, msg)
    end

    ---@type loop.scheduler.exit_fn
    local on_schedule_end = function(success, trigger, param)
        local msg = success and "" or _get_failure_message(trigger, param)
        vim.schedule(function()
            _plans[plan_id] = nil
            call_on_exit(success, msg)
        end)
    end

    scheduler:start(nodes, root, start_node, on_node_event, on_schedule_end)
end

function M.terminate()
    for _, p in pairs(_plans) do
        p.base_scheduler:terminate()
    end
end

---@return boolean
function M.is_running()
    for _, p in pairs(_plans) do
        if p.base_scheduler:is_running() then return true end
    end
    return false
end

return M
