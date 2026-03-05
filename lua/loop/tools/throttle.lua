local M = {}

local uv = vim.uv

-- Throttle that:
-- • Runs the first call immediately
-- • Guarantees at least `ms` between executions
-- • Never drops a call – if called during cooldown, it will run again exactly when allowed
-- • No arguments, pure side-effect trigger
function M.throttle_wrap(ms, fn)
    local timer = nil
    local last_exec = 0

    return function()
        ---@diagnostic disable-next-line: undefined-field
        local now = uv.now()

        local function run()
            ---@diagnostic disable-next-line: undefined-field
            last_exec = uv.now()
            fn()
        end

        -- Can run immediately
        if last_exec == 0 or now - last_exec >= ms then
            run()
            return
        end

        -- Already scheduled
        if timer then
            return
        end

        -- Schedule trailing execution
        local delay = ms - (now - last_exec)
        ---@diagnostic disable-next-line: undefined-field
        timer = uv.new_timer()
        timer:start(delay, 0, function()
            vim.schedule(function()
                if timer:is_active() then timer:stop() end
                timer:close()
                timer = nil
                run()
            end)
        end)
    end
end

return M
