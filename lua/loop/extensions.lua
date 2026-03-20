-- IMPORTANT: keep this module light for lazy loading
local M = {}

---@type table<string,string>
local _ext_registry = {}

---@return string[]
function M.ext_names()
    return vim.tbl_keys(_ext_registry)
end

---@class loop.ExtensionOpts
---@field name string
---@field module string

---@param opts loop.ExtensionOpts
function M.register_extension(opts)
    assert(type(opts.module) == 'string' and opts.module:match("^[%w_.-][%w_.-]*$") ~= nil,
        "Invalid extension module: " .. tostring(opts.module))

    assert(type(opts.name) == 'string' and opts.name:match("[_%a][_%w]*") ~= nil,
        "Invalid extension name: " .. tostring(opts.name))
    assert(#opts.name >= 2, "ext name too short: " .. opts.name)
    assert(not _ext_registry[opts.name], "extension name already registered: " .. opts.name)

    _ext_registry[opts.name] = opts.module
end

---@param modname string
---@return loop.Extension|nil
local function _get_extension(modname)
    local m = package.loaded[modname]
    if m then return m end

    -- Do not attempt to load modules during shutdown
    if vim.v.exiting ~= vim.NIL then return nil end

    local ok, res = pcall(require, modname)
    if not ok then
        error(string.format("[loop.nvim] Failed to load extension: %s\n%s", modname, res), vim.log.levels.ERROR)
        return nil
    end
    return res
end

---@param name string
---@return loop.Extension|nil
function M.get_extension(name)
    local modname = _ext_registry[name]
    return modname and _get_extension(modname) or nil
end

return M
