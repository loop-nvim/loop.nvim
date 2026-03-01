local M = {}

local uitools = require('loop.tools.uitools')
local systools = require("loop.tools.systools")
local selector = require("loop.tools.selector")

local _nofile_error = "Current buffer is not a regular saved file"
local _badtype_error = "Current file type is not %s"

--- Helper to check if current buffer is a valid file
local function _is_file()
    local buf = vim.api.nvim_get_current_buf()
    if not uitools.is_regular_buffer(buf) then
        return false
    end
    return vim.api.nvim_buf_get_name(buf) ~= ""
end

-- ============================================================================
-- MACRO DEFINITIONS
-- Signature: function(ctx, arg) return result, error_msg end
-- ============================================================================

function M.home(ctx)
    local home = os.getenv("HOME")
    if not home then
        return nil, "Environment variable $HOME is not set"
    end
    return home
end

function M.file(ctx, type)
    if not _is_file() then return nil, _nofile_error end
    if type and type ~= vim.bo.filetype then
        return nil, _badtype_error:format(type)
    end
    return vim.fn.expand("%:p")
end

function M.filename(ctx, type)
    if not _is_file() then return nil, _nofile_error end
    if type and type ~= vim.bo.filetype then
        return nil, _badtype_error:format(type)
    end
    return vim.fn.expand("%:t")
end

function M.fileext(ctx)
    if not _is_file() then return nil, _nofile_error end
    local ext = vim.fn.expand("%:e")
    return (ext ~= "" and ext) or nil
end

function M.fileroot(ctx, type)
    if not _is_file() then return nil, _nofile_error end
    if type and type ~= vim.bo.filetype then
        return nil, _badtype_error:format(type)
    end
    return vim.fn.expand("%:p:r")
end

function M.filedir(ctx)
    if not _is_file() then return nil, _nofile_error end
    return vim.fn.expand("%:p:h")
end

function M.wsdir(ctx)
    if not ctx or not ctx.ws_dir then
        return nil, "No active workspace"
    end
    return ctx.ws_dir
end

function M.cwd(ctx)
    return vim.fn.getcwd()
end

function M.filetype(ctx)
    return vim.bo.filetype
end

function M.tmpdir(ctx)
    local tmp = os.getenv("TMPDIR") or os.getenv("TEMP") or os.getenv("TMP") or "/tmp"
    return tmp
end

function M.date(ctx)
    return os.date("%F") -- YYYY-MM-DD
end

function M.time(ctx)
    return os.date("%T") -- HH:MM:SS
end

function M.timestamp(ctx)
    return os.date("%Y-%m-%dT%H:%M:%S")
end

--- Async: Prompts user for input
-- NOTE: Uses coroutine.yield/resume to handle the async UI call
function M.prompt(ctx, prompt, default, completion)
    if not prompt then return nil, "prompt macro requires prompt text" end

    local co = coroutine.running()

    prompt = prompt .. ': '
    vim.schedule(function()
        vim.ui.input({ prompt = prompt, default = default, completion = completion }, function(input)
            -- Resume the coroutine with the user's input
            coroutine.resume(co, input)
        end)
    end)

    -- Pause execution here until user presses Enter/Esc
    local result = coroutine.yield()

    if not result then return nil, "Prompt cancelled" end
    return result
end

function M.env(ctx, varname)
    if not varname then return nil, "env macro requires variable name" end
    local value = vim.fn.getenv(varname)
    return (value ~= vim.NIL and value) or nil
end

--- Looks up a custom variable and returns its literal value (no macro expansion)
function M.var(ctx, varname, ...)
    if not varname then return nil, "var macro requires variable name" end

    if not ctx or not ctx.variables then
        return nil, "No task context available"
    end

    local raw_value = ctx.variables[varname]
    if not raw_value then
        return nil, "Variable not found: " .. varname
    end

    if select("#", ...) > 0 then
        local ok, formatted = pcall(string.format, raw_value, ...)
        if not ok then
            return nil, "String substitution failed for variable: " .. varname
        end
        return formatted
    end

    -- Return the literal value without expansion
    return raw_value
end

--- Async: Process selector
-- NOTE: Uses coroutine.yield/resume to handle the async UI call
M["select-pid"] = function(ctx)
    local procs = systools.get_running_processes()
    if not procs or #procs == 0 then
        return nil, "No processes found"
    end

    local choices = {}
    for _, proc in ipairs(procs) do
        table.insert(choices, {
            label = ("%8d | %s - %s"):format(proc.pid, proc.user or "unknown", proc.name or "unknown"),
            data = proc.pid,
        })
    end

    local co = coroutine.running()

    vim.schedule(function()
        selector.select({
                prompt = "Select process to attach",
                items = choices,
            },
            function(selected_pid)
                coroutine.resume(co, selected_pid)
            end
        )
    end)

    -- Pause until selection is made
    local pid = coroutine.yield()

    if not pid then return nil, "Process selection cancelled" end
    return pid
end

return M
