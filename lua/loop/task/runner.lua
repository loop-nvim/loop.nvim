local M                   = {}

local taskmgr             = require("loop.task.taskmgr")
local resolver            = require("loop.tools.resolver")
local logs                = require("loop.log")
local task_scheduler      = require("loop.task.taskscheduler")
local variablesmgr        = require("loop.task.variablesmgr")
local strtools            = require("loop.tools.strtools")
local planner             = require("loop.task.planner")

---@type loop.ws.WorkspaceInfo?
local _workspace_info

---@type loop.PageManager?
local _page_manager

---@alias loop.ws.ActiveTaskData {name:string,root:string,ctrl:loop.TaskControl}

---@type number
local _last_task_key      = 0
---@type {number:loop.ws.ActiveTaskData}
local _active_tasks       = {}

---@type table<string, loop.PageGroup[]>
-- task_name -> list of run entries
local _expired_pagegroups = {}

local _last_run_id        = 0

---@class LoopRunState
---@field waiting integer
---@field running integer

---@type table<number, LoopRunState>
-- run_id -> counters
local _run_state          = {}

---@type fun(nb_waiting:number,nb_running:number)?
local _status_handler     = nil

local function _report_state()
    if not _status_handler then return end
    local nb_waiting, nb_running = 0, 0
    for _, state in pairs(_run_state) do
        nb_waiting = nb_waiting + state.waiting
        nb_running = nb_running + state.running
    end
    _status_handler(nb_waiting, nb_running)
end

---@param run_id number
local function _on_run_end(run_id)
    _run_state[run_id] = nil
    _report_state()
end

---@param task_name string
---@param page_group loop.PageGroup
local function _expire_page_group(task_name, page_group)
    page_group.expire()
    _expired_pagegroups[task_name] = _expired_pagegroups[task_name] or {}
    table.insert(_expired_pagegroups[task_name], page_group)
end

---@param task_name  string
local function _delete_expired_groups(task_name)
    local expired_groups = _expired_pagegroups[task_name]
    if expired_groups then
        for _, group in ipairs(expired_groups) do
            group.delete_group()
        end
        _expired_pagegroups[task_name] = {}
    end
end

---@param task loop.Task
---@param page_group loop.PageGroup
---@param depedant_root string
---@param on_exit loop.TaskExitHandler
---@return loop.TaskControl|nil, string|nil
local function _start_task(task, page_group, depedant_root, on_exit)
    logs.user_log("Starting task:\n" .. vim.inspect(task), "task")

    local exited = false
    local task_key = _last_task_key + 1
    _last_task_key = task_key

    ---@type loop.TaskExitHandler
    local exit_handler = function(success, reason)
        exited = true
        _active_tasks[task_key] = nil
        if not success and reason then
            if not page_group.is_expired() and not page_group.have_pages() then
                local page = page_group.add_page({
                    label = "Error",
                    type = "output",
                    activate = true,
                })
                if page then
                    page.output_buf.add_lines(reason)
                end
            end
        end
        _expire_page_group(task.name, page_group)
        on_exit(success, reason)
    end

    _delete_expired_groups(task.name)

    local taskctrl, err_msg = taskmgr.run_one_task(task, page_group, exit_handler)
    if err_msg and not page_group.have_pages() then
        -- add the error before expiring the page group
        local page = page_group.add_page({
            label = "Error",
            type = "output",
            activate = true
        })
        if page then
            page.output_buf.add_lines(err_msg or "Task failed")
        end
    end
    if not taskctrl or exited then
        _expire_page_group(task.name, page_group)
    end

    if not exited then
        _active_tasks[task_key] = {
            name = task.name,
            root = depedant_root,
            ctrl = taskctrl
        }
    end

    return taskctrl, err_msg
end

---@param config_dir string
---@return table<string, string>|nil variables, string[]|nil errors
local function _load_variables(config_dir)
    -- Load variables after loading tasks (errors are logged but don't block task loading)
    local vars, var_errors = variablesmgr.load_variables(config_dir)
    if var_errors then
        vim.notify("error(s) loading variables.json")
        logs.log(strtools.indent_errors(var_errors, "Error(s) loading variables.json"),
            vim.log.levels.WARN)
    end
    return vars, var_errors
end

---@param ws_info loop.ws.WorkspaceInfo
---@param page_manager loop.PageManager
function M.on_workspace_open(ws_info, page_manager)
    _workspace_info = ws_info
    _page_manager = page_manager
end

function M.on_workspace_close()
    _page_manager = nil
    _workspace_info = nil
end

---@param handler fun(nb_waiting:number,nb_running:number)
function M.set_status_handler(handler)
    _status_handler = handler
end

---@param all_tasks loop.Task[]
---@param root_name string
function M.run_task_with_deps(all_tasks, root_name)
    assert(_workspace_info)

    local ws_dir = _workspace_info.ws_dir
    local config_dir = _workspace_info.config_dir

    -- Log task start
    logs.user_log("Task started: " .. root_name, "task")

    if #all_tasks == 0 then
        vim.notify("No tasks found")
        logs.user_log("No tasks found")
        return
    end

    local node_tree, used_tasks, plan_error_msg = planner.generate_task_plan(all_tasks, root_name)
    if not node_tree or not used_tasks then
        logs.user_log(plan_error_msg or "Failed to build task plan", "task")
        vim.notify("Failed to start task, use ':Loop log' for details")
        return
    end

    for _, task in ipairs(used_tasks) do
        _delete_expired_groups(task.name)
    end

    ---@type loop.PageGroup?
    local root_page_group
    ---@param err_msg string
    local function on_run_failed(err_msg)
        if not root_page_group or (not root_page_group.is_expired() and not root_page_group.have_pages()) then
            root_page_group = _page_manager and _page_manager.add_page_group(root_name)
            if root_page_group then
                local page = root_page_group.add_page({
                    label = "Error",
                    type = "output",
                    activate = true,
                })
                if page then
                    page.output_buf.add_lines(err_msg or "Task failed")
                end
                _expire_page_group(root_name, root_page_group)
            end
        end
    end

    logs.user_log("Scheduling tasks:\n" .. planner.print_task_tree(node_tree))

    _last_run_id = _last_run_id + 1
    local run_id = _last_run_id

    _run_state[run_id] = {
        waiting = #used_tasks, -- initially all tasks are waiting
        running = 0,
    }
    _report_state()

    local vars, _ = _load_variables(config_dir)

    -- Build task context
    ---@type loop.TaskContext
    local task_ctx = {
        ws_dir = ws_dir,
        variables = vars or vim.empty_dict()
    }

    -- Resolve macros only on the tasks that will be used
    resolver.resolve_macros(used_tasks, task_ctx, function(resolve_ok, resolved_tasks, resolve_error)
        if not resolve_ok or not resolved_tasks then
            local err_msg = resolve_error or "Failed to resolve macros in tasks"
            on_run_failed(err_msg)
            _on_run_end(run_id)
            return
        end
        -- Check if any task in the chain requires saving buffers
        local needs_save = false
        for _, task in ipairs(resolved_tasks) do
            if task.save_buffers == true then
                needs_save = true
                break
            end
        end
        -- Save workspace buffers if any task requires it
        if needs_save then
            local workspace = require("loop.workspace")
            local save_ok, saved_count, save_err = workspace.save_workspace_buffers(true)
            if not save_ok then
                on_run_failed(save_err or "Failed to save workspace buffers")
                _on_run_end(run_id)
                return
            end
            if saved_count > 0 then
                logs.user_log(
                    string.format("Saved %d file%s before running task", saved_count, saved_count == 1 and "" or "s"),
                    "save")
            end
        end
        --_status_page.set_ui_flags(config.current.window.symbols.running)
        task_scheduler.run_plan(
            resolved_tasks,
            root_name,
            function(task, on_exit)
                local page_group = _page_manager and _page_manager.add_page_group(task.name)
                if task.name == root_name then
                    root_page_group = page_group
                end
                if not page_group then
                    return nil, "failed to create page group"
                end
                return _start_task(task, page_group, root_name, on_exit)
            end,
            function(name, status, reason) -- on task event
                local status_str = (reason and reason ~= "") and ("%s - %s"):format(status, reason) or status
                logs.user_log(("Task update: `%s`: %s"):format(name, status_str), "task")
                local state = _run_state[run_id]
                if not state then return end
                if status == "running" then
                    state.waiting = math.max(0, state.waiting - 1)
                    state.running = state.running + 1
                elseif status == "success" or status == "failure" then
                    state.running = math.max(0, state.running - 1)
                end
                _report_state()
            end,
            function(success, reason) -- on exit
                if not success then
                    on_run_failed(reason)
                end
                _on_run_end(run_id)
            end
        )
    end)
end

---@return loop.ws.ActiveTaskData[]
function M.get_active_tasks()
    local ret = {}
    local keys = vim.tbl_keys(_active_tasks)
    vim.fn.sort(keys)
    for _, key in ipairs(keys) do
        table.insert(ret, _active_tasks[key])
    end
    return ret
end

--- Check if a task plan is currently running or terminating
---@return boolean
function M.have_running_tasks()
    return task_scheduler.is_running()
end

--- Terminate all running tasks
function M.terminate_tasks()
    task_scheduler.terminate()
end

return M
