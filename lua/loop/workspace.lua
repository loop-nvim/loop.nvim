local M = {}

local logs = require('loop.logs')
local taskmgr = require("loop.task.taskmgr")
local variablesmgr = require("loop.task.variablesmgr")
local window = require("loop.ui.window")
local statusline = require("loop.statusline")
local runner = require("loop.task.runner")
local jsoncodec = require('loop.json.codec')
local jsonvalidator = require('loop.json.validator')
local filetools = require('loop.tools.file')
local wssaveutil = require('loop.ws.saveutil')
local floatwin = require('loop.tools.floatwin')
local selector = require('loop.tools.selector')
local extdata = require("loop.extdata")
local JsonEditor = require('loop.json.JsonEditor')

local _init_done = false
local _init_err_msg = "init() not called"


---@class loop.ws.WorkspaceInfo
---@field name string
---@field ws_dir string
---@field config_dir string
---@field config loop.WorkspaceConfig

---@type loop.ws.WorkspaceInfo?
local _workspace_info = nil

local _save_timer = nil

-- New: recent workspaces persistence
local MAX_RECENTS = 50

local function _get_recent_file()
    local data_dir = vim.fn.stdpath('data')
    return vim.fs.joinpath(data_dir, "loop", "recent_workspaces.json")
end

local function _load_recent_workspaces()
    local f = _get_recent_file()
    if not filetools.file_exists(f) then return {} end
    local ok, data_or_err = jsoncodec.load_from_file(f)
    if not ok or type(data_or_err) ~= "table" then return {} end
    return data_or_err
end

local function _save_recent_workspaces(list)
    local f = _get_recent_file()
    -- ensure parent dir exists
    local dir = vim.fn.fnamemodify(f, ":h")
    vim.fn.mkdir(dir, "p")
    jsoncodec.save_to_file(f, list)
end

local function _add_recent_workspace(dir)
    if not dir or dir == "" then return end
    dir = vim.fn.fnamemodify(dir, ":p")
    local list = _load_recent_workspaces()
    local seen = {}
    local newlist = { dir }
    seen[dir] = true
    for _, v in ipairs(list) do
        local p = vim.fn.fnamemodify(v, ":p")
        if not seen[p] then
            table.insert(newlist, p)
            seen[p] = true
        end
        if #newlist >= MAX_RECENTS then break end
    end
    _save_recent_workspaces(newlist)
end

---@return loop.ws.WorkspaceInfo?
local function _get_ws_info_or_warn()
    if not _workspace_info then
        vim.notify("No active workspace", vim.log.levels.WARN)
        return
    end
    return _workspace_info
end

local function _get_config_dir(workspace_dir)
    local dir = vim.fs.joinpath(workspace_dir, ".nvimloop")
    return dir
end

local function _save_workspace()
    if not _workspace_info then
        return false
    end
    assert(_init_done, _init_err_msg)
    window.save_settings(_workspace_info.config_dir)
    extdata.save(_workspace_info)
    return true
end

---@param quiet? boolean
local function _close_workspace(quiet)
    if not _workspace_info then
        return false
    end

    runner.terminate_tasks()

    _save_workspace()

    extdata.on_workspace_unload(_workspace_info)
    runner.on_workspace_close()

    if not quiet and _workspace_info then
        local label = _workspace_info.name or _workspace_info.ws_dir
        logs.user_log("Workspace closed: " .. label, "workspace")
        vim.notify("Workspace closed")
    end
    _workspace_info = nil
    statusline.set_workspace_name(nil)
end

---@param ws_dir string
local function _configure_workspace(ws_dir)
    local config_dir = _get_config_dir(ws_dir)
    local schema = require('loop.ws.schema')
    local filepath = vim.fs.joinpath(config_dir, "workspace.json")

    if not filetools.file_exists(filepath) then
        local schema_filepath = vim.fs.joinpath(config_dir, 'wsschema.json')
        if not filetools.file_exists(schema_filepath) then
            jsoncodec.save_to_file(schema_filepath, schema)
        end
        local data = {}
        data["$schema"] = './wsschema.json'
        data["workspace"] = vim.fn.deepcopy(require('loop.ws.template'))
        data["workspace"].name = vim.fn.fnamemodify(ws_dir, ":p:h:t")
        jsoncodec.save_to_file(filepath, data)
    end

    local editor = JsonEditor:new({
        name = "Workspace configuration",
        filepath = filepath,
        schema = schema,
    })

    editor:open()
end

---@param config_dir string
---@return loop.WorkspaceConfig?,string?
local function _load_workspace_config(config_dir)
    local config_file = vim.fs.joinpath(config_dir, "workspace.json")
    if not filetools.file_exists(config_file) then
        return nil, "workspace.json not found"
    end
    local loaded, data_or_err = jsoncodec.load_from_file(config_file)
    if not loaded then
        ---@cast data_or_err string
        return nil, data_or_err
    end
    local config = data_or_err
    local schema = require('loop.ws.schema')
    local errors = jsonvalidator.validate(schema, config)
    if errors then
        return nil, jsonvalidator.errors_to_string(errors)
    end
    return config.workspace
end

---@param dir string
---@return boolean
---@return string|nil
local function _load_workspace(dir)
    assert(_init_done, _init_err_msg)
    assert(type(dir) == 'string')

    dir = vim.fn.fnamemodify(dir, ":p")

    local config_dir = _get_config_dir(dir)
    if not filetools.dir_exists(config_dir) then
        return false, "No workspace in " .. dir
    end

    local ws_config, config_errors = _load_workspace_config(config_dir)
    if not ws_config then
        logs.log(config_errors or "unknown error", vim.log.levels.ERROR)
        return false, "Failed to load workspace configuration (:Loop logs for details)"
    end

    local loopconfig = require('loop.config')
    ---@type loop.ws.WorkspaceInfo
    _workspace_info = {
        name = ws_config.name,
        ws_dir = dir,
        config_dir = config_dir,
        config = ws_config,
    }
    if not _workspace_info.name or _workspace_info.name == "" then
        _workspace_info.name = vim.fn.fnamemodify(dir, ":p:h:t")
    end

    statusline.set_workspace_name(_workspace_info.name)

    window.load_settings(config_dir)

    local page_manager_fact = window.get_page_manager_factory()
    taskmgr.reset_provider_list(dir, page_manager_fact)
    runner.on_workspace_open(_workspace_info, page_manager_fact)
    extdata.on_workspace_load(_workspace_info, page_manager_fact)

    if not _save_timer then
        local config = require('loop.config')
        local save_interval = (config.current.autosave_interval or 5) * 60 * 1000

        if save_interval > 0 then
            -- Create and start the repeating timer
            ---@diagnostic disable-next-line: undefined-field
            _save_timer = vim.loop.new_timer()
            _save_timer:start(
                save_interval, -- initial delay
                save_interval, -- frequency
                vim.schedule_wrap(_save_workspace)
            )
        end
    end

    return true, nil
end

local function _show_workspace_info_floatwin()
    if not _workspace_info then
        vim.notify("No active workspace")
        return
    end
    local info = _workspace_info
    local save_config = vim.fn.copy(info.config.save)
    local schema = require('loop.ws.schema')
    ---@diagnostic disable-next-line: inject-field
    local str = ("Name: %s\nDirectory: %s\nFiles:\n%s"):format(info.name, info.ws_dir,
        jsoncodec.to_string(save_config, schema))
    floatwin.show_floatwin(str, { title = "Workspace" })
end

---@param dir string?
function M.create_workspace(dir)
    assert(_init_done, _init_err_msg)

    dir = dir or vim.fn.getcwd()
    local config_dir = _get_config_dir(dir)

    assert(type(dir) == 'string')
    assert(type(config_dir) == 'string')
    local config_file = vim.fs.joinpath(config_dir, "workspace.json")

    if filetools.dir_exists(config_dir) and filetools.file_exists(config_file) then
        vim.notify("A workspace already exists in " .. dir, vim.log.levels.ERROR)
        return
    end

    -- Ask user to confirm creation and show the target directory
    local msg = "Create workspace in:\n" .. tostring(dir) .. "\n\nProceed?"
    local choice = vim.fn.confirm(msg, "&Yes\n&No", 2)
    if choice ~= 1 then
        vim.notify("Workspace creation cancelled")
        return false
    end

    -- important check because the user may pass garbage data
    if not filetools.dir_exists(dir) then
        vim.notify("Invalid directory " .. tostring(dir), vim.log.levels.ERROR)
        return
    end

    vim.fn.mkdir(config_dir, "p")

    local ws_name = vim.fn.fnamemodify(dir, ":p:h:t")
    logs.user_log("Workspace created: " .. ws_name, "workspace")

    _configure_workspace(dir)
end

---@param dir string?
---@param at_startup boolean
function M.open_workspace(dir, at_startup)
    assert(_init_done, _init_err_msg)

    -- If no dir provided, present recent workspaces via selector
    if not dir or dir == "" then
        local cwd = vim.fn.getcwd()
        local candidates = _load_recent_workspaces()

        -- If cwd is a workspace, ensure it's first
        local cwd_config_dir = _get_config_dir(cwd)
        if filetools.dir_exists(cwd_config_dir) then
            table.insert(candidates, 1, cwd)
        end

        -- Deduplicate and normalize
        local seen = {}
        local uniq = {}
        for _, p in ipairs(candidates) do
            if p and p ~= "" then
                local np = vim.fn.fnamemodify(p, ":p")
                if not seen[np] then
                    seen[np] = true
                    table.insert(uniq, np)
                end
            end
        end

        if #uniq == 0 then
            vim.notify("No recent workspaces found")
            return
        end

        local items = {}
        for _, path in ipairs(uniq) do
            local label = vim.fn.fnamemodify(path, ":t") .. " — " .. path
            table.insert(items, { label = label, data = path })
        end

        selector.select({
            prompt = "Open workspace",
            items = items,
            callback = function(choice)
                if choice then
                    -- async open of selected workspace
                    M.open_workspace(choice, false)
                end
            end
        })
        return
    end

    dir = dir or vim.fn.getcwd()
    local ok, err_msg = _load_workspace(dir)
    if ok and _workspace_info then
        -- add to recent list (MRU)
        _add_recent_workspace(dir)

        local label = _workspace_info.name
        if not label or label == "" then label = _workspace_info.ws_dir end
        logs.user_log("Workspace opened: " .. label, "workspace")
        if not at_startup then
            vim.notify("Workspace opened: " .. label)
        end
    else
        if not at_startup and err_msg then
            vim.notify(err_msg, vim.log.levels.ERROR)
        end
        logs.user_log("Workspace not loaded, " .. err_msg, "workspace")
    end
end

function M.configure_workspace()
    if not _workspace_info then
        vim.notify("No active workspace", vim.log.levels.WARN)
        return
    end
    _configure_workspace(_workspace_info.ws_dir)
end

---@return string[]
function M.get_commands()
    local cmds = { "workspace", "log", "ui", "page" }
    if _workspace_info then
        vim.list_extend(cmds, { "task", "var" })
        vim.list_extend(cmds, extdata.lead_commands())
    end
    return cmds
end

---@param cmd string
---@param rest string[]
---@param opts vim.api.keyset.create_user_command.command_args
function M.run_command(cmd, rest, opts)
    if cmd == "workspace" then
        M.workspace_command(unpack(rest))
    elseif cmd == "ui" then
        M.ui_command(unpack(rest))
    elseif cmd == "page" then
        M.page_command(unpack(rest))
    elseif cmd == "task" then
        M.task_command(unpack(rest))
    elseif cmd == "var" then
        M.var_command(unpack(rest))
    elseif cmd == "log" then
        M.logs_command()
    else
        local provider = extdata.get_cmd_provider(cmd)
        if provider then
            provider.dispatch(rest, opts)
        else
            vim.notify("Invalid command: " .. tostring(cmd))
        end
    end
end

---@param cmd string
---@param rest string[]
---@return string[]
function M.get_subcommands(cmd, rest)
    if cmd == "task" then
        return M.task_subcommands(rest)
    elseif cmd == "workspace" then
        return M.workspace_subcommands(rest)
    elseif cmd == "ui" then
        return M.ui_subcommands(rest)
    elseif cmd == "page" then
        return M.page_subcommands(rest)
    elseif cmd == "var" then
        return M.var_subcommands(rest)
    else
        local provider = extdata.get_cmd_provider(cmd)
        if provider then
            return provider.get_subcommands(rest)
        end
    end
    return {}
end

---@param args string[]
---@return string[]
function M.workspace_subcommands(args)
    if #args == 0 then
        return { "info", "create", "open", "configure", "save" }
    end
    return {}
end

---@param command string|nil
function M.workspace_command(command)
    if not command or command == "" or command == "info" then
        _show_workspace_info_floatwin()
        return
    end
    if command == "create" then
        M.create_workspace()
        return
    end
    if command == "open" then
        M.open_workspace(nil, false)
        return
    end
    if command == "configure" then
        M.configure_workspace()
        return
    end
    if command == "save" then
        M.save_workspace_buffers()
        return
    end
    vim.notify("Invalid command: " .. command)
end

---@param args string[]
---@return string[]
function M.task_subcommands(args)
    if #args == 0 then
        return { "run", "repeat", "terminate", "configure" }
    end
    return {}
end

---@param command string|nil
---@param arg1 string
---@param arg2? string|nil
function M.task_command(command, arg1, arg2)
    assert(_init_done, _init_err_msg)
    local ws_info = _get_ws_info_or_warn()
    if not ws_info then
        return
    end

    command = command and command:match("^%s*(.-)%s*$") or ""
    command = command ~= "" and command or "run"
    local config_dir = ws_info.config_dir
    if command == "run" then
        window.show_window()
        runner.load_and_run_task("task", arg1)
    elseif command == "repeat" then
        window.show_window()
        runner.load_and_run_task("repeat")
    elseif command == "configure" then
        taskmgr.configure_tasks(config_dir)
    elseif command == "terminate" then
        runner.terminate_tasks()
    else
        vim.notify('Invalid task command: ' .. command)
    end
end

---@param args string[]
---@return string[]
function M.var_subcommands(args)
    if #args == 0 then
        return { "list", "configure" }
    end
    return {}
end

---@param command string|nil
function M.var_command(command)
    assert(_init_done, _init_err_msg)
    local ws_info = _get_ws_info_or_warn()
    if not ws_info then
        return
    end

    command = command and command:match("^%s*(.-)%s*$") or ""
    if command == "" then
        command = "list"
    end

    local config_dir = ws_info.config_dir
    if command == "list" then
        variablesmgr.show_variables(config_dir)
    elseif command == "configure" then
        variablesmgr.configure_variables(config_dir)
    else
        vim.notify('Invalid var command: ' .. command)
    end
end

function M.ui_subcommands(args)
    if #args == 0 then
        return { "toggle", "show", "hide" }
    end
    return {}
end

function M.page_subcommands(args)
    if #args == 0 then
        return { "switch", "open" }
    end
    if #args == 1 and (args[1] == "open" or args[1] == "switch") then
        local names = window.get_pagegroup_names()
        return vim.tbl_map(vim.fn.fnameescape, names)
    end
    if #args == 2 and (args[1] == "open" or args[1] == "switch") then
        local group = args[2]
        local names = window.get_page_names(group)
        return vim.tbl_map(vim.fn.fnameescape, names)
    end
    return {}
end

function M.page_command(command, arg1, arg2)
    if not command or command == "" or command == "switch" then
        M.switch_page(arg1, arg2)
    elseif command == "open" then
        M.open_page(arg1, arg2)
    else
        vim.notify("Invalid command: " .. command)
    end
end

function M.ui_command(command)
    if not command or command == "toggle" then
        M.toggle_window()
    elseif command == "show" then
        M.show_window()
    elseif command == "hide" then
        M.hide_window()
    else
        vim.notify("Invalid command: " .. command)
    end
end

function M.show_window()
    assert(_init_done, _init_err_msg)
    window.show_window()
end

function M.hide_window()
    assert(_init_done, _init_err_msg)
    window.hide_window()
end

function M.toggle_window()
    assert(_init_done, _init_err_msg)
    window.toggle_window()
end

function M.switch_page(group_label, page_label)
    assert(_init_done, _init_err_msg)
    window.open_page(nil, group_label, page_label)
end

---@param group_label string|nil
---@param page_label string|nil
function M.open_page(group_label, page_label)
    assert(_init_done, _init_err_msg)
    window.open_page(vim.api.nvim_get_current_win(), group_label, page_label)
end

function M.logs_command()
    assert(_init_done, _init_err_msg)
    logs.show_logs()
end

function M.save_workspace_buffers()
    local ws_info = _get_ws_info_or_warn()
    if not ws_info then return 0 end
    return wssaveutil.save_workspace_buffers(ws_info)
end

function M.winbar_click(id, clicks, button, mods)
    assert(_init_done, _init_err_msg)
    window.winbar_click(id, clicks, button, mods)
end

function M.init()
    assert(not _init_done, "init already done")
    _init_done = true

    window.init()

    vim.api.nvim_create_autocmd("VimLeavePre", {
        callback = function()
            -- Stop the timer if it's still running
            if _save_timer and _save_timer:is_active() then
                _save_timer:stop()
                _save_timer:close()
            end

            if runner.have_running_task() then
                runner.terminate_tasks()
                local max_waits = 100 -- 10 seconds max
                while max_waits > 0 and runner.have_running_task() do
                    max_waits = max_waits - 1
                    vim.wait(100)
                end
            end

            _close_workspace(true)
        end,
    })
end

return M
