local M = {}

-- Returns a version of fn that can only be called once
function M.called_once(fn)
    local called = false
    return function(...)
        if called then
            return
        end
        called = true
        return fn(...)
    end
end

--- Starts a recurring timer using the Neovim event loop (uv).
---@param interval number The delay and subsequent interval between executions (in milliseconds).
---@param fn function The callback function to execute.
---@return function stop_timer A function that, when called, stops and cleans up the timer.
function M.start_timer(interval, fn)
    ---@diagnostic disable-next-line: undefined-field
    local timer = vim.uv.new_timer()
    assert(timer, "Timer creation failed")
    -- start(initial_delay, repeat_interval, callback)
    timer:start(interval, interval, vim.schedule_wrap(fn))
    return function()
        if timer then
            if timer:is_active() then
                timer:stop()
            end
            if not timer:is_closing() then
                timer:close()
            end
            timer = nil
        end
    end
end

---@param timer table?
---@return nil
function M.stop_and_close_timer(timer)
    if timer then
        if timer:is_active() then
            timer:stop()
        end
        if not timer:is_closing() then
            timer:close()
        end
    end
    return nil
end

function M.deep_merge_tables(dest, src)
    vim.validate("dest", dest, "table")
    vim.validate("src", src, "table")
    for k, v in pairs(src) do
        if type(v) == "table" then
            if type(dest[k]) == "table" then
                if vim.islist(v) then
                    -- Override lists completely
                    dest[k] = v
                else
                    -- Recursively merge dictionaries
                    dest[k] = M.deep_merge_tables(dest[k], v)
                end
            else
                -- Replace non-table with table
                dest[k] = v
            end
        else
            -- Override primitive values
            dest[k] = v
        end
    end
    return dest
end

return M
