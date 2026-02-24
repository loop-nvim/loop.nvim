local class = require("loop.tools.class")
local ItemTreeComp = require("loop.comp.ItemTree")
local CompBuffer = require("loop.buf.CompBuffer")
local floatwin = require("loop.tools.floatwin")
local selector = require("loop.tools.selector")
local file_util = require("loop.tools.file")
local validator = require("loop.json.validator")
local jsontools = require("loop.json.jsontools")
local jsoncodec = require("loop.json.codec")
local uitools = require('loop.tools.uitools')

---@alias JsonPrimitive string|number|boolean|nil
---@alias JsonValue JsonPrimitive|table<string,JsonValue>|JsonValue[]

---@class loop.JsonEditor.NodeData
---@field key string
---@field path string
---@field value JsonValue
---@field value_type string
---@field err_msg string|nil
---@field unresolved_schema table|nil
---@field schema table|nil

---@class loop.JsonEditorOpts
---@field name string?
---@field filepath string?
---@field schema table?
---@field null_support boolean?

---@class loop.JsonEditor
---@field new fun(self:loop.JsonEditor,opts:loop.JsonEditorOpts):loop.JsonEditor
---@field _opts loop.JsonEditorOpts
---@field _filepath string
---@field _data table
---@field _schema table|nil
---@field _fold_cache table<string, boolean>
---@field _undo_stack table[]
---@field _redo_stack table[]
---@field _validation_errors loop.json.ValidationError[]
---@field _is_dirty boolean
---@field _value_selection_handler fun(path:string, callback:fun(value:any?))?
---@field _itemtree loop.comp.ItemTree
---@field _is_open boolean
local JsonEditor = class()

local function _show_help()
    local help_text = {
        "Navigation:",
        "  <CR>     Toggle expand/collapse",
        "",
        "Editing:",
        "  i        Add element to object or array",
        "  o        Add element after",
        "  O        Add element before",
        "  c        Change value",
        "  C        Change value (JSON)",
        "  d        Delete element",
        "  u        Undo last change",
        "  C-r      Redo last change",
        "",
        "Other:",
        "  K        Show element help (hover window)",
        "  !        Show validation errors",
        "  g?       Show this help",
    }

    floatwin.show_floatwin(table.concat(help_text, "\n"), { title = "Show help" })
end

--- Dynamically call a Lua function given a module path string
---@param path string e.g. "module.submodule.func"
---@param ... any arguments to pass
---@return any return values
local function _call_lua_function(path, ...)
    local parts = vim.split(path, "%.")
    if #parts < 2 then
        error("Path must be at least module.function")
    end

    local fn_name = table.remove(parts)          -- last element is function
    local module_path = table.concat(parts, ".") -- the rest is module

    -- require the module
    local mod = require(module_path)
    local fn = mod[fn_name]

    if type(fn) ~= "function" then
        error(("'%s' is not a function in module '%s'"):format(fn_name, module_path))
    end

    return fn(...)
end

---@param filetype string
local function _get_existing_window(filetype)
    local curwin = vim.api.nvim_get_current_win()
    local curbuf = vim.api.nvim_win_get_buf(curwin)
    if vim.bo[curbuf].filetype == filetype then
        return curwin
    end
    local tabpage = vim.api.nvim_get_current_tabpage()
    local windows = vim.api.nvim_tabpage_list_wins(tabpage)
    for _, winid in ipairs(windows) do
        if vim.api.nvim_win_is_valid(winid) then
            local cfg = vim.api.nvim_win_get_config(winid)
            if cfg.relative == "" then -- skip poup windows
                local bufnr = vim.api.nvim_win_get_buf(winid)
                if vim.bo[bufnr].filetype == filetype then
                    return winid
                end
            end
        end
    end
    return -1
end

---@param schema table|nil
---@param null_support boolean?
---@return string[]
local function _get_allowed_types(schema, null_support)
    local allowed = jsontools.get_schema_allowed_types(schema)
    if #allowed == 0 then
        allowed = { "string", "number", "boolean", "object", "array" }
        if null_support == true then
            table.insert(allowed, "null")
        end
    else
        if null_support ~= true then
            allowed = vim.tbl_filter(function(v) return v ~= "null" end, allowed)
        end
    end
    return allowed
end

---@param type_choice string
---@return any
local function _create_default_value(type_choice)
    if type_choice == "null" then return vim.NIL end
    if type_choice == "boolean" then return false end
    if type_choice == "number" then return 0 end
    if type_choice == "string" then return "" end
    if type_choice == "array" then return {} end
    if type_choice == "object" then return vim.empty_dict() end
    return vim.NIL
end

---@param input string
---@param wanted_type string
---@return any
local function _coerce_value(input, wanted_type)
    assert(type(input) == "string")
    assert(type(wanted_type) == "string")

    if wanted_type == "null" and (input == "" or input:lower() == "null") then
        return vim.NIL
    end

    if wanted_type == "boolean" then
        local l = input:lower()
        if l == "true" or l == "yes" or l == "1" then return true end
        if l == "false" or l == "no" or l == "0" then return false end
        return nil
    end

    if wanted_type == "integer" then
        local n = tonumber(input)
        if n and n == math.floor(n) then return n end
        return nil
    end

    if wanted_type == "number" then
        return tonumber(input)
    end

    -- fallback: string
    return input
end


---@param item loop.comp.ItemTree.Item?
local function _show_node_help(item)
    if not item or not item.data then
        vim.notify("No node selected", vim.log.levels.WARN)
        return
    end
    ---@type loop.JsonEditor.NodeData
    local data = item.data
    local schema = data.unresolved_schema
    local lines = {}
    if schema then
        local function add_field(label, value)
            if value == nil then return end
            if type(value) == "table" then
                value = vim.inspect(value):gsub("\n", " ")
            end
            table.insert(lines, ("  %s: %s"):format(label, tostring(value)))
        end

        if type(schema.description) then
            table.insert(lines, schema.description)
        end

        if schema.enum then
            local enum_str = table.concat(vim.tbl_map(vim.inspect, schema.enum), ", ")
            add_field("enum", enum_str)
        end

        if schema.items and not vim.islist(schema.items) then
            local item_types = _get_allowed_types(schema.items)
            add_field("items type", table.concat(item_types, " | "))
        end

        local req = schema.required or {}
        if #req > 0 then
            add_field("required properties", table.concat(req, ", "))
        end

        if schema.default ~= nil then
            add_field("default", vim.inspect(schema.default))
        end

        if schema.format then
            add_field("format", schema.format)
        end

        if schema.pattern then
            add_field("pattern", schema.pattern)
        end

        if schema.minimum or schema.maximum then
            add_field("range", (schema.minimum or "-∞") .. " ≤ x ≤ " .. (schema.maximum or "∞"))
        end
    end
    if #lines == 0 then
        table.insert(lines, "(no information available)")
    end

    floatwin.show_tooltip(table.concat(lines, "\n"))
end

---@param _ any
---@param data loop.JsonEditor.NodeData
---@return string[][], string[][]
local function _formatter(_, data, expanded)
    if not data then return {}, {} end

    local text_chunks = {}
    local virt_chunks = {}

    local key = tostring(data.key or "")
    local vt = data.value_type
    local value = data.value
    local err_msg = data.err_msg

    -- Key label
    table.insert(text_chunks, { key, "Label" })

    if vt == "object" or vt == "array" then
        -- Show bracket count as virt_text
        if type(value) == "table" then
            local count = #value
            local bracket = vt == "object" and "{…}" or ("[…] (" .. count .. ")")
            table.insert(virt_chunks, { "", nil }) -- spacing
            table.insert(virt_chunks, { bracket, "Comment" })
            if expanded == false and vt == "object" then
                local name_prop = data.schema and data.schema["x-name-prop"]
                if name_prop then
                    local name = value[name_prop]
                    if name then
                        table.insert(virt_chunks, { " ", nil }) -- spacing
                        table.insert(virt_chunks, { name, "Comment" })
                    end
                end
            end
        else
            table.insert(virt_chunks, { "Type Error", "Error" })
        end
    else
        -- Separator between key and value
        table.insert(text_chunks, { ": ", "Comment" })

        if vt == "string" then
            table.insert(text_chunks, { tostring(value):gsub("\n", "↵"), "@string" })
        elseif vt == "null" then
            table.insert(text_chunks, { "null", "@constant" })
        elseif vt == "boolean" then
            table.insert(text_chunks, { tostring(value), "@boolean" })
        else
            table.insert(text_chunks, { tostring(value), "@number" })
        end
    end

    -- Append error as virt_text if present
    if err_msg then
        if #virt_chunks > 0 then table.insert(virt_chunks, { " ", nil }) end -- spacing
        table.insert(virt_chunks, { "● " .. err_msg, "DiagnosticError" })
    end

    return text_chunks, virt_chunks
end

---@param opts loop.JsonEditorOpts
function JsonEditor:init(opts)
    self._opts = opts or {} ---@type loop.JsonEditorOpts
    self._undo_stack = {} ---@type table[]
    self._redo_stack = {} ---@type table[]
    self._is_dirty = false
    self._validation_errors = {} ---@type loop.json.ValidationError[]
    self._filepath = opts.filepath
    self._schema = opts.schema
    self._fold_cache = {} ---@type table<string, boolean>
    self._is_open = false
end

---@param handler fun(path:string, callback:fun(value:any?))?
function JsonEditor:set_value_selection_handler(handler)
    self._value_selection_handler = handler
end

---@param winid integer?
function JsonEditor:open(winid)
    assert(not self._is_open, "Editor already open")
    self._is_open = true

    local name = self._opts.name or "JSON Editor"

    ---@diagnostic disable-next-line: undefined-field
    self._itemtree = ItemTreeComp:new({
        formatter = _formatter,
        render_delay_ms = 40,
    })

    self:_reload_data()

    self._itemtree:add_tracker({
        on_toggle = function(_, data, expanded)
            self._fold_cache[data.path or ""] = expanded
        end,
    })

    local filetype = "loop-jsoneditor"
    local buf = CompBuffer:new(filetype, name)

    local function with_current_item(fn)
        local item = self._itemtree:get_cur_item()
        if item then fn(item) end
    end

    buf:add_keymap("c", {
        desc = "Change value",
        callback = function() with_current_item(function(i) self:_edit_value(i) end) end,
    })

    buf:add_keymap("C", {
        desc = "Change string (multiline)",
        callback = function() with_current_item(function(i) self:_edit_value(i, true) end) end,
    })

    buf:add_keymap("i", {
        desc = "Add property/item",
        callback = function() with_current_item(function(i) self:_add_new(i, "under") end) end,
    })

    buf:add_keymap("o", {
        desc = "insert item (Add the parent node)",
        callback = function() with_current_item(function(i) self:_add_new(i, "after") end) end,
    })

    buf:add_keymap("O", {
        desc = "insert item (Add the parent node)",
        callback = function() with_current_item(function(i) self:_add_new(i, "before") end) end,
    })

    buf:add_keymap("d", {
        desc = "Delete",
        callback = function() with_current_item(function(i) self:_delete(i) end) end,
    })

    buf:add_keymap("K", {
        desc = "Show schema/help for current node (K)",
        callback = function() with_current_item(function(i) _show_node_help(i) end) end,
    })

    buf:add_keymap("u", { desc = "Undo", callback = function() self:undo() end })
    buf:add_keymap("<C-r>", { desc = "Redo", callback = function() self:redo() end })
    buf:add_keymap("g?", { desc = "Help", callback = function() _show_help() end })
    buf:add_keymap("ge", { desc = "Show errors", callback = function() self:_show_errors() end })

    self._itemtree:link_to_buffer(buf:make_controller())

    local bufid = buf:get_or_create_buf()
    local tgtwin = winid
    if not tgtwin or tgtwin < 0 then
        tgtwin = _get_existing_window(filetype)
        if tgtwin == -1 then
            tgtwin = uitools.get_regular_window()
        end
    end
    vim.api.nvim_set_current_win(tgtwin)
    vim.api.nvim_win_set_buf(tgtwin, bufid)
end

function JsonEditor:_apply_changes()
    self:save()
    vim.schedule(function()
        self:_reload_data()
    end)
end

function JsonEditor:_reload_data()
    local ok, data = jsoncodec.load_from_file(self._filepath)
    if not ok then
        if file_util.file_exists(self._filepath) then
            vim.notify("Failed to load JSON: " .. tostring(data), vim.log.levels.WARN)
            return
        else
            data = {}
        end
    end
    self._data = data
    self:_reload_tree()
end

function JsonEditor:_reload_tree()
    self._validation_errors = {}
    ---@type table<string, string>
    local errors = {}
    if self._schema then
        local validation_errors = validator.validate(self._schema, self._data)
        if validation_errors and #validation_errors > 0 then
            self._validation_errors = validation_errors
            for _, e in ipairs(validation_errors) do
                errors[e.path] = e.err_msg:gsub("\n", " ")
            end
        end
    end
    self:_upsert_tree_items(self._data, "", nil, self._schema, errors)
end

---@param tbl table
---@param path string
---@param parent_id string?
---@param parent_schema table?
---@param errors table<string,string>
function JsonEditor:_upsert_tree_items(tbl, path, parent_id, parent_schema, errors)
    assert(type(tbl) == "table")

    ---@type loop.comp.ItemTree.ItemDef[]
    local items = {}

    if vim.islist(tbl) then
        for i, v in ipairs(tbl) do
            local str_i = tostring(i)
            local p = validator.join_path(path, str_i)
            local item_schema = parent_schema and parent_schema.items or nil
            jsontools.merge_additional_properties(item_schema, parent_schema)

            local unresolved_schema = item_schema
            local resolved_schema = validator.resolve_oneof_schema(v, item_schema) or item_schema

            local e = errors[p]

            ---@type loop.comp.ItemTree.ItemDef
            local item = {
                id = p,
                expanded = self._fold_cache[p] ~= false,
                data = {
                    key               = "[" .. str_i .. "]",
                    path              = p,
                    value             = v,
                    err_msg           = e,
                    value_type        = jsontools.value_type(v),
                    unresolved_schema = unresolved_schema,
                    schema            = resolved_schema,
                },
            }
            table.insert(items, item)
        end
    else
        local keys = vim.tbl_keys(tbl)
        jsoncodec.order_keys(keys, parent_schema)

        for _, k in ipairs(keys) do
            if k == "$schema" then goto continue end

            local v = tbl[k]
            local p = validator.join_path(path, k)

            local prop_schema, unresolved_schema, resolved_schema
            if parent_schema and parent_schema.properties and parent_schema.properties[k] then
                prop_schema = parent_schema.properties[k]
                jsontools.merge_additional_properties(prop_schema, parent_schema)
                unresolved_schema = prop_schema
                resolved_schema = validator.resolve_oneof_schema(v, prop_schema) or prop_schema
            end

            local e = errors[p]

            ---@type loop.comp.ItemTree.ItemDef
            local item = {
                id = p,
                parent_id = parent_id,
                expanded = self._fold_cache[p] ~= false,
                data = {
                    key               = k,
                    path              = p,
                    value             = v,
                    err_msg           = e,
                    value_type        = jsontools.value_type(v),
                    unresolved_schema = unresolved_schema,
                    schema            = resolved_schema,
                },
            }
            table.insert(items, item)

            ::continue::
        end
    end

    self._itemtree:update_children(parent_id, items)

    for _, item in ipairs(items) do
        if type(item.data.value) == "table" then
            local data = item.data
            self:_upsert_tree_items(data.value, data.path, item.id, data.schema, errors)
        end
    end
end

---@param path string
---@return any
function JsonEditor:value_at(path)
    local item = self._itemtree:get_item(path)
    if not item then return nil end
    return item.data.value
end

---@param path string
---@param name string
---@param value_type string
---@param schema table?
---@param default_text string?
---@param value_selection_handler fun(path:string, callback:fun(value:any?))?
---@param on_confirm fun(value:any)
function JsonEditor:_request_value(path, name, value_type, schema, default_text, value_selection_handler, on_confirm)
    if schema and schema["x-valueSelector"] then
        local value_selector_fn_path = schema["x-valueSelector"]
        _call_lua_function(value_selector_fn_path, function(value)
            if value and validator.validate(schema, value) == nil then
                on_confirm(value)
            end
        end, vim.deepcopy(self._data), path)
        return
    end
    if value_type == "array" or value_type == "object" then
        on_confirm(_create_default_value(value_type))
        return
    end

    if (schema and schema.enum) or value_type == "boolean" then
        local values = schema and schema.enum or { true, false }
        local desc_list = schema and schema["x-enumDescriptions"]
        ---@type {label: string, data: any}[]
        local choices = {}
        local initial
        for i, v in ipairs(values) do
            local text = tostring(v)
            if text == default_text then initial = i end
            local desc = desc_list and desc_list[i]
            table.insert(choices, {
                label = text,
                data = v,
                virt_lines = desc and { { { desc, "Comment" } } } or nil
            })
        end
        selector.select({
            prompt = "Select value",
            items = choices,
            initial = initial,
            callback = function(data)
                if data ~= nil then
                    on_confirm(data)
                end
            end
        })
        return
    end
    local on_input = function(txt)
        if txt == nil then return end
        local coerced = _coerce_value(txt, value_type)
        if coerced ~= nil then
            on_confirm(coerced)
        end
    end
    ---@type table
    local input_opts = {
        prompt = ("%s (%s)"):format(name, value_type),
        default_text = default_text and tostring(default_text),
    }
    floatwin.input_at_cursor(input_opts, on_input)
end

---@param item loop.comp.ItemTree.Item
---@param multiline? boolean
function JsonEditor:_edit_value(item, multiline)
    local path = item.data.path ---@type string
    local schema = item.data.schema or {} ---@type table
    local current_value = item.data.value ---@type any
    if current_value == nil then
        return
    end
    if schema and schema.const then
        return
    end
    local on_confirm = function(value)
        if value ~= nil then
            self:_set_value(path, value)
        end
    end
    -- Normal scalar editing
    if multiline and item.data.value_type == "string" then
        local default_text = tostring(current_value)
        ---@type table
        local input_opts = {
            prompt = ("%s (%s)"):format(item.data.key, item.data.value_type),
            default_text = default_text,
        }
        floatwin.input_multiline(input_opts, on_confirm)
        return
    end
    self:_request_value(path, item.data.key, item.data.value_type, schema, current_value, self._value_selection_handler,
        on_confirm)
end

---@param path string
---@param new_value any
function JsonEditor:_set_value(path, new_value)
    local parts = validator.split_path(path) ---@type string[]
    local obj = nil
    local key = nil

    if #parts == 1 then
        obj = self._data
        key = parts[1]
    else
        local parent_id = self._itemtree:get_parent_id(path)
        if parent_id then
            ---@type loop.comp.ItemTree.Item?
            local par_item = self._itemtree:get_item(parent_id)
            if par_item then
                local last = parts[#parts]
                obj = par_item.data.value
                key = vim.islist(par_item.data.value) and tonumber(last) or tostring(last)
            end
        end
    end

    if obj and key then
        self:_push_undo()
        obj[key] = new_value
        self:_apply_changes()
    else
        vim.notify("Failed to set value")
    end
end

---@param item loop.comp.ItemTree.Item
---@param where "under"|"before"|"after"
function JsonEditor:_add_new(item, where)
    local insert_pos
    local parent
    if where == "under" then
        parent = item
    else
        local parts = validator.split_path(item.data.path)
        if #parts < 2 then return end
        local item_key = table.remove(parts, #parts)
        local parent_path = validator.join_path_parts(parts)
        local par_item = self._itemtree:get_item(parent_path)
        if not par_item then return end
        parent = par_item
        if parent.data.value_type == "array" then
            if where == "before" then
                insert_pos = tonumber(item_key)
            else
                insert_pos = tonumber(item_key) + 1
            end
        end
    end
    local vt = parent.data.value_type ---@type string
    if vt == "array" then
        self:get_new_array_member(parent, function(value)
            if value then
                self:_push_undo()
                local last_pos = #parent.data.value + 1
                local pos = insert_pos or last_pos
                pos = math.min(pos, last_pos)
                table.insert(parent.data.value, pos, value)
                self:_apply_changes()
            end
        end)
    elseif vt == "object" then
        self:get_new_object_member(parent, function(key, value)
            if value then
                assert(type(key) == "string")
                self:_push_undo()
                parent.data.value[key] = value
                self:_apply_changes()
            end
        end)
    else
        vim.notify("Can only add to object or array", vim.log.levels.INFO)
    end
end

---@param item loop.comp.ItemTree.Item
---@param callback fun(alue:any)
function JsonEditor:get_new_array_member(item, callback)
    local vt = item.data.value_type ---@type string
    local path = item.data.path
    local schema = item.data.schema ---@type table|nil
    if vt == "array" then
        local items_schema = schema and schema.items
        self:_get_new_value(path, items_schema, function(value) callback(value) end)
    else
        callback(nil)
    end
end

---@param item loop.comp.ItemTree.Item
---@param callback fun(key:string?,value:any)
function JsonEditor:get_new_object_member(item, callback)
    local vt = item.data.value_type ---@type string
    local schema = item.data.schema ---@type table|nil
    if vt == "object" then
        self:_get_object_new_value(item, schema, callback)
    else
        callback(nil)
    end
end

---@param item loop.comp.ItemTree.Item
function JsonEditor:_delete(item)
    if not item or not item.data or item.data.path == "" then
        vim.notify("Cannot delete root node", vim.log.levels.WARN)
        return
    end

    local parts = validator.split_path(item.data.path) ---@type string[]
    if #parts == 0 then return end

    local key = parts[#parts] ---@type string

    local parent_item = self._itemtree:get_parent_item(item.data.path)
    if not parent_item then return end

    local parent = parent_item.data.value
    if type(parent) ~= "table" then return end

    self:_push_undo()

    -- Perform deletion
    if vim.islist(parent) then
        local idx = tonumber(key)
        assert(type(idx) == "number")
        table.remove(parent, idx)
    else
        parent[key] = nil
        if next(parent) == nil then
            local empty_dict_mt = getmetatable(vim.empty_dict())
            assert(empty_dict_mt, "unsupported neovim API change")
            setmetatable(parent, empty_dict_mt)
        end
    end

    self:_apply_changes()
end

---@param path string
---@param schema table|nil
---@param callback fun(value:any)
function JsonEditor:_get_new_value(path, schema, callback)
    ---@param type_choice string
    local function get_value(type_choice)
        self:_request_value(path, "New array item", type_choice, schema, "", self._value_selection_handler,
            function(value)
                callback(value)
            end)
    end

    local allowed = _get_allowed_types(schema, self._opts.null_support) ---@type string[]

    if #allowed == 1 then
        get_value(allowed[1])
    else
        ---@type {label: string, data: string}[]
        local choices = {}
        for _, t in ipairs(allowed) do
            table.insert(choices, { label = t, data = t })
        end
        selector.select({
            prompt = "Select item type",
            items = choices,
            callback = function(data)
                if data then
                    get_value(data)
                end
            end
        })
    end
end

---@param item loop.comp.ItemTree.Item
---@param schema table|nil
---@param callback fun(key:string, value:any)
function JsonEditor:_get_object_new_value(item, schema, callback)
    schema = schema or {} ---@type table
    local obj = item.data.value ---@type table
    local path = item.data.path ---@type string

    -- Collect candidate keys from schema.properties / oneOf
    ---@type table<string, {schema: table, parent: table}[]>
    local key_candidates = {}
    ---@type string[]
    local suggested_keys = {}
    local key_descriptions = {}

    local function add_candidate(key, prop_schema, parent_schema)
        if obj[key] ~= nil then return end
        if not key_candidates[key] then
            key_candidates[key] = {}
            table.insert(suggested_keys, key)
            key_descriptions[key] = prop_schema.description
        end
        table.insert(key_candidates[key], {
            schema = prop_schema or {},
            parent = parent_schema,
        })
    end

    if schema.oneOf then
        for _, subschema in ipairs(schema.oneOf) do
            local errs = validator.validate(subschema, obj)
            if not errs or #errs == 0 then
                if subschema.properties then
                    for k, ps in pairs(subschema.properties) do
                        add_candidate(k, ps, subschema)
                    end
                end
            end
        end
    elseif schema.properties then
        for k, ps in pairs(schema.properties) do
            add_candidate(k, ps, schema)
        end
        jsoncodec.order_keys(suggested_keys, schema)
    end

    if #suggested_keys == 0 then
        vim.notify("No additional properties")
    end

    local on_confirm = function(key)
        if not key or key == "" then return end
        if obj[key] ~= nil then
            vim.notify("Key already exists", vim.log.levels.WARN)
            return
        end

        local schemas = key_candidates[key]
        local function with_schema(prop_schema)
            self:_get_new_value(path, prop_schema, function(value)
                callback(key, value)
            end)
        end

        if schemas and #schemas > 1 then
            ---@type {label: string, data: table}[]
            local choices = {}
            for _, info in ipairs(schemas) do
                table.insert(choices, {
                    label = info.parent.__name or "<schema>",
                    data = info.schema,
                })
            end
            selector.select({
                prompt = "Select schema for '" .. key .. "'",
                items = choices,
                callback = function(data)
                    if data then with_schema(data) end
                end
            })
            return
        end

        if schemas and schemas[1] then
            with_schema(schemas[1].schema)
            return
        end

        if type(schema.patternProperties) == "table" then
            for pattern, pat_schema in pairs(schema.patternProperties) do
                if key:match(pattern) then
                    with_schema(pat_schema)
                    return
                end
            end
        end

        -- fallback: additionalProperties
        local ap = schema.additionalProperties
        with_schema(type(ap) == "table" and ap or {})
    end

    local choices = {}
    for _, key in ipairs(suggested_keys) do
        local name, desc = key, key_descriptions[key]
        local desc_lines = desc and vim.split(desc, "\n", { trimempty = true })
        local desc_chunks = desc_lines and vim.tbl_map(function(a)
            return { { a, "Comment" } }
        end, desc_lines)
        ---@type loop.SelectorItem
        local choice = {
            label = name,
            virt_lines = desc_chunks,
            data = name
        }
        table.insert(choices, choice)
    end
    selector.select({
        items = choices,
        prompt = "Select property",
        callback = on_confirm
    })
end

function JsonEditor:_push_undo()
    table.insert(self._undo_stack, vim.fn.deepcopy(self._data))
    self._redo_stack = {}
    self._is_dirty = true
end

---@return table|nil
function JsonEditor:_pop_undo()
    return table.remove(self._undo_stack)
end

function JsonEditor:undo()
    if #self._undo_stack == 0 then
        vim.notify("Nothing to undo", vim.log.levels.INFO)
        return
    end

    table.insert(self._redo_stack, vim.fn.deepcopy(self._data))
    self._data = self:_pop_undo() or self._data
    self:_apply_changes()
end

function JsonEditor:redo()
    if #self._redo_stack == 0 then
        vim.notify("Nothing to redo", vim.log.levels.INFO)
        return
    end
    table.insert(self._undo_stack, vim.fn.deepcopy(self._data))
    self._data = table.remove(self._redo_stack)
    self:_apply_changes()
end

function JsonEditor:save()
    local ok, err = jsoncodec.save_to_file(self._filepath, self._data)
    if not ok then
        vim.notify("Save failed: " .. tostring(err), vim.log.levels.ERROR)
    else
        self._is_dirty = false
    end
end

function JsonEditor:_show_errors()
    if #self._validation_errors == 0 then
        vim.notify("No validation errors", vim.log.levels.INFO)
        return
    end

    local lines = { "=== Validation Errors ===\n" }
    for i, err in ipairs(self._validation_errors) do
        table.insert(lines, string.format("%d. at '%s': %s\n", i, err.path, err.err_msg))
    end

    floatwin.show_floatwin(table.concat(lines), { title = "Errors" })
end

return JsonEditor
