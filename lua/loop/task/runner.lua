local M               = {}

local taskmgr         = require("loop.task.taskmgr")
local resolver        = require("loop.tools.resolver")
local logs            = require("loop.logs")
local task_scheduler  = require("loop.task.taskscheduler")
local StatusComp      = require("loop.task.StatusComp")
local config          = require("loop.config")
local variablesmgr    = require("loop.task.variablesmgr")
local strtools        = require("loop.tools.strtools")
local planner         = require("loop.task.planner")

---@type loop.ws.WorkspaceInfo?
local _workspace_info

---@type loop.PageManager?
local _page_manager

---@type table<string,{run_id:number,pg:loop.PageGroup?,tast_ended:boolean?}[]>
local _page_groups    = {}

local _last_run_id    = 0

---@type fun(text:string)?
local _status_handler = nil

---@param run_id number
---@param task_name string
---@return {run_id:number,pg:loop.PageGroup?,tast_ended:boolean?}?
local function _get_pg_data(run_id, task_name)
    assert(_page_manager)
    local task_pgdata = _page_groups[task_name]
    if not task_pgdata then
        task_pgdata = {}
        _page_groups[task_name] = task_pgdata
    end
    do
        -- if pg_data exists, return it
        local pg_data = task_pgdata[run_id]
        if pg_data and pg_data.pg and not pg_data.tast_ended then
            return pg_data
        end
    end
    -- try to recycle a terminated pg_data from this task
    local tgt_group
    for _, pg_data in pairs(task_pgdata) do
        if pg_data.tast_ended then
            tgt_group = pg_data
            break
        end
    end
    -- or create a new pg_data
    if not tgt_group then
        tgt_group = task_pgdata[run_id] or {}
        task_pgdata[run_id] = tgt_group
    end
    if tgt_group.pg then
        tgt_group.pg.delete_group()
    end
    tgt_group.pg = _page_manager.add_page_group(task_name)
    return tgt_group
end

---@param run_id number
---@param root_name string
---@param err_msg string
local function _report_run_failure(run_id, root_name, err_msg)
    local pg_data = _get_pg_data(run_id, root_name)
    if pg_data and pg_data.pg then
        local page = pg_data.pg.add_page({
            label = "Status",
            type = "output"
        })
        if page then
            page.output_buf.add_lines(err_msg)
        end
        pg_data.tast_ended = true
    end
end

---@param run_id number
---@param task loop.Task
---@param on_exit loop.TaskExitHandler
---@return loop.TaskControl|nil, string|nil
local function _start_task(run_id, task, on_exit)
    logs.user_log("Starting task:\n" .. vim.inspect(task), "task")
    local pg_data = _get_pg_data(run_id, task.name)
    local page_group = pg_data and pg_data.pg
    if not page_group then
        return nil, "failed to create page group"
    end
    ---@type loop.TaskExitHandler
    local exit_handler = function(success, reason)
        pg_data.tast_ended = true
        on_exit(success, reason)
    end
    return taskmgr.run_one_task(task, page_group, exit_handler)
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

---@param mode "task"|"repeat"
---@param task_name string|nil
function M.load_and_run_task(mode, task_name)
    assert(_workspace_info)
    local config_dir = _workspace_info.config_dir

    taskmgr.get_or_select_task(config_dir, mode, task_name, function(root_name, all_tasks)
        if not root_name or not all_tasks then
            return
        end
        taskmgr.save_last_task_name(root_name, config_dir)
        M.run_task(all_tasks, root_name)
    end)
end

---@param handler fun(text:string)
function M.set_status_handler(handler)
    _status_handler = handler
end

---@param all_tasks loop.Task[]
---@param root_name string
function M.run_task(all_tasks, root_name)
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

    logs.user_log("Scheduling tasks:\n" .. planner.print_task_tree(node_tree))

    _last_run_id = _last_run_id + 1
    local run_id = _last_run_id
    ---@param task_name string
    ---@param status loop.comp.StatusComp.Status
    ---@param msg string?
    local function report_status(task_name, status, msg)
        local symbols = config.current.window.symbols
        if msg then logs.user_log(("%s: %s"):format(task_name, msg), "task") end
        if _status_handler then
            local nb_waiting, nb_running = 0, 0 -- TODO
            local parts = {}
            if nb_waiting > 0 then
                table.insert(parts, ("%s %d"):format(symbols.waiting, nb_waiting))
            end
            if nb_running > 0 then
                table.insert(parts, ("%s %d"):format(symbols.running, nb_running))
            end
            _status_handler(table.concat(parts, "  "))
        end
    end

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
            for _, task in ipairs(used_tasks) do
                report_status(task.name, "failure", err_msg)
            end
            _report_run_failure(run_id, root_name, err_msg)
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
            local saved_count = workspace.save_workspace_buffers()
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
                --_status_page.set_ui_flags(config.current.window.symbols.running)
                return _start_task(run_id, task, on_exit)
            end,
            function(name, status, reason) -- on task event
                logs.user_log(("%s: %s - %s"):format(name, status, reason), "task")
                report_status(name, status, reason)
            end,
            function(success, reason) -- on exit
                if not success then
                    _report_run_failure(run_id, root_name, reason)
                end
            end
        )
    end)
end

--- Check if a task plan is currently running or terminating
---@return boolean
function M.have_running_task()
    return task_scheduler.is_running()
end

--- Terminate the currently running task plan (if any)
function M.terminate_tasks()
    task_scheduler.terminate()
end

return M
