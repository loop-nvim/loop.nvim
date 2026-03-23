local M = {}

local loopconfig = require('loop').config

-- Log history storage
---@type {text: string, level: integer|nil, timestamp: number, category: string|nil}[]
local _log_history = {}

local function _get_log_count()
    return (loopconfig and loopconfig.logs_count) or 50
end

---@param text string|string[]
---@param level vim.log.levels?
function M.log(text, level)
    if not text then return end

    local log_text = type(text) == 'table' and table.concat(text, '\n') or text

    -- Store in history
     table.insert(_log_history, {
        text = log_text,
        level = level,
        ---@diagnostic disable-next-line: undefined-field
        timestamp = vim.loop.now()
    })
    -- Limit history size
    if #_log_history > _get_log_count() then
        table.remove(_log_history, 1)
    end
end

---@param message string User-friendly message to log
---@param category nil|"workspace"|"task"|"save"
function M.user_log(message, category)
    if type(message) == "table" then
        message = table.concat(message, '\n')
    end
    table.insert(_log_history, {
        text = message,
        level = nil, -- User logs don't have technical levels
        ---@diagnostic disable-next-line: undefined-field
        timestamp = vim.loop.now(),
        category = category,
    })

    -- Limit history size (keep last 1000 entries)
    if #_log_history > _get_log_count() then
        table.remove(_log_history, 1)
    end
end

---@param count integer|nil Number of recent logs to retrieve (default: all)
---@return {text: string, level: integer|nil, timestamp: number, category: string|nil}[]
local function _get_logs(count)
    if not count or count <= 0 then
        return vim.list_extend({}, _log_history)
    end

    local start_idx = math.max(1, #_log_history - count + 1)
    local result = {}
    for i = start_idx, #_log_history do
        table.insert(result, _log_history[i])
    end
    return result
end

function M.show_logs()
    local floatwin = require('loop.utils.floatwin')

    local logs_count = _get_log_count()
    local logs = _get_logs(logs_count)

    if #logs == 0 then
        vim.notify("Loop: No logs available", vim.log.levels.INFO)
        return
    end

    -- Format logs for display (user-friendly)
    local lines = {}
    for _, log in ipairs(logs) do
        -- Skip technical debug logs unless in debug mode
        if log.level == vim.log.levels.DEBUG and not (loopconfig and loopconfig.debug) then
            -- Only show user logs
            if not log.category and not (log.level and log.level >= vim.log.levels.WARN) then
                goto continue
            end
        end

        -- Choose icon based on category or level
        local icon = "" -- default bullet

        if log.category == "workspace" then
            icon = "" -- folder
        elseif log.category == "task" then
            icon = "" -- gear
        elseif log.category == "save" then
            icon = "" -- save
        elseif log.level then
            if log.level == vim.log.levels.ERROR then
                icon = "" -- error
            elseif log.level == vim.log.levels.WARN then
                icon = "" -- warning
            elseif log.level == vim.log.levels.INFO then
                icon = "" -- info
            end
        end

        -- Format timestamp (relative time)
        local time_str = ""
        if log.timestamp then
            ---@diagnostic disable-next-line: undefined-field
            local now = vim.loop.now()
            local diff_ms = (now - log.timestamp) / 1000
            if diff_ms < 1 then
                time_str = "just now"
            elseif diff_ms < 60 then
                time_str = string.format("%.0fs ago", diff_ms)
            elseif diff_ms < 3600 then
                time_str = string.format("%.0fm ago", diff_ms / 60)
            else
                time_str = string.format("%.1fh ago", diff_ms / 3600)
            end
        end

        -- Clean up text (remove "loop.nvim: " prefix if present)
        local clean_text = log.text
        -- Split multi-line logs
        local log_lines = vim.split(clean_text, '\n', { trimempty = false })
        for j, line in ipairs(log_lines) do
            if j == 1 then
                table.insert(lines, string.format(" %s %s  %s", icon, time_str, line))
            else
                table.insert(lines, string.format("   %s", line))
            end
        end

        ::continue::
    end

    if #lines == 0 then
        -- Only header and empty line
        table.insert(lines, "No recent activity")
    end

    local text = table.concat(lines, '\n')
    floatwin.show_floatwin(text, {
        title = "Activity Log",
        move_to_bot = true
    })
end

return M
