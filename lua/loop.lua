-- lua/loop/init.lua
local strtools = require('loop.tools.strtools')

local M = {}

-- Dependencies
local workspace = require("loop.workspace")
local config = require("loop.config")

-----------------------------------------------------------
-- Defaults
-----------------------------------------------------------

---@type loop.Config
local DEFAULT_CONFIG = {
    selector = "builtin",
    window = {
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
    autosave_interval = 5, -- 5 minutes
    logs_count = 50,       -- Number of recent logs to show
}

-----------------------------------------------------------
-- State
-----------------------------------------------------------

local setup_done = false
local initialized = false

-----------------------------------------------------------
-- Setup (user config only)
-----------------------------------------------------------

---@param opts loop.Config?
function M.setup(opts)
    if vim.fn.has("nvim-0.10") ~= 1 then
        error("loop.nvim requires Neovim >= 0.10")
    end

    config.current = vim.tbl_deep_extend("force", DEFAULT_CONFIG, opts or {})
    setup_done = true

    M.init()
end

-----------------------------------------------------------
-- Command completion
-----------------------------------------------------------

function M.complete(arg_lead, cmd_line)
    M.init()

    local function filter(strs)
        local out = {}
        for _, s in ipairs(strs or {}) do
            if not vim.startswith(s, '_') and vim.startswith(s, arg_lead) then
                table.insert(out, s)
            end
        end
        return out
    end

    local args = strtools.split_shell_args(cmd_line)
    if cmd_line:match("%s+$") then
        table.insert(args, ' ')
    end

    if #args == 2 then
        return filter(workspace.get_commands())
    elseif #args >= 3 then
        local cmd = args[2]
        local rest = { unpack(args, 3) }
        rest[#rest] = nil
            return filter(workspace.get_subcommands(cmd, rest))
    end
    return {}
end
---@param prefix string[]   -- e.g. { "task" }
---@param out loop.tools.Cmd[]
local function _collect_commands(prefix, out)
    local cmds = workspace.get_subcommands(prefix[1], { unpack(prefix, 2) })

    for _, cmd in ipairs(cmds or {}) do
        local parts = vim.list_extend(vim.deepcopy(prefix), { cmd })
        local vimcmd = "Loop " .. table.concat(parts, " ")

        table.insert(out, {
            vimcmd = vimcmd,
        })

        -- recurse to catch deeper subcommands
        _collect_commands(parts, out)
    end
end

function M.select_command()
    M.init()

    ---@type loop.tools.Cmd[]
    local all_cmds = {}

    -- Top-level commands
    for _, cmd in ipairs(workspace.get_commands()) do
        local vimcmd = "Loop " .. cmd

        table.insert(all_cmds, {
            vimcmd = vimcmd,
        })

        -- Subcommands (recursive)
        _collect_commands({ cmd }, all_cmds)
    end

    require("loop.tools.cmdmenu").select_and_run_command(all_cmds)
end

-----------------------------------------------------------
-- Dispatcher
-----------------------------------------------------------

---@param opts vim.api.keyset.create_user_command.command_args
function M.dispatch(opts)
    M.init()

    local args = strtools.split_shell_args(opts.args)
    local subcmd = args[1]

    if not subcmd or subcmd == "" then
        M.select_command()
        return
    end
    local rest = { unpack(args, 2) }
    local ok, err = pcall(workspace.run_command, subcmd, rest, opts)
    if not ok then
        vim.notify(
            "Loop " .. subcmd .. " failed: " .. tostring(err),
            vim.log.levels.ERROR
        )
    end
end

-----------------------------------------------------------
-- Initialization (runs once)
-----------------------------------------------------------

function M.init()
    if initialized then
        return
    end
    initialized = true

    -- Apply defaults if setup() was never called
    if not setup_done then
        config.current = DEFAULT_CONFIG
    end

    workspace.init()

    _G._LoopPluginGlobalState = {}
    _G._LoopPluginGlobalState.wbc = workspace.winbar_click
end

function M.load_workspace(dir)
    M.init()
    workspace.open_workspace(dir, true)
end

return M
