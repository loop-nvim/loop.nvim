-- IMPORTANT: keep this module light for lazy loading

local M = {}

-- IMPORTANT: keep this module light for lazy loading

---@class loop.Config.Window.Symbols
---@field change string
---@field success string
---@field failure string
---@field waiting string
---@field running string

---@class loop.Config.Window
---@field symbols loop.Config.Window.Symbols

---@class loop.Config.WorspaceFiles
---@field always_excluded_globs string[]
---@field include_data_dir boolean

---@class loop.Config
---@field workspace_data_dir string
---@field statuspanel loop.Config.Window
---@field files loop.Config.WorspaceFiles
---@field macros table<string,(fun(ctx:loop.TaskContext,...):any,string|nil)>
---@field debug boolean Enable debug/verbose mode for development
---@field state_autosave_interval integer Auto-save interval in minutes (default: 5 minutes).
---@field logs_count integer Number of recent logs to show with :Loop logs (default: 50).
---@field use_fd_find boolean

-- IMPORTANT: keep this module light for lazy loading

local function _get_default_config()
    ---@type loop.Config
    return {
        workspace_data_dir = ".loop",
        files = {
            always_excluded_globs = { ".git/", "node_modules/", ".cache/" },
            include_data_dir = false,
        },
        statuspanel = {
            symbols = {
                change  = "●",
                success = "✓",
                failure = "✗",
                waiting = "⧗",
                running = "▶",
            },
        },
        macros = {},
        debug = false,
        state_autosave_interval = 5, -- 5 minutes
        logs_count = 50,             -- Number of recent logs to show
        use_fd_find = false,
    }
end

---@type loop.Config
M.config = _get_default_config()

-----------------------------------------------------------
-- Setup (user config)
-----------------------------------------------------------

---@param opts loop.Config?
function M.setup(opts)
    if vim.fn.has("nvim-0.10") ~= 1 then
        error("loop.nvim requires Neovim >= 0.10")
    end

    M.config = vim.tbl_deep_extend("force", _get_default_config(), opts or {})
end

return M
