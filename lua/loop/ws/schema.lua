local schema = {
    ["$schema"] = "http://json-schema.org/draft-07/schema#",
    title = "Loop Variables Configuration",
    description = "Configuration file for loop.nvim custom variables",
    type = "object",
    additionalProperties = false,
    required = { "workspace" },
    properties = {
        ["$schema"] = {
            type = "string"
        },
        workspace = {
            type = "object",
            required = { "name", "save" },
            ["x-order"] = { "name", "save" },
            properties = {
                name = {
                    type = { "string" },
                    default = "",
                    description = "Optional name/identifier for this configuration entry",
                },
                save = {
                    type = { "object", "null" },
                    description = "File saving/filtering options",
                    default = {},
                    ["x-order"] = { "include", "exclude", "follow_symlinks" },
                    properties = {
                        include = {
                            type = { "array" },
                            description = "Glob patterns for files to include when saving",
                            items = { type = "string" },
                        },
                        exclude = {
                            type = { "array" },
                            description = "Glob patterns for files/directories to exclude",
                            items = { type = "string" },
                        },
                        follow_symlinks = {
                            type = { "boolean" },
                            description = "Whether to follow symbolic links when scanning",
                        },
                    },
                    additionalProperties = false,
                },
            },
            additionalProperties = false,

        },
    },
}


return schema
