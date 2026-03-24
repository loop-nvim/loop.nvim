local M = {}

local strtools = require("loop.utils.strtools")

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
    local proc_env
    if type(task.env) == "string" then
        ---@diagnostic disable-next-line: assign-type-mismatch
        local envstr = task.env ---@type string
        local parts = strtools.split_shell_args(envstr)
        proc_env = {}
        for _, part in ipairs(parts) do
            local key, value = part:match("^([^=]+)=(.*)$")
            if key and #key > 0 then
                proc_env[key] = value
            end
        end
    else
        if not type(proc_env) == "table" then
            return nil, "invalid task.env"
        end
        proc_env = task.env
    end

    local interrupted = false
    -- Your original args — unchanged, just using the resolved values
    ---@type loop.utils.TermProc.StartArgs
    local start_args = {
        name = task.name or "Unnamed Tool Task",
        command = task.command,
        env = proc_env,
        cwd = task.cwd or ws_dir,
        on_exit_handler = function(code)
            if code == 0 then
                on_exit(true, nil)
            elseif interrupted then
                on_exit(false, "Interrupted")
            else
                on_exit(false, "Exit code " .. tostring(code))
            end
        end,
    }

    local page_data, err_msg = page_group.add_page({
        type = "term",
        filetype = "term",
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
            interrupted = true
            proc:terminate()
        end
    }
    return controller, nil
end

return M
