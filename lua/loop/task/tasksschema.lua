local base_schema = {
    ["$schema"] = "http://json-schema.org/draft-07/schema#",
    title = "Loop Task Configuration",
    type = "object",
    additionalProperties = false,
    required = { "tasks" },

    properties = {
        ["$schema"] = {
            type = "string",
        },
        tasks = {
            type = "array",
            description = "List of task definitions",
            additionalProperties = false,
            items = {
                description = "Single task definition entry",
                ["x-valueSelector"] = "loop.task.jsonselectors.select_taskobj",
                -- Providers will populate this with concrete task schemas
                oneOf = vim.empty_dict(),
            },
        },
    },
}

local base_items = {
    type = "object",
    description = "Definition of a single task",
    additionalProperties = false,
    required = { "name", "type" },
    ["x-name-prop"] = "name",
    ["x-order"] = { "name", "type", "save_buffers", "if_running", "depends_on", "depends_order" },

    properties = {
        -- Unique identifier for the task
        name = {
            type = "string",
            minLength = 1,
            description = "Unique, non-empty name of the task"
        },

        -- Type of task (used for dispatching to task providers)
        type = {
            type = "string",
            description = "Task type (used to determine behavior)"
        },

        -- Behavior when multiple instances of the task are started
        if_running = {
            type = "string",
            description = "Specifies what happens if the task is already running",
            enum = { "restart", "refuse", "parallel", },
            ["x-enumDescriptions"] = { "Stop the current instance and start a new one", "Do not start a new instance if one is already running", "Start a new instance alongside any existing ones" },
        },

        -- Tasks that must complete successfully before this task can start
        depends_on = {
            type = { "array", "null" },
            description = [[
List of task names that must complete successfully before this task runs.
This enforces a completion-based dependency order.
]],
            items = {
                type = "string",
                minLength = 1,
                description = "Name of a task this task depends on",
                ["x-valueSelector"] = "loop.task.jsonselectors.select_taskname",
            }
        },

        -- Execution order for dependencies: sequence vs parallel
        depends_order = {
            type = "string",
            description = "Specifies how dependencies listed in 'depends_on' are executed",
            enum = { "sequence", "parallel" },
            ["x-enumDescriptions"] = { "dependencies run one after another", "dependencies run concurrently" },
        },

        -- Save modified workspace buffers before executing this task
        save_buffers = {
            type = "boolean",
            default = false,
            description = "If true, all modified workspace buffers will be saved before running the task"
        },
    },
}

return {
    base_schema = base_schema,
    base_items = base_items,
}
