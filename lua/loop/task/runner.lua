local M              = {}

local taskmgr        = require("loop.task.taskmgr")
local resolver       = require("loop.tools.resolver")
local logs           = require("loop.logs")
local task_scheduler = require("loop.task.taskscheduler")
local StatusComp     = require("loop.task.StatusComp")
local config         = require("loop.config")
local variablesmgr   = require("loop.task.variablesmgr")
local strtools       = require("loop.tools.strtools")

---@type loop.ws.WorkspaceInfo?
local _workspace_info

---@type loop.PageManagerFactory?
local _page_manager_fact

---@type table<string,loop.PageManager>
local _last_pm_by_task = {}

---@type loop.task.TasksStatusComp?,loop.PageController?,loop.PageGroup?
local _status_comp, _status_page, _status_pagegroup

local _last_run_id   = 0

---@param task_name string
---@param name_to_task table<string, loop.Task>
---@param visiting table<string, boolean>
---@param visited table<string, boolean>
---@return loop.TaskTreeNode? node, string? error
local function _build_task_tree(task_name, name_to_task, visiting, visited)
    -- True cycle (back-edge)
    if visiting[task_name] then
        return nil, "Cycle detected at task: " .. task_name
    end
    local task = name_to_task[task_name]
    if not task then
        return nil, "Unknown task: " .. task_name
    end
    -- Option B: already expanded elsewhere → return leaf
    if visited[task_name] then
        return {
            name = task.name,
            order = task.depends_order or "sequence",
            deps = {}, -- no re-expansion
        }, nil
    end
    visiting[task_name] = true
    local deps = {}
    for _, dep_name in ipairs(task.depends_on or {}) do
        local dep_node, err =
            _build_task_tree(dep_name, name_to_task, visiting, visited)
        if err then
            return nil, err
        end
        table.insert(deps, dep_node)
    end
    visiting[task_name] = nil
    visited[task_name] = true
    return {
        name = task.name,
        order = task.depends_order or "sequence",
        deps = deps,
    }, nil
end

---@param tasks loop.Task[]
---@param root string
---@return loop.TaskTreeNode|nil task_tree
---@return loop.Task[]? used_tasks
---@return string? error_msg
local function _generate_task_plan(tasks, root)
    local name_to_task = {}
    for _, t in ipairs(tasks) do
        if name_to_task[t.name] then
            return nil, nil, "Duplicate task: " .. t.name
        end
        name_to_task[t.name] = t
    end
    local visited = {}
    local visiting = {}
    local tree, err = _build_task_tree(root, name_to_task, visiting, visited)
    if err then return nil, nil, err end

    ---@type loop.Task[]
    local used_tasks = {}
    for name, _ in pairs(visited) do
        table.insert(used_tasks, name_to_task[name])
    end

    return tree, used_tasks, nil
end

---@param node table Task node from generate_task_plan_tree
---@param prefix? string Internal use for indentation
---@param is_last? boolean Internal use to determine tree branch
local function _print_task_tree(node, prefix, is_last)
    prefix = prefix or ""
    is_last = is_last or true

    local branch = is_last and "└─ " or "├─ "
    local line = prefix .. branch .. node.name .. " (" .. (node.order or "sequence") .. ")"
    local new_prefix = prefix .. (is_last and "   " or "│  ")
    if node.deps then
        for i, child in ipairs(node.deps) do
            line = line .. '\n' .. _print_task_tree(child, new_prefix, i == #node.deps)
        end
    end
    return line
end

---@param task loop.Task
---@param on_exit loop.TaskExitHandler
---@return loop.TaskControl|nil, string|nil
local function _start_task(task, on_exit)
    logs.user_log("Starting task:\n" .. vim.inspect(task), "task")
    assert(_page_manager_fact)

    local pm = _last_pm_by_task[task.name]
    if pm and task.if_running ~= "parallel" then
        pm.delete_all_groups(true)
    end
    pm = _page_manager_fact()
    _last_pm_by_task[task.name] = pm

    ---@type loop.TaskExitHandler
    local on_task_exit = function(ok, reason)
        on_exit(ok, reason)
    end

    return taskmgr.run_one_task(task, pm, on_task_exit)
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
---@param page_manager_fact loop.PageManagerFactory
function M.on_workspace_open(ws_info, page_manager_fact)
    _workspace_info = ws_info
    _page_manager_fact = page_manager_fact
    if (_status_comp or _status_page or _status_pagegroup) then return end
    local group = page_manager_fact().add_page_group("Status")
    assert(group, "page mgr error")
    local page_data = group.add_page({
        type = "comp",
        label = "Status",
        buftype = "status",
        activate = false,
    })
    assert(page_data)
    page_data.comp_buf.disable_change_events()
    local comp = StatusComp:new()
    comp:link_to_buffer(page_data.comp_buf)
    _status_comp, _status_page, _status_pagegroup = comp, page_data.page, group
end

function M.on_workspace_close()
    _page_manager_fact = nil
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

---@param all_tasks loop.Task[]
---@param root_name string
function M.run_task(all_tasks, root_name)
    assert(_workspace_info)
    assert(_status_comp and _status_page and _status_pagegroup)

    local ws_dir = _workspace_info.ws_dir
    local config_dir = _workspace_info.config_dir

    -- Log task start
    logs.user_log("Task started: " .. root_name, "task")
    local symbols = config.current.window.symbols
    --_status_page.set_ui_flags(symbols.waiting)

    if #all_tasks == 0 then
        vim.notify("No tasks found")
        logs.user_log("No tasks found")
        return
    end

    local node_tree, used_tasks, plan_error_msg = _generate_task_plan(all_tasks, root_name)
    if not node_tree or not used_tasks then
        logs.user_log(plan_error_msg or "Failed to build task plan", "task")
        vim.notify("Failed to start task, use ':Loop log' for details")
        return
    end

    logs.user_log("Scheduling tasks:\n" .. _print_task_tree(node_tree))

    _last_run_id = _last_run_id + 1
    local run_id = _last_run_id

    local run_status_items = {}
    for _, task in ipairs(used_tasks) do
        run_status_items[task.name] = _status_comp:add_task(task.name, "waiting")
    end

    local function remove_status_items()
        vim.defer_fn(function()
            for _, id in pairs(run_status_items) do
                _status_comp:remove_item(id)
            end
        end, 300 * 1000)
    end

    ---@param task_name string
    ---@param status loop.comp.StatusComp.Status
    ---@param msg string?
    local function report_status(task_name, status, msg)
        if msg then logs.user_log(("%s: %s"):format(task_name, msg), "task") end
        _status_comp:set_task_status(run_status_items[task_name], status, msg)
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
            remove_status_items()
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
                return _start_task(task, on_exit)
            end,
            function(name, status, reason) -- on task event
                logs.user_log(("%s: %s - %s"):format(name, status, reason), "task")
                report_status(name, status, reason)
            end,
            function(success, reason) -- on exit
                remove_status_items()
                --local status = success and "success" or "failure"
                --local error_msg = reason or "Unknown error"
                --for _, task in ipairs(used_tasks) do
                --    report_status(task.name, status, error_msg)
                --end
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
