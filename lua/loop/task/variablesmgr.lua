local M = {}

local JsonEditor = require('loop.json.JsonEditor')
local floatwin = require('loop.tools.floatwin')
local jsoncodec = require('loop.json.codec')
local filetools = require('loop.tools.file')
local uitools = require('loop.tools.uitools')
local jsonvalidator = require('loop.json.validator')

---@param config_dir string
---@return table<string, string>|nil
---@return string[]|nil
function M.load_variables(config_dir)
    local filepath = vim.fs.joinpath(config_dir, "variables.json")

    -- Missing file is not an error, return empty table
    if not filetools.file_exists(filepath) then
        return {}, nil
    end

    local loaded, contents_or_err = filetools.read_content(filepath)
    if not loaded then
        return nil, { contents_or_err }
    end

    local decoded, data_or_err = jsoncodec.from_string(contents_or_err)
    if not decoded or type(data_or_err) ~= 'table' then
        return nil, { data_or_err or "Parsing error" }
    end

    local data = data_or_err
    do
        local schema = require("loop.task.variablesschema")
        local valid, errors = jsonvalidator.validate(schema, data)
        if not valid then
            return nil, jsonvalidator.errors_to_string_arr(errors)
        end
        if not data or not data.variables then
            return nil, { "Parsing error: missing 'variables' field" }
        end
    end

    return data.variables, nil
end

---@param config_dir string
function M.show_variables(config_dir)
    local vars, var_errors = M.load_variables(config_dir)
    if var_errors then
        vim.notify("error(s) loading variables.json")
    end
    local text = jsoncodec.to_string(vars)
    floatwin.show_floatwin(text, {
        title = "Variables"
    })
end

---@param config_dir string
function M.configure_variables(config_dir)
    local schema = require("loop.task.variablesschema")
    local filepath = vim.fs.joinpath(config_dir, "variables.json")

    if not filetools.file_exists(filepath) then
        local schema_filepath = vim.fs.joinpath(config_dir, 'variablesschema.json')
        if not filetools.file_exists(schema_filepath) then
            jsoncodec.save_to_file(schema_filepath, schema)
        end
        local data = {}
        data["$schema"] = './variablesschema.json'
        data["variables"] = vim.empty_dict()
        jsoncodec.save_to_file(filepath, data)
    end

    local editor = JsonEditor:new({
        name = "Variables editor",
        filepath = filepath,
        schema = schema,
    })

    editor:open()
end

return M
