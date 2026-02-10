---@diagnostic disable: undefined-global, undefined-field
require("plenary.busted")
local task_scheduler = require("loop.task.taskscheduler")

describe("loop.task.taskscheduler", function()
    -- Helpers to create mock tasks
    ---@param order "parallel"|"sequence"|nil
    ---@param if_running "restart"|"refuse"|"parallel"|"wait"|nil
    local function mock_task(name, deps, order, if_running)
        ---@type loop.Task
        return {
            name = name,
            type = "none",
            depends_on = deps or {},
            depends_order = order or "sequence",
            if_running = if_running,
        }
    end

    -- Mock start_task implementation
    local function sync_start_task(ok, reason)
        return function(task, on_exit)
            on_exit(ok ~= false, reason)
            return { terminate = function() end }
        end
    end

    it("validates and runs a simple task plan", function()
        local tasks = { mock_task("root") }
        local event_called = false
        local exit_called = false

        task_scheduler.run_plan(
            tasks,
            "root",
            sync_start_task(true),
            function(name, event, success)
                if event == "stop" then event_called = true end
            end,
            function(success)
                exit_called = true
                assert.is_true(success)
            end
        )

        vim.wait(100, function() return exit_called end)
        assert.is_true(event_called)
    end)

    it("returns error message for missing root task", function()
        local tasks = { mock_task("not_root") }
        local exit_called = false

        task_scheduler.run_plan(
            tasks,
            "root",
            sync_start_task(true),
            function() end,
            function(success, msg)
                exit_called = true
                assert.is_false(success)
                assert.match("Root task 'root' not found", msg)
            end
        )

        vim.wait(100, function() return exit_called end)
    end)

    it("handles 'refuse' concurrency correctly", function()
        local long_task = mock_task("busy", {}, "sequence", "refuse")
        local exit_msg = nil

        -- Start first instance (will stay running)
        local finish_first = false
        task_scheduler.run_plan(
            { long_task },
            "busy",
            function(_, on_exit)
                -- Don't call on_exit yet to keep it "running"
                return {
                    terminate = function()
                        finish_first = true
                        on_exit(true)
                    end
                }
            end,
            function() end
        )

        -- Try to start second instance
        task_scheduler.run_plan(
            { long_task },
            "busy",
            sync_start_task(true),
            function() end,
            function(success, msg)
                exit_msg = msg
            end
        )

        vim.wait(100, function() return exit_msg ~= nil end)
        assert.equals("Task refused (already running)", exit_msg)

        -- Cleanup
        task_scheduler.terminate()
        vim.wait(100, function() return finish_first end)
    end)

    it("handles 'restart' concurrency by waiting for termination", function()
        local restart_task = mock_task("reboot", {}, "sequence", "restart")
        local log = {}

        -- Start first instance
        task_scheduler.run_plan(
            { restart_task },
            "reboot",
            function(_, on_exit)
                table.insert(log, "start_1")
                return {
                    terminate = function()
                        vim.defer_fn(function()
                            table.insert(log, "stop_1")
                            on_exit(true)
                        end, 50)
                    end
                }
            end,
            function() end
        )

        vim.wait(20) -- Ensure first one is registered as running

        -- Trigger restart
        local second_finished = false
        task_scheduler.run_plan(
            { restart_task },
            "reboot",
            function(_, on_exit)
                table.insert(log, "start_2")
                on_exit(true)
                return { terminate = function() end }
            end,
            function() end,
            function() second_finished = true end
        )

        vim.wait(200, function() return second_finished end)

        -- Verify order: 1 starts, then is told to stop, then 2 starts
        assert.equals("start_1", log[1])
        assert.equals("stop_1", log[2])
        assert.equals("start_2", log[3])
    end)

    it("formats dependency cycle errors correctly", function()
        local tasks = {
            mock_task("a", { "b" }),
            mock_task("b", { "a" }),
        }
        local error_msg = nil

        task_scheduler.run_plan(
            tasks,
            "a",
            sync_start_task(true),
            function() end,
            function(success, msg)
                error_msg = msg
            end
        )

        vim.wait(100, function() return error_msg ~= nil end)
        assert.match("Task dependency loop detected", error_msg)
    end)

    it("terminates all active plans", function()
        local tasks = { mock_task("t1") }
        local t1_stopped = false

        task_scheduler.run_plan(
            tasks,
            "t1",
            function(_, on_exit)
                return {
                    terminate = function()
                        t1_stopped = true
                        on_exit(false, "term")
                    end
                }
            end,
            function() end
        )

        assert.is_true(task_scheduler.is_running())
        task_scheduler.terminate()

        vim.wait(1000, function() return t1_stopped end)
        assert.is_true(t1_stopped)
        vim.wait(1000, function() return not task_scheduler.is_running() end)
        assert.is_false(task_scheduler.is_running())
    end)
end)

describe("loop.task.taskscheduler - Restart Scenarios", function()
    local function mock_task(name)
        ---@type loop.Task
        return {
            name = name,
            depends_on = {},
            depends_order = "sequence",
            if_running = "restart",
            type = "process",
        }
    end

    it("verifies the new task only starts after the old task fully exits", function()
        local log = {}
        local task_def = mock_task("service")

        -- 1. Start the first instance
        task_scheduler.run_plan({ task_def }, "service", function(_, on_exit)
            table.insert(log, "start_1")
            return {
                terminate = function()
                    table.insert(log, "term_1_received")
                    -- Simulate an asynchronous cleanup delay
                    vim.defer_fn(function()
                        table.insert(log, "exit_1_callback")
                        on_exit(true)
                    end, 50)
                end
            }
        end, function() end)

        vim.wait(10) -- Let it register

        -- 2. Start the second instance (triggers restart)
        local second_done = false
        task_scheduler.run_plan({ task_def }, "service", function(_, on_exit)
            table.insert(log, "start_2")
            on_exit(true)
            return { terminate = function() end }
        end, function() end, function() second_done = true end)

        vim.wait(200, function() return second_done end)

        -- ASSERTION: start_2 MUST happen after exit_1_callback
        assert.are.same({
            "start_1",
            "term_1_received",
            "exit_1_callback",
            "start_2"
        }, log)
    end)

    it("handles multiple concurrent restarts (queuing waiters)", function()
        local log = {}
        local task_def = mock_task("queued_service")

        -- Start original
        task_scheduler.run_plan({ task_def }, "queued_service", function(_, on_exit)
            table.insert(log, "start_orig")
            return {
                terminate = function()
                    vim.defer_fn(function()
                        table.insert(log, "exit_orig")
                        on_exit(true)
                    end, 50)
                end
            }
        end, function() end)

        -- Fire two restarts at nearly the same time
        local final_done = 0
        local start_fn = function(_, on_exit)
            table.insert(log, "start_restart")
            on_exit(true)
            return { terminate = function() end }
        end

        vim.wait(300)
        print("test2")

        task_scheduler.run_plan({ task_def }, "queued_service", start_fn, function() end,
            function() final_done = final_done + 1 end)
        task_scheduler.run_plan({ task_def }, "queued_service", start_fn, function() end,
            function() final_done = final_done + 1 end)

        vim.wait(300, function() return final_done == 2 end)

        -- We expect the original to exit once, and two new ones to have started
        local start_count = 0
        for _, entry in ipairs(log) do
            if entry == "start_restart" then start_count = start_count + 1 end
        end

        assert.equals(2, final_done, "both tasks are expected to end")
        assert.equals(1, start_count, "Only the last one is expected to run")
        assert.equals("exit_orig", log[2], "The first restart should wait for original exit")
    end)

    it("cancels a pending restart if the plan itself is terminated", function()
        local task_def = mock_task("stuck")
        local second_started = false

        -- 1. Start instance 1 that takes forever to terminate
        task_scheduler.run_plan({ task_def }, "stuck", function(_, on_exit)
            return {
                terminate = function()
                    -- This task is "stubborn" and doesn't call on_exit immediately
                    vim.defer_fn(function() on_exit(true) end, 200)
                end
            }
        end, function() end)

        vim.wait(10)

        -- 2. Start instance 2 (will be a 'waiter')
        task_scheduler.run_plan({ task_def }, "stuck", function(_, on_exit)
            second_started = true
            on_exit(true)
            return { terminate = function() end }
        end, function() end)

        -- 3. Kill the whole scheduler before instance 1 finishes exiting
        task_scheduler.terminate()

        vim.wait(300)

        assert.is_false(second_started, "The second task should never have started because its plan was terminated")
    end)

    it("properly handles a restart when the start_task function returns an error", function()
        local task_def = mock_task("fail_restart")
        local error_received = nil

        -- Start healthy instance
        task_scheduler.run_plan({ task_def }, "fail_restart", function(_, on_exit)
            return { terminate = function() on_exit(true) end }
        end, function() end)

        vim.wait(10)

        -- Restart with a failing start_task
        task_scheduler.run_plan(
            { task_def },
            "fail_restart",
            function(_, on_exit)
                return nil, "OS Error: Binary not found"
            end,
            function() end,
            function(success, msg)
                if not success then error_received = msg end
            end
        )

        vim.wait(100, function() return error_received ~= nil end)
        assert.equals("OS Error: Binary not found", error_received)
    end)

    it("handles 'wait' concurrency by starting only after the running task exits", function()
        local wait_task = mock_task("waiter")
        wait_task.if_running = "wait"
        local log = {}

        -- Start first instance (long-running)
        task_scheduler.run_plan(
            { wait_task },
            "waiter",
            function(_, on_exit)
                table.insert(log, "start_1")
                return {
                    terminate = function()
                        -- Let it finish naturally after a delay
                        vim.defer_fn(function()
                            table.insert(log, "exit_1")
                            on_exit(true)
                        end, 200)
                    end
                }
            end,
            function() end
        )

        -- Start second instance (should WAIT, not terminate the first)
        local second_done = false
        task_scheduler.run_plan(
            { wait_task },
            "waiter",
            function(_, on_exit)
                table.insert(log, "start_2")
                on_exit(true)
                return { terminate = function() end }
            end,
            function() end,
            function() second_done = true end
        )

        vim.wait(1000, function() return second_done end)

        assert.are.same({
            "start_1",
            "exit_1",
            "start_2",
        }, log)
    end)
end)
