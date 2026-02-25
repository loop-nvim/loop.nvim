local M = {}

local function _escape_ptr(token)
    return (tostring(token)
        :gsub("~", "~0")
        :gsub("/", "~1"))
end

local function _unescape_ptr(token)
    return (token
        :gsub("~1", "/")
        :gsub("~0", "~"))
end

-- Build a JSON Pointer (defined in RFC 6901)
---@param base string
---@param key string
---@return string -- JSON Pointer (defined in RFC 6901)
function M.join_path(base, key)
    local escaped = _escape_ptr(key)
    if base == "" or base == "/" then
        return "/" .. escaped
    end
    return base .. "/" .. escaped
end

-- Build a JSON Pointer (defined in RFC 6901)
---@param parts string[]
---@return string -- JSON Pointer (RFC 6901)
function M.join_path_parts(parts)
    local arr = {}
    for _, seg in ipairs(parts) do
        if seg ~= nil and seg ~= "" then
            table.insert(arr, _escape_ptr(seg))
        end
    end
    return "/" .. table.concat(arr, "/")
end

---@param path string -- -- JSON Pointer (defined in RFC 6901)
---@return string[]
function M.split_path(path)
    if path == "" or path == "/" then
        return {}
    end

    local parts = {}
    for part in path:gmatch("[^/]+") do
        table.insert(parts, _unescape_ptr(part))
    end
    return parts
end

---@param errors loop.json.ValidationError[]
---@param path string -- path is a JSON Pointer (defined in RFC 6901)
---@param msg string
local function add_error(errors, path, msg)
    table.insert(errors, {
        path = path,
        err_msg = msg,
    })
end

-- Helper: check enum
local function check_enum(enum_tbl, value)
    for _, v in ipairs(enum_tbl) do
        if v == value then
            return true
        end
    end
    return false
end

---@class loop.json.ValidationError
---@field path string
---@field err_msg string

-- Core recursive validator
---@param schema table
---@param data any
---@param path string
---@return loop.json.ValidationError[]?
local function _validate(schema, data, path)
    ---@type loop.json.ValidationError[]
    local errors = {}

    -- Type check
    local allowed_types = type(schema.type) == "table" and schema.type or { schema.type }
    if allowed_types and not vim.tbl_isempty(allowed_types) then
        local ok = false
        for _, t in ipairs(allowed_types) do
            if t == "null" and data == nil then
                ok = true
            elseif t == "object" and type(data) == "table" and not vim.islist(data) then
                ok = true
            elseif t == "array" and vim.islist(data) then
                ok = true
            elseif t == "string" and type(data) == "string" then
                ok = true
            elseif t == "number" and type(data) == "number" then
                ok = true
            elseif t == "boolean" and type(data) == "boolean" then
                ok = true
            end
            if ok then break end
        end

        if not ok then
            local expected = table.concat(allowed_types, " or ")
            ---@type string
            local got = type(data)
            if got == "table" then
                got = vim.islist(data) and "array" or "object"
            elseif data == nil then
                got = "null"
            end
            add_error(errors, path, ("expected %s, got %s"):format(expected, got))
            return errors
        end
    end

    -- enum
    if schema.enum and not check_enum(schema.enum, data) then
        add_error(errors, path, "valid values: " .. table.concat(schema.enum, ", "))
        return errors
    end

    -- const
    if schema.const ~= nil then
        local function deep_equal(a, b)
            if a == b then return true end
            if type(a) ~= type(b) then return false end
            if type(a) ~= "table" then return false end
            for k, v in pairs(a) do if not deep_equal(v, b[k]) then return false end end
            for k, v in pairs(b) do if not deep_equal(v, a[k]) then return false end end
            return true
        end

        if not deep_equal(data, schema.const) then
            add_error(
                errors,
                path,
                ("expecting %s, got %s"):format(
                    vim.inspect(schema.const),
                    vim.inspect(data)
                )
            )
            return errors
        end
    end

    -- object
    if schema.type == "object" or (type(schema.type) == "table" and vim.tbl_contains(schema.type, "object")) then
        if type(data) ~= "table" or vim.islist(data) then
            add_error(errors, path, "expected object")
            return errors
        end

        local props = schema.properties or {}
        local required = schema.required or {}
        local pattern_props = schema.patternProperties or {}

        local missing
        for _, key in ipairs(required) do
            if data[key] == nil then
                missing = missing or {}
                table.insert(missing, key)
            end
        end
        if missing then
            add_error(errors, path,
                ("required propert%s missing: %s"):format(#missing == 1 and "y" or "ies", table.concat(missing, ', ')))
        end

        for key, subschema in pairs(props) do
            if data[key] ~= nil then
                local sub_err = _validate(subschema, data[key], M.join_path(path, key))
                if sub_err then vim.list_extend(errors, sub_err) end
            end
        end

        local addl = schema.additionalProperties
        for key, value in pairs(data) do
            local handled = props[key] ~= nil
            for pattern, subschema in pairs(pattern_props) do
                if type(key) == "string" and key:match(pattern) then
                    handled = true
                    local sub_err = _validate(subschema, value, M.join_path(path, key))
                    if sub_err then vim.list_extend(errors, sub_err) end
                end
            end
            if not handled then
                if addl == false then
                    add_error(errors, M.join_path(path, key), "invalid property name")
                elseif type(addl) == "table" then
                    local sub_err = _validate(addl, value, M.join_path(path, key))
                    if sub_err then vim.list_extend(errors, sub_err) end
                end
            end
        end
    end

    -- array
    if schema.type == "array" or (type(schema.type) == "table" and vim.tbl_contains(schema.type, "array")) then
        if not vim.islist(data) then
            add_error(errors, path, "expected array")
            return errors
        end
        if schema.items then
            for i, value in ipairs(data) do
                local sub_err = _validate(schema.items, value, path .. "/" .. i)
                if sub_err then vim.list_extend(errors, sub_err) end
            end
        end
    end

    -- string pattern
    if schema.pattern and type(data) == "string" and not data:match(schema.pattern) then
        add_error(errors, path, ("string does not match pattern %q"):format(schema.pattern))
    end

    -- string pattern
    if type(schema.minLength) == "number" and type(data) == "string" and vim.fn.strdisplaywidth(data) < schema.minLength then
        local err = schema.minLength > 1 and ("string must be at least %d character"):format(schema.minLength) or "string cannot be empty"
        add_error(errors, path, err)
    end

    -- oneOf (best-match selection)
    if schema.oneOf then
        local best_errors = nil
        local best_count = math.huge
        --local best_option = nil

        for i, sub in ipairs(schema.oneOf) do
            local sub_err = _validate(sub, data, path)
            if not sub_err then
                -- Perfect match: oneOf succeeds
                best_errors = nil
                best_count = 0
                --best_option = nil
                break
            end

            local count = #sub_err
            if count < best_count then
                best_count = count
                best_errors = sub_err
                --best_option = sub.__name
            end
        end

        if best_errors then
            vim.list_extend(errors, best_errors)
        end
    end

    return #errors > 0 and errors or nil
end

---@param schema table
---@param data any
---@return loop.json.ValidationError[]?
function M.validate(schema, data)
    return _validate(schema, data, "")
end

---@param errors loop.json.ValidationError[]
---@return string
function M.errors_to_string(errors)
    local err = {}
    for _, e in ipairs(errors) do
        table.insert(err, e.path .. ": " .. e.err_msg)
    end
    return table.concat(err, '\n')
end

---@param errors loop.json.ValidationError[]
---@return string[]
function M.errors_to_string_arr(errors)
    local ret = {}
    for _, e in ipairs(errors) do
        table.insert(ret, e.path .. ": " .. e.err_msg)
    end
    return ret
end

---@param value any
---@param schema table|nil
---@return table|nil, boolean  -- resolved_schema, is_valid
function M.resolve_oneof_schema(value, schema)
    if not (schema and schema.oneOf) then
        return schema, true
    end

    local best_subschema = nil
    local best_error_count = math.huge

    for _, subschema in ipairs(schema.oneOf) do
        local errors = M.validate(subschema, value)
        if not errors then
            -- Perfect match
            return subschema, true
        end
        assert(#errors > 0)
        local err_count = #errors
        if err_count < best_error_count then
            best_subschema = subschema
            best_error_count = err_count
        end
    end

    -- No perfect match → return best candidate + false
    return best_subschema, false
end

return M
