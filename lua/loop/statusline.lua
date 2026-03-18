local M = {}

local _init_done = false
local _workspace_name = nil

local function _init()
    local monitor = require("loop.workspacemonitor")
    monitor.add_tracker({
        on_open = function(wsdir, config)
            _workspace_name = config and config.name or nil
        end,
        on_config_change = function(wsdir, config)
            _workspace_name = config and config.name or nil
        end,
        on_close = function()
            _workspace_name = nil
        end
    })
end

---@return string
function M.status()
    if not _init_done then
        _init_done = true
        _init()
    end
    return _workspace_name and ("󰉖 " .. _workspace_name) or ""
end

return M
