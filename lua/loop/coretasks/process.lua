local M = {}

---@class loop.coretasks.process.Task : loop.Task
---@field command string[]|string|nil
---@field cwd string?
---@field env table<string,string>? # optional environment variables

---@param ws_dir string
---@param task loop.coretasks.process.Task
---@param page_group loop.PageGroup
---@param on_exit loop.TaskExitHandler
---@return loop.TaskControl|nil
---@return string|nil
function M.start_task(ws_dir, task, page_group, on_exit)
    if not task.command then
        return nil, "task.command is required"
    end

    -- Your original args — unchanged, just using the resolved values
    ---@type loop.tools.TermProc.StartArgs
    local start_args = {
        name = task.name or "Unnamed Tool Task",
        command = task.command,
        env = task.env,
        cwd = task.cwd or ws_dir,
        on_exit_handler = function(code)
            if code == 0 then
                on_exit(true, nil)
            else
                on_exit(false, "Exit code " .. tostring(code))
            end
        end,
    }

    local page_data, err_msg = page_group.add_page({
        type = "term",
        buftype = "term",
        label = task.name,
        term_args = start_args,
        activate = true,
    })

    if not page_data then
        return nil, "failed to create task page"
    end

    --add_term_page(task.name, start_args, true)
    local proc = page_data.term_proc
    if not proc then
        return nil, err_msg
    end

    ---@type loop.TaskControl
    local controller = {
        terminate = function()
            proc:terminate()
        end
    }
    return controller, nil
end

return M
