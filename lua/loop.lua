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

---@class loop.Config.FileTree
---@field track_current_file loop.Config.FileTree.Track
---@field monitor_file_system boolean Watch for external OS file changes
---@field max_monitored_folders integer limit to prevent handle exhaustion

---@class loop.Config.FileTree.Track
---@field enabled boolean Focus the active buffer in the tree automatically
---@field auto_collapse_others boolean Collapse non-focused nodes when tracking

---@class loop.Config.WorkspaceFiles
---@field always_excluded_globs string[] List of patterns to ignore (e.g., .git/)
---@field include_data_dir boolean Whether to index the .loop directory itself

---@class loop.Config
---@field workspace_data_dir string
---@field statuspanel loop.Config.Window
---@field filetree loop.Config.FileTree
---@field files loop.Config.WorkspaceFiles
---@field debug boolean Enable debug/verbose mode for development
---@field state_autosave_interval integer Auto-save interval in minutes (default: 5)
---@field logs_count integer Number of recent logs to show (default: 50)

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
        filetree = {
            track_current_file = {
                enabled = true,
                auto_collapse_others = false,
            },
            monitor_file_system = true,
            max_monitored_folders = 100,
        },
        debug = false,
        state_autosave_interval = 5, -- 5 minutes
        logs_count = 50,             -- Number of recent logs to show
    }
end

---@type loop.Config
M.config = _get_default_config()

---@type table<string, (fun(ctx:loop.TaskContext, ...): any, string|nil)>
M.user_macros = {}

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

---@type function
function M.register_macro(name, fn)
    assert(type(name) == 'string' and name:match("[_%a][_%w]*") ~= nil,
    "Invalid macro name in register_macro(): " .. tostring(name))
    assert(type(fn) == "function", "Invalid macro function in register_macro()")
    M.user_macros[name] = fn
end

return M
