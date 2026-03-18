local M = {}

---@type table<string, loop.ViewProvider>
local _registry = {}

---Validates that the ID contains only alphanumeric characters, hyphens, or underscores.
---@param name string
---@return boolean
local function is_valid_id(name)
    return name:match("^[a-zA-Z0-9%-_]+$") ~= nil
end

function M.clear_views()
    _registry = {}
end

---@param ws_dir string
function M.reset_views(ws_dir)
    local FileTree = require("loop.ui.FileTree")
    local tree = FileTree:new({
        root = ws_dir,
        include_globs = {}, -- ws_config.files.include,
        exclude_globs = {}, -- ws_config.files.exclude,
    })
    ---@type loop.ViewProvider
    local provider = {
        create_buffer = function()
            local buf = tree:get_compbuffer():get_or_create_buf()
            return buf
        end,
    }
    M.register_view("files", provider)
end

---Registers a new view provider.
---@param name string Unique identifier for the view.
---@param provider loop.ViewProvider The provider definition.
function M.register_view(name, provider)
    if not is_valid_id(name) then
        error(string.format("Invalid view ID: '%s'. IDs must only contain alphanumeric characters, '-', or '_'.", name))
    end
    assert(not _registry[name], string.format("View already registered: %s", name))
    _registry[name] = provider
end

---Returns a single view provider by ID.
---@param name string
---@return loop.ViewProvider|nil
function M.get_view(name)
    return _registry[name]
end

---Returns a list of view providers for a given list of IDs.
---Skips IDs that are not registered.
---@param ids string[]
---@return loop.ViewProvider[]
function M.get_views_by_ids(ids)
    local found = {}
    for _, name in ipairs(ids) do
        if _registry[name] then
            table.insert(found, _registry[name])
        end
    end
    return found
end

---Returns all registered view IDs (useful for tab completion).
---@return string[]
function M.get_all_ids()
    return vim.tbl_keys(_registry)
end

---Returns the full internal _registry.
---@return table<string, loop.ViewProvider>
function M.get_registry()
    return _registry
end

return M
