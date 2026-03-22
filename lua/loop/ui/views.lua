local M = {}

---@class loop.ext.ViewInfo
---@field name string
---@field provider loop.ViewProvider

---@type table<number, loop.ext.ViewInfo>
local _registry = {}

local _next_view_id = 1

---Validates that the ID contains only alphanumeric characters, hyphens, or underscores.
---@param name string
---@return boolean
local function is_valid_name(name)
    return name:match("^[a-zA-Z0-9%-_]+$") ~= nil
end

function M.clear_views()
    _registry = {}
end

---Registers a new view provider.
---@param name string Unique identifier for the view.
---@param provider loop.ViewProvider The provider definition.
---@return number view_id
function M.register_view(name, provider)
    if not is_valid_name(name) then
        error(string.format("Invalid view name: '%s'. IDs must only contain alphanumeric characters, '-', or '_'.", name))
    end
    assert(not _registry[name], string.format("View already registered: %s", name))
    assert(type(provider) == "table")
    local view_id = _next_view_id
    _next_view_id = _next_view_id + 1
    _registry[view_id] = {
        name = name,
        provider = provider,
    }
    return view_id
end

---Returns a single view provider by ID.
---@return number[]
function M.get_view_ids()
    return vim.tbl_keys(_registry)
end

---Returns a single view provider by ID.
---@return loop.ext.ViewInfo[]
function M.get_views()
    local views = vim.tbl_values(_registry)
    table.sort(views, function(a, b) return a.name < b.name end)
    return views
end

---@param id number
---@return loop.ext.ViewInfo?
function M.get_view_info(id)
    local info = _registry[id]
    if not info then return end
    return {
        name = info.name,
        provider = info.provider,
    }
end

return M
