local schema = {
    ["$schema"] = "http://json-schema.org/draft-07/schema#",
    title = "Loop Variables Configuration",
    description = "Configuration file for loop.nvim custom variables",
    type = "object",
    additionalProperties = false,
    required = { "variables" },
    properties = {
        ["$schema"] = {
            type = "string"
        },
        variables = {
            type = "object",
            patternProperties = {
                ["^[A-Za-z_][-A-Za-z0-9_]*$"] = { type = "string" }
            },
            additionalProperties = false,
            description = "Object mapping variable names to their values",
        },
    },
}

return schema
