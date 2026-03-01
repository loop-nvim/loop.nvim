---@class loop.Config.Window.Symbols
---@field change string
---@field success string
---@field failure string
---@field waiting string
---@field running string

---@class loop.Config.Window
---@field symbols loop.Config.Window.Symbols

---@class window loop.Config.Window
---@class loop.Config
---@field window loop.Config.Window?
---@field macros table<string,(fun(ctx:loop.TaskContext,...):any,string|nil)>?
---@field debug boolean? Enable debug/verbose mode for development
---@field autosave_interval integer? Auto-save interval in minutes (default: 5 minutes).
---@field logs_count integer? Number of recent logs to show with :Loop logs (default: 50).

local M = {}

---@type loop.Config|nil
M.current = nil

return M
