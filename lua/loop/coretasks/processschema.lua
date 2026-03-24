local schema = {
    description = "Executes a process or shell command as a task",
    required = { "command" },
    ["x-order"] = { "command", "cwd", "env" },

    properties = {
        command = {
            description =
            "Command to execute. Can be a single string, or a list of string (program + args)",
            oneOf = {
                {
                    type = "string",
                    minLength = 1,
                    description = "Command or process to execute, can include arguments"
                },
                {
                    type = "array",
                    minItems = 1,
                    description = "Command with arguments, executed without shell interpolation",
                    items = {
                        type = "string",
                        minLength = 1,
                        description = "Command or argument token"
                    },
                },
                {
                    type = "null",
                    description = "No command execution"
                },
            },
        },

        cwd = {
            type = { "string", "null" },
            description = "Working directory used when executing the command"
        },


        env = {
            description =
            "Environment variables applied to the command execution",
            oneOf = {
                {
                    type = "string",
                    minLength = 1,
                    description =
                    "Environment variables applied to the command execution, format: VAR1=VALUE1 VAR2=VALUE2 ..."
                },
                {
                    type = { "object", "null" },
                    description = "Additional environment variables applied to the command execution",
                    additionalProperties = {
                        type = "string",
                        description = "Environment variable value"
                    },
                },
            },
        },
    },
}

return schema
