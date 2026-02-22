local process_task = require('loop.coretasks.process')

local M = {}

function M.get_composite_templates_provider()
    ---@type loop.TaskTemplateProvider
    return {
        get_task_templates = function()
            ---@type loop.taskTemplate[]
            return {

                {
                    name = "Task Sequence",
                    task = {
                        name = "Sequence",
                        type = "composite",
                        depends_on = { "", "" },
                        depends_order = "sequence",
                        save_buffers = nil,
                    },
                },
                {
                    name = "Parallel tasks",
                    task = {
                        name = "Parallel",
                        type = "composite",
                        depends_on = { "", "" },
                        depends_order = "parallel",
                        save_buffers = nil,
                    },
                },
            }
        end
    }
end

function M.get_process_templates_provider()
    ---@type loop.TaskTemplateProvider
    return {
        get_task_templates = function()
            ---@type loop.taskTemplate[]
            return {
                {
                    name = "Process",
                    task = {
                        name = "Run",
                        type = "process",
                        command = "",
                        cwd = "${wsdir}",
                        save_buffers = false,
                        depends_on = {}
                    },
                },
            }
        end
    }
end

function M.get_composite_task_provider()
    ---@type loop.TaskTypeProvider
    return {
        get_task_schema = function()
            return {}
        end,
        start_one_task = function(task, page_group, on_exit)
            -- composite task does nothing by itself
            on_exit(true)
            ---@type loop.TaskControl
            local controller = { terminate = function() end }
            return controller, nil
        end
    }
end

---@param ws_dir string
function M.get_process_task_provider(ws_dir)
    assert(type(ws_dir) == "string")
    ---@type loop.TaskTypeProvider
    return {
        get_task_schema = function()
            local schema = require('loop.coretasks.processschema')
            return schema
        end,
        start_one_task = function(task, page_group, on_exit)
            ---@cast task loop.coretasks.process.Task
            return process_task.start_task(ws_dir, task, page_group, on_exit)
        end
    }
end

return M
