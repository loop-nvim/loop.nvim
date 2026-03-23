local M             = {}

local loopconfig    = require("loop").config
local log           = require('loop.log')
local taskmgr       = require("loop.task.taskmgr")
local variablesmgr  = require("loop.task.variablesmgr")
local statuspanel   = require("loop.ui.statuspanel")
local runner        = require("loop.task.runner")
local jsoncodec     = require('loop.json.codec')
local jsonvalidator = require('loop.json.validator')
local filetools     = require('loop.tools.file')
local flock         = require('loop.tools.flock')
local fntools       = require('loop.tools.fntools')
local wssaveutil    = require('loop.ws.saveutil')
local floatwin      = require('loop.tools.floatwin')
local selector      = require('loop.tools.selector')
local extensionsmgr = require("loop.extensionsmgr")
local JsonEditor    = require('loop.json.JsonEditor')
local views         = require('loop.ui.views')
local sidebar       = require("loop.ui.sidebar")

local _init_done    = false

---@class loop.ws.WorkspaceInfo
---@field ws_dir string
---@field config_dir string

---@class loop.ws.WorkspaceData
---@field ws_dir string
---@field config_dir string
---@field page_manager loop.PageManager
---@field cancel_save_timer fun()?

---@type loop.ws.WorkspaceData?
local _ws_data      = nil

---@type loop.workspace.Tracker
local _monitor      = require("loop.workspacemonitor").init()

-- New: recent workspaces persistence
local MAX_RECENTS   = 50
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

local function _notify_no_ws()
    vim.notify("No active workspace", vim.log.levels.WARN)
end

local function _get_config_dir(workspace_dir)
    local dir = vim.fs.joinpath(workspace_dir, loopconfig.workspace_data_dir)
    return dir
end

local function _save_workspace()
    if not _ws_data then
        return false
    end
    extensionsmgr.on_save(_ws_data.config_dir)
    return true
end

---@param quiet? boolean
local function _close_workspace(quiet)
    if runner.have_running_tasks() then
        runner.terminate_tasks()
        local max_waits = 100 -- 10 seconds max
        while max_waits > 0 and runner.have_running_tasks() do
            max_waits = max_waits - 1
            vim.wait(100)
        end
    end

    taskmgr.clear_providers()

    if _ws_data then
        if _ws_data.cancel_save_timer then _ws_data.cancel_save_timer() end

        _save_workspace()

        extensionsmgr.on_workspace_unload()
        runner.on_workspace_close()
        views.clear_views()
        sidebar.on_workspace_close()
        statuspanel.hide_window()

        if _ws_data.page_manager then
            _ws_data.page_manager.delete_groups()
            _ws_data.page_manager.expire(true)
        end

        local lockfile_path = vim.fs.joinpath(_ws_data.config_dir, "wslock")
        flock.unlock(lockfile_path)

        if not quiet then
            log.user_log("Workspace closed", "workspace")
            vim.notify("Workspace closed")
        end

        _monitor.on_close(_ws_data.ws_dir)
    end

    _ws_data = nil
end

---@param ws_dir string
---@return loop.WorkspaceConfig?,string?
local function _load_workspace_config(ws_dir)
    local config_dir = _get_config_dir(ws_dir)
    local config_file = vim.fs.joinpath(config_dir, "workspace.json")
    if not filetools.file_exists(config_file) then
        return nil, "workspace.json not found"
    end
    local loaded, data_or_err = jsoncodec.load_from_file(config_file)
    if not loaded then
        ---@cast data_or_err string
        return nil, data_or_err
    end
    local config_node = data_or_err
    local schema = require('loop.ws.schema')
    local valid, errors = jsonvalidator.validate(schema, config_node)
    if not valid then
        return nil, jsonvalidator.errors_to_string(errors)
    end
    ---@type loop.WorkspaceConfig
    local ws_config = config_node.workspace
    if not ws_config or not ws_config.files or not ws_config.files.exclude then
        return nil, "Invalid workspace configuration"
    end
    -- add default exclude globs
    local default_excludes = vim.fn.copy(loopconfig.files.always_excluded_globs)
    if not loopconfig.files.include_data_dir then
        local wsdir_pattern = loopconfig.workspace_data_dir
        -- ensure trailing slash
        if wsdir_pattern:sub(-1) ~= "/" then
            wsdir_pattern = wsdir_pattern .. "/"
        end
        table.insert(default_excludes, wsdir_pattern)
    end
    local exclude_globs = ws_config.files.exclude
    for _, glob in ipairs(default_excludes) do
        if not vim.tbl_contains(exclude_globs, glob) then
            table.insert(exclude_globs, glob)
        end
    end
    return ws_config
end

---@param ws_dir string
---@return string,table
local function _get_or_create_ws_config_file(ws_dir)
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
    return filepath, schema
end

local function _configure_workspace()
    if not _ws_data then return end
    local ws_dir = _ws_data.ws_dir
    local filepath, schema = _get_or_create_ws_config_file(ws_dir)
    local existing_editor = JsonEditor.get_existing(filepath)
    if existing_editor then
        existing_editor:open()
        return
    end
    local editor = JsonEditor:new({
        name = "Workspace configuration",
        filepath = filepath,
        schema = schema,
    })
    editor:set_on_save_handler(function()
        -- ensure workspace was not changed/closed
        if _ws_data and ws_dir == _ws_data.ws_dir then
            local config = _load_workspace_config(ws_dir)
            local configcopy = config and vim.fn.deepcopy(config) or nil
            _monitor.on_config_change(ws_dir, configcopy)
        end
    end)
    editor:open()
end

---@param dir string
---@return "ok"|"no_ws"|"locked"|"unexpected"
---@return string? error_msg
local function _load_workspace(dir)
    assert(type(dir) == 'string')

    dir = vim.fn.fnamemodify(dir, ":p")

    local config_dir = _get_config_dir(dir)
    if not filetools.dir_exists(config_dir) then
        return "no_ws"
    end

    local lockfile_path = vim.fs.joinpath(config_dir, "wslock")
    do
        local locked, err = flock.lock(lockfile_path)
        if not locked then
            if err then
                return "unexpected", "lock error (" .. tostring(err) .. ")"
            else
                return "locked"
            end
        end
    end

    ---@type loop.ws.WorkspaceData
    _ws_data = {
        ws_dir = dir,
        config_dir = config_dir,
        page_manager = statuspanel.create_page_manager(),
    }

    ---@type loop.ws.WorkspaceInfo
    local ws_info = {
        ws_dir = _ws_data.ws_dir,
        config_dir = _ws_data.config_dir,
    }

    -- resets must be before extentions are loaded
    taskmgr.reset_providers(dir)
    sidebar.on_workspace_open()
    -- init task runner
    runner.on_workspace_open(ws_info, _ws_data.page_manager)
    -- load extensions
    extensionsmgr.on_workspace_load(ws_info, _ws_data.page_manager)

    assert(not _ws_data.cancel_save_timer)
    local save_interval = (loopconfig.state_autosave_interval or 5) * 60 * 1000
    if save_interval > 0 then
        _ws_data.cancel_save_timer = fntools.start_timer(save_interval, vim.schedule_wrap(_save_workspace))
    end

    -- notify trackers
    local ws_config = _load_workspace_config(dir)
    _monitor.on_open(dir, ws_config)

    return "ok", nil
end

local function _show_workspace_info_floatwin()
    if not _ws_data then
        vim.notify("No active workspace")
        return
    end
    local ws_config, _ = _load_workspace_config(_ws_data.ws_dir)
    if not ws_config then
        vim.notify("Invalid workspace configuration")
        return
    end
    local schema = require('loop.ws.schema')
    ---@diagnostic disable-next-line: inject-field
    local str = ("Directory:\n%s\n\nSettings:\n%s"):format(_ws_data.ws_dir,
        jsoncodec.to_string(ws_config, schema.properties.workspace))
    floatwin.show_floatwin(str, { title = "Workspace" })
end

---@param mode "task"|"repeat"
---@param task_name string|nil
local function _load_and_run_task(mode, task_name)
    assert(_ws_data)
    local config_dir = _ws_data.config_dir

    taskmgr.get_or_select_task(config_dir, mode, task_name, function(root_name, all_tasks)
        if not root_name or not all_tasks then
            return
        end
        taskmgr.save_last_task_name(root_name, config_dir)
        statuspanel.show_window()
        runner.run_task_with_deps(all_tasks, root_name)
    end)
end


local function _ensure_init()
    if _init_done then return end
    _init_done = true

    assert(not _G._LoopPluginGlobalState)
    _G._LoopPluginGlobalState = {}
    _G._LoopPluginGlobalState.wbc = statuspanel.winbar_click

    statuspanel.init()

    runner.set_status_handler(function(nb_waiting, nb_running)
        local symbols = loopconfig.statuspanel.symbols
        local parts = {}
        if nb_waiting > 0 then
            table.insert(parts, ("%s %d"):format(symbols.waiting, nb_waiting))
        end

        if nb_running > 0 then
            table.insert(parts, ("%s %d"):format(symbols.running, nb_running))
        end
        statuspanel.set_status_text(table.concat(parts, " "))
    end)

    vim.api.nvim_create_autocmd("VimLeavePre", {
        callback = function()
            _close_workspace(true)
        end,
    })
end

----------------- PUBLIC FUNCTIONS -----------------

---@param dir string?
function M.create_workspace(dir)
    _ensure_init()

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

    _get_or_create_ws_config_file(dir)

    _load_workspace(dir)

    log.user_log("Workspace created in " .. dir, "workspace")

    -- open configuration
    vim.schedule(function()
        _configure_workspace()
    end)
end

---@param dir string?
---@param at_startup boolean
function M.open_workspace(dir, at_startup)
    _ensure_init()

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
                items = items
            },
            function(choice)
                if choice then
                    -- async open of selected workspace
                    M.open_workspace(choice, false)
                end
            end
        )
        return
    end

    dir = dir or vim.fn.getcwd()
    if _ws_data and dir == _ws_data.ws_dir then
        vim.notify("Workspace already open")
        return
    end

    _close_workspace()

    local status, err_msg = _load_workspace(dir)
    if status == "ok" and _ws_data then
        -- add to recent list (MRU)
        _add_recent_workspace(dir)
        log.user_log("Workspace opened: " .. dir, "workspace")
        if not at_startup then
            vim.notify("Workspace opened: " .. dir)
        end
    else
        if err_msg then
            log.user_log("Failed to load workspace - " .. tostring(err_msg), "workspace")
        end
        if not at_startup then
            local ui_msg
            if status == "no_ws" then
                ui_msg = "No workspace in " .. dir
            elseif status == "locked" then
                ui_msg = "Workspace open in another instance"
            elseif status == "badconfig" then
                ui_msg = "Workspace configuration error"
            else
                ui_msg = "Workspace not loaded (:Loop log for details)"
            end
            vim.notify(ui_msg, vim.log.levels.ERROR)
            if status == "badconfig" then
                _configure_workspace()
            end
        end
    end
end

function M.close_workspace()
    _ensure_init()
    _close_workspace()
end

function M.configure_workspace()
    _ensure_init()
    if not _ws_data then
        _notify_no_ws()
        return
    end
    _configure_workspace()
end

---@return string[]
function M.get_commands()
    _ensure_init()
    local cmds = { "workspace" }
    if _ws_data and sidebar.have_views() then
        table.insert(cmds, "sidebar")
    end
    if _ws_data then
        vim.list_extend(cmds, { "statuspanel", "page" })
    end
    if _ws_data then
        vim.list_extend(cmds, { "task", "var" })
        vim.list_extend(cmds, extensionsmgr.lead_commands())
    end
    table.insert(cmds, "log")
    return cmds
end

---@param cmd string
---@param rest string[]
---@param opts vim.api.keyset.create_user_command.command_args
function M.run_command(cmd, rest, opts)
    _ensure_init()
    if cmd == "workspace" then
        M.workspace_command(unpack(rest))
    elseif cmd == "statuspanel" then
        M.statuspanel_command(unpack(rest))
    elseif cmd == "sidebar" then
        M.sidebar_command(unpack(rest))
    elseif cmd == "page" then
        M.page_command(unpack(rest))
    elseif cmd == "task" then
        M.task_command(unpack(rest))
    elseif cmd == "var" then
        M.var_command(unpack(rest))
    elseif cmd == "log" then
        M.logs_command()
    else
        local provider = extensionsmgr.get_cmd_provider(cmd)
        if provider then
            provider.dispatch(rest, opts)
        elseif not _ws_data then
            _notify_no_ws()
        else
            vim.notify("Invalid command: " .. tostring(cmd))
        end
    end
end

---@param cmd string
---@param rest string[]
---@param for_cmd_menu boolean?
---@return string[]
function M.get_subcommands(cmd, rest, for_cmd_menu)
    _ensure_init()
    if cmd == "task" then
        return M.task_subcommands(rest)
    elseif cmd == "workspace" then
        return M.workspace_subcommands(rest)
    elseif cmd == "statuspanel" then
        return M.statuspanel_subcommands(rest)
    elseif cmd == "sidebar" then
        return M.sidebar_subcommands(rest)
    elseif cmd == "page" then
        return M.page_subcommands(rest, for_cmd_menu)
    elseif cmd == "var" then
        return M.var_subcommands(rest)
    else
        local provider = extensionsmgr.get_cmd_provider(cmd)
        if provider then
            return provider.get_subcommands(rest)
        end
    end
    return {}
end

---@param args string[]
---@return string[]
function M.workspace_subcommands(args)
    _ensure_init()
    if #args == 0 then
        if _ws_data then
            return { "info", "create", "open", "close", "configure", "save", "find_files", "grep_files" }
        else
            return { "create", "open" }
        end
    end
    return {}
end

---@param command string|nil
function M.workspace_command(command)
    _ensure_init()
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
    if command == "close" then
        M.close_workspace()
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
    if command == "find_files" then
        M.find_workspace_files()
        return
    end
    if command == "grep_files" then
        M.grep_workspace_files()
        return
    end
    vim.notify("Invalid command: " .. command)
end

---@param args string[]
---@return string[]
function M.task_subcommands(args)
    _ensure_init()
    if #args == 0 then
        return { "run", "repeat", "terminate", "terminate_all", "configure" }
    end
    return {}
end

local function _select_and_terminate_task()
    local active_tasks = runner.get_active_tasks()
    if #active_tasks == 0 then return end
    local choices = {}
    for _, data in ipairs(active_tasks) do
        local virt_lines
        if data.root ~= data.name then
            virt_lines = { { { ("Triggered by `%s`"):format(data.root), "Comment" }, } }
        end
        ---@type loop.SelectorItem
        local choice = {
            label = data.name,
            virt_lines = virt_lines,
            data = data.ctrl
        }
        table.insert(choices, choice)
    end
    selector.select({
            prompt = "Terminate task",
            items = choices
        },
        function(ctrl)
            if ctrl then
                ---@cast ctrl loop.TaskControl
                ctrl.terminate()
            end
        end)
end

---@param command string|nil
---@param arg1 string
---@param arg2? string|nil
function M.task_command(command, arg1, arg2)
    _ensure_init()
    if not _ws_data then
        _notify_no_ws()
        return
    end

    command = command and command:match("^%s*(.-)%s*$") or ""
    command = command ~= "" and command or "run"
    local config_dir = _ws_data.config_dir
    if command == "run" then
        _load_and_run_task("task", arg1)
    elseif command == "repeat" then
        _load_and_run_task("repeat")
    elseif command == "configure" then
        taskmgr.configure_tasks(config_dir)
    elseif command == "terminate" then
        _select_and_terminate_task()
    elseif command == "terminate_all" then
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
    _ensure_init()
    if not _ws_data then
        _notify_no_ws()
        return
    end

    command = command and command:match("^%s*(.-)%s*$") or ""
    if command == "" then
        command = "list"
    end

    local config_dir = _ws_data.config_dir
    if command == "list" then
        variablesmgr.show_variables(config_dir)
    elseif command == "configure" then
        variablesmgr.configure_variables(config_dir)
    else
        vim.notify('Invalid var command: ' .. command)
    end
end

function M.statuspanel_subcommands(args)
    if #args == 0 then
        return { "show", "hide", "clean" }
    end
    return {}
end

function M.sidebar_subcommands(args)
    if #args == 0 then
        return { "show", "hide" }
    end
    if #args == 1 and args[1] == "show" then
        local preset_names = sidebar.preset_names()
        return #preset_names > 1 and preset_names or {}
    end
    return {}
end

---@param for_cmd_menu boolean?
function M.page_subcommands(args, for_cmd_menu)
    _ensure_init()
    if #args == 0 then
        return { "switch", "open" }
    end
    if not for_cmd_menu then
        if #args == 1 and (args[1] == "open" or args[1] == "switch") then
            local names = statuspanel.get_pagegroup_names()
            return vim.tbl_map(vim.fn.fnameescape, names)
        end
        if #args == 2 and (args[1] == "open" or args[1] == "switch") then
            local group = args[2]
            local names = statuspanel.get_page_names(group)
            return vim.tbl_map(vim.fn.fnameescape, names)
        end
    end
    return {}
end

function M.page_command(command, arg1, arg2)
    _ensure_init()
    if not command or command == "" or command == "switch" then
        M.switch_page(arg1, arg2)
    elseif command == "open" then
        M.open_page(arg1, arg2)
    else
        vim.notify("Invalid command: " .. command)
    end
end

function M.statuspanel_command(command)
    _ensure_init()
    if not command or command == "" then
        M.toggle_window()
    elseif command == "show" then
        M.show_window()
    elseif command == "hide" then
        M.hide_window()
    elseif command == "clean" then
        if _ws_data and _ws_data.page_manager then _ws_data.page_manager.delete_expired_groups() end
        extensionsmgr.clean_page_groups()
    else
        vim.notify("Invalid command: " .. command)
    end
end

function M.sidebar_command(command, name)
    if command == nil or command == "" then
        sidebar.toggle()
    elseif command == "show" then
        sidebar.show(name)
    elseif command == "hide" then
        sidebar.hide()
    else
        vim.notify("Invalid sidebar command: " .. tostring(command))
    end
end

function M.show_window()
    _ensure_init()
    if not _ws_data then
        _notify_no_ws()
        return
    end
    statuspanel.show_window()
    sidebar.fix_layout()
end

function M.hide_window()
    _ensure_init()
    statuspanel.hide_window()
end

function M.toggle_window()
    _ensure_init()
    if statuspanel.is_visible() then
        M.hide_window()
    else
        M.show_window()
    end
end

function M.switch_page(group_label, page_label)
    _ensure_init()
    statuspanel.open_page(nil, group_label, page_label)
end

---@param group_label string|nil
---@param page_label string|nil
function M.open_page(group_label, page_label)
    _ensure_init()
    statuspanel.open_page(vim.api.nvim_get_current_win(), group_label, page_label)
end

function M.logs_command()
    _ensure_init()
    log.show_logs()
end

---@param quiet boolean?
---@return boolean,number,string?
function M.save_workspace_buffers(quiet)
    _ensure_init()
    if not _ws_data then
        if not quiet then _notify_no_ws() end
        return false, 0, "No active workspace"
    end
    local ws_config, config_err = _load_workspace_config(_ws_data.ws_dir)
    if not ws_config then
        local err_str = "Invalid workspace configuration"
        if config_err then
            err_str = ("%s\n%s"):format(err_str, config_err)
        end
        if not quiet then vim.notify(err_str) end
        return false, 0, err_str
    end
    return true, wssaveutil.save_workspace_buffers(_ws_data.ws_dir, ws_config)
end

function M.find_workspace_files()
    _ensure_init()
    if not _ws_data then
        _notify_no_ws()
        return
    end
    local ws_config, config_err = _load_workspace_config(_ws_data.ws_dir)
    if not ws_config then
        vim.notify("Invalid workspace configuration")
        return
    end
    local history_file = vim.fs.joinpath(_ws_data.config_dir, "ffindhist.json")
    ---@type loop.Picker.QueryHistoryProvider
    local history_provider = {
        load = function()
            local ok, hist = jsoncodec.load_from_file(history_file)
            return ok and (hist or {}) or {}
        end,
        store = function(hist)
            jsoncodec.save_to_file(history_file, hist)
        end
    }
    local filepicker = require("loop.tools.filepicker")
    filepicker.open({
        cwd = _ws_data.ws_dir,
        include_globs = ws_config.files.include,
        exclude_globs = ws_config.files.exclude,
        history_provider = history_provider,
    })
end

function M.grep_workspace_files()
    _ensure_init()
    if not _ws_data then
        _notify_no_ws()
        return
    end
    local ws_config, config_err = _load_workspace_config(_ws_data.ws_dir)
    if not ws_config then
        vim.notify("Invalid workspace configuration")
        return
    end
    local history_file = vim.fs.joinpath(_ws_data.config_dir, "grephist.json")
    ---@type loop.Picker.QueryHistoryProvider
    local history_provider = {
        load = function()
            local ok, hist = jsoncodec.load_from_file(history_file)
            return ok and (hist or {}) or {}
        end,
        store = function(hist)
            jsoncodec.save_to_file(history_file, hist)
        end
    }
    local livegrep = require("loop.tools.livegrep")
    livegrep.open({
        cwd = _ws_data.ws_dir,
        include_globs = ws_config.files.include,
        exclude_globs = ws_config.files.exclude,
        history_provider = history_provider,
    })
end

return M
