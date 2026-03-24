local Trackers = require('loop.utils.Trackers')

local M = {}
local _init_done = false

---@class loop.workspace.Tracker
---@field on_open fun (wsdir:string, config:loop.WorkspaceConfig|nil)
---@field on_close fun(wsdir:string)
---@field on_config_change fun(wsdir:string, config?:loop.WorkspaceConfig|nil)

local _current_wsdir, _current_wsconfig
local _trackers = Trackers:new()

---@param callbacks loop.workspace.Tracker
function M.add_tracker(callbacks)
    -- don't assert _init_done here, statusline may be invoked before init
    if _current_wsdir then
        if callbacks.on_open then
            callbacks.on_open(_current_wsdir, _current_wsconfig)
        end
    end
    return _trackers:add_tracker(callbacks)
end

---@return loop.workspace.Tracker
function M.init()
    assert(not _init_done)
    _init_done = true
    ---@type loop.workspace.Tracker
    return {
        on_open = function(wsdir, config)
            _current_wsdir = wsdir
            _current_wsconfig = config
            _trackers:invoke("on_open", wsdir, config)
        end,
        on_close = function(wsdir)
            _current_wsdir = nil
            _current_wsconfig = nil
            _trackers:invoke("on_close", wsdir)
        end,
        on_config_change = function(wsdir, config)
            _current_wsconfig = config
            _trackers:invoke("on_config_change", wsdir, config)
        end
    }
end

return M
