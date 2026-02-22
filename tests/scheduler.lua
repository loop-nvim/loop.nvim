---@diagnostic disable: undefined-global, undefined-field
require("plenary.busted")
local Scheduler = require("loop.tools.Scheduler")

describe("loop.tools.Scheduler", function()
    -- Synchronous mock
    local function sync_start_node(behavior_map)
        behavior_map = behavior_map or {}
        return function(id, on_exit)
            local config = behavior_map[id] or { succeed = true }
            local control = { terminate = function() end }
            on_exit(config.succeed ~= false, config.reason)
            return control
        end
    end

    -- Async mock using vim.schedule (reliable in tests)
    local function async_start_node(behavior_map)
        behavior_map = behavior_map or {}
        return function(id, on_exit)
            local config = behavior_map[id] or { succeed = true }
            local control = { terminate = function() end }
            vim.schedule(function()
                on_exit(config.succeed ~= false, config.reason)
            end)
            return control
        end
    end

    it("completes a single node", function()
        local sched = Scheduler:new()
        local called = false
        sched:start({ { id = "test" } }, "test", sync_start_node(), function(id, event) end, function(ok, trigger)
            called = true
            assert.is_true(ok)
            assert.equals("node", trigger)
        end)
        vim.wait(200)
        assert.is_true(called)
        assert.is_true(sched:is_terminated())
    end)

    it("completes a single node asynchronously and eventually terminates", function()
        local sched = Scheduler:new()
        local called = false
        sched:start({ { id = "test" } }, "test", async_start_node(), function(id, event) end, function(ok)
            called = true
            assert.is_true(ok)
        end)
        assert.is_false(called)
        vim.wait(200)
        assert.is_true(called)
        assert.is_true(sched:is_terminated())
    end)

    it("reports leaf node failure correctly", function()
        local nodes = { { id = "fail" } }
        local start_node = sync_start_node({ fail = { succeed = false, reason = "boom" } })
        local sched = Scheduler:new()
        local called = false
        sched:start(nodes, "fail", start_node, function(id, event) end, function(ok, trigger, param)
            called = true
            assert.is_false(ok)
            assert.equals("node", trigger)
            assert.equals("boom", param)
        end)
        vim.wait(200)
        assert.is_true(called)
        assert.is_true(sched:is_terminated())
    end)

    it("reports failure when start_node cannot start a node", function()
        local start_node = function() return nil, "blocked" end
        local sched = Scheduler:new()
        local called = false
        sched:start({ { id = "test" } }, "test", start_node, function(id, event) end, function(ok, trigger, param)
            called = true
            assert.is_false(ok)
            assert.equals("node", trigger)
            assert.equals("blocked", param)
        end)
        assert.is_true(called)
        assert.is_true(sched:is_terminated())
    end)

    it("detects invalid root node (not in graph)", function()
        local sched = Scheduler:new()
        local called = false
        sched:start({ { id = "valid" } }, "invalid", sync_start_node(), function(id, event) end,
            function(ok, trigger, param)
                called = true
                assert.is_false(ok)
                assert.equals("invalid_node", trigger)
                assert.equals("invalid", param)
            end)
        assert.is_true(called)
        assert.is_true(sched:is_terminated())
    end)

    it("detects cycles in the graph", function()
        local nodes = {
            { id = "a",    deps = { "b" } },
            { id = "b",    deps = { "a" } },
            { id = "root", deps = { "a" } },
        }
        local sched = Scheduler:new()
        local called = false
        sched:start(nodes, "root", sync_start_node(), function(id, event) end, function(ok, trigger, param)
            called = true
            assert.is_false(ok)
            assert.equals("cycle", trigger)
        end)
        vim.wait(200)
        assert.is_true(called)
        assert.is_true(sched:is_terminated())
    end)

    it("executes sequential dependencies in order", function()
        local order = {}
        local start_node = function(id, on_exit)
            table.insert(order, "start:" .. id)
            local control = { terminate = function() end }
            vim.schedule(function()
                table.insert(order, "end:" .. id)
                on_exit(true, nil)
            end)
            return control
        end

        local nodes = {
            { id = "a" },
            { id = "b" },
            { id = "root", deps = { "a", "b" }, order = "sequence" },
        }

        local sched = Scheduler:new()
        local root_ok = false
        sched:start(nodes, "root", start_node, function(id, event) end, function(ok)
            root_ok = ok
        end)

        vim.wait(100)
        assert.is_true(root_ok)
        assert.are.same({
            "start:a", "end:a",
            "start:b", "end:b",
            "start:root", "end:root",
        }, order)
        assert.is_true(sched:is_terminated())
    end)

    it("interrupts on terminate() and reports interrupt", function()
        local started = false
        local terminated = false

        local start_node = function(id, on_exit)
            started = true
            local control = {
                terminate = function()
                    terminated = true
                    on_exit(false, "interrupted by terminate")
                end
            }
            vim.schedule(function()
                vim.defer_fn(function()
                    if not terminated then
                        on_exit(true, nil)
                    end
                end, 1000)
            end)
            return control
        end

        local sched = Scheduler:new()
        local called = false
        local received_ok, received_trigger, received_param

        sched:start({ { id = "task" } }, "task", start_node, function(id, event) end, function(ok, trigger, param)
            called = true
            received_ok = ok
            received_trigger = trigger
            received_param = param
        end)

        vim.wait(50)
        assert.is_true(started)

        sched:terminate()
        vim.wait(200)

        assert.is_true(called)
        assert.is_false(received_ok)
        assert.equals("node", received_trigger)
        assert.equals("interrupted by terminate", received_param)
        assert.is_true(terminated)
        assert.is_true(sched:is_terminated())
    end)

    it("handles shared dependencies (diamond pattern) only once", function()
        local execution_count = 0
        local nodes = {
            { id = "shared" },
            { id = "a",     deps = { "shared" } },
            { id = "b",     deps = { "shared" } },
            { id = "root",  deps = { "a", "b" }, order = "parallel" },
        }

        local start_node = function(id, on_exit)
            if id == "shared" then execution_count = execution_count + 1 end
            vim.defer_fn(function() on_exit(true) end, 10)
            return { terminate = function() end }
        end

        local sched = Scheduler:new()
        local done = false

        sched:start(nodes, "root", start_node, function() end, function(ok)
            done = true
            assert.is_true(ok)
        end)

        vim.wait(200, function() return done end)
        assert.equals(1, execution_count)
    end)

    it("respects sequential execution order", function()
        local log = {}
        local nodes = {
            { id = "step1" },
            { id = "step2" },
            { id = "root", deps = { "step1", "step2" }, order = "sequence" },
        }

        local start_node = function(id, on_exit)
            table.insert(log, id .. "_start")
            vim.defer_fn(function()
                table.insert(log, id .. "_stop")
                on_exit(true)
            end, 20)
            return { terminate = function() end }
        end

        local sched = Scheduler:new()
        local done = false
        sched:start(nodes, "root", start_node, function() end, function() done = true end)

        vim.wait(500, function() return done end)

        assert.equals("step1_start", log[1])
        assert.equals("step1_stop", log[2])
        assert.equals("step2_start", log[3])
        assert.equals("step2_stop", log[4])
    end)

    it("handles immediate start_node failures gracefully", function()
        local nodes = { { id = "fail_me" } }
        local start_node = function(id, on_exit)
            return nil, "OS Error: Permission Denied"
        end

        local sched = Scheduler:new()
        local result_ok, result_param
        local done = false

        sched:start(nodes, "fail_me", start_node, function() end, function(ok, trigger, param)
            result_ok = ok
            result_param = param
            done = true
        end)

        vim.wait(100, function() return done end)
        assert.is_false(result_ok)
        assert.equals("OS Error: Permission Denied", result_param)
        assert.is_true(sched:is_terminated())
    end)

    it("fires start and stop events in correct pairs", function()
        local nodes = {
            { id = "child" },
            { id = "root", deps = { "child" } }
        }
        local events = {}
        local start_node = function(id, on_exit)
            vim.defer_fn(function() on_exit(true) end, 5)
            return { terminate = function() end }
        end

        local sched = Scheduler:new()
        local done = false

        sched:start(nodes, "root", start_node, function(id, event)
            table.insert(events, id .. ":" .. event)
        end, function() done = true end)

        vim.wait(200, function() return done end)

        assert.equals("child:start", events[1])
        assert.equals("child:stop", events[2])
        assert.equals("root:start", events[3])
        assert.equals("root:stop", events[4])
    end)

    it("executes a shared deep dependency only once across levels", function()
        local init_calls = 0
        local nodes = {
            { id = "init",   deps = {} },
            { id = "lvl1_a", deps = { "init" } },
            { id = "lvl1_b", deps = { "init" } },
            { id = "lvl2",   deps = { "lvl1_a", "lvl1_b" } },
        }

        local start_node = function(id, on_exit)
            if id == "init" then init_calls = init_calls + 1 end
            on_exit(true)
            return { terminate = function() end }
        end

        local sched = Scheduler:new()
        local done = false
        sched:start(nodes, "lvl2", start_node, function() end, function(ok)
            done = true
            assert.is_true(ok)
        end)

        vim.wait(100, function() return done end)
        assert.equals(1, init_calls)
    end)

    it("fails the root if one branch of a shared dependency fails", function()
        local nodes = {
            { id = "init",        deps = {} },
            { id = "branch_ok",   deps = { "init" } },
            { id = "branch_fail", deps = { "init" } },
            { id = "root",        deps = { "branch_ok", "branch_fail" }, order = "parallel" },
        }

        local start_node = function(id, on_exit)
            if id == "branch_fail" then
                on_exit(false, "node")
            else
                on_exit(true)
            end
            return { terminate = function() end }
        end

        local sched = Scheduler:new()
        local res_ok, res_trigger
        local done = false
        sched:start(nodes, "root", start_node, function() end, function(ok, trigger)
            res_ok = ok
            res_trigger = trigger
            done = true
        end)

        vim.wait(100, function() return done end)
        assert.is_false(res_ok)
        assert.equals("deps_failed", res_trigger)
    end)

    it("rejects concurrent start() calls with interrupt", function()
        local leaf_started = 0
        local start_node = function(id, on_exit)
            leaf_started = leaf_started + 1
            vim.defer_fn(function() on_exit(true) end, 50)
            return { terminate = function() end }
        end

        local nodes = { { id = "task" } }
        local sched = Scheduler:new()
        local success_results = 0
        local interrupt_results = 0

        local function callback(ok, trigger, param)
            if ok then
                success_results = success_results + 1
            else
                interrupt_results = interrupt_results + 1
            end
        end

        sched:start(nodes, "task", start_node, function() end, callback)
        sched:start(nodes, "task", start_node, function() end, function(ok, trigger, param)
            callback(ok, trigger, param)
            if not ok then
                assert.equals("interrupt", trigger)
                assert.equals("another schedule is running", param)
            end
        end)
        sched:start(nodes, "task", start_node, function() end, callback)

        vim.wait(300)
        assert.equals(1, leaf_started)
        assert.equals(1, success_results)
        assert.equals(2, interrupt_results)
        assert.is_true(sched:is_terminated())
    end)

    it("handles concurrent starts of the same root correctly (only one run)", function()
        local executions = 0
        local start_node = function(id, on_exit)
            executions = executions + 1
            vim.schedule(function() on_exit(true) end)
            return { terminate = function() end }
        end

        local sched = Scheduler:new()
        local completed_ok = 0
        local interrupted = 0
        local nodes = { { id = "task" } }

        local function callback(ok, trigger, param)
            if ok then completed_ok = completed_ok + 1 else interrupted = interrupted + 1 end
        end

        sched:start(nodes, "task", start_node, function() end, callback)
        sched:start(nodes, "task", start_node, function() end, function(ok, trigger, param)
            callback(ok, trigger, param)
            if not ok then
                assert.equals("interrupt", trigger)
                assert.equals("another schedule is running", param)
            end
        end)

        vim.wait(300)
        assert.equals(1, executions)
        assert.equals(1, completed_ok)
        assert.is_true(interrupted >= 1)
        assert.is_true(sched:is_terminated())
    end)

    it("terminates during dependency execution (interrupt propagation)", function()
        local log = {}
        local start_node = function(id, on_exit)
            table.insert(log, "start:" .. id)
            local ctl = {
                terminate = function()
                    table.insert(log, "terminate:" .. id)
                    on_exit(false, "terminated")
                end
            }
            vim.defer_fn(function()
                if id ~= "long" then return end
                table.insert(log, "complete:" .. id)
                on_exit(true)
            end, 100)
            return ctl
        end

        local nodes = {
            { id = "quick" },
            { id = "long" },
            { id = "root", deps = { "quick", "long" }, order = "parallel" },
        }

        local sched = Scheduler:new()
        local called = false
        sched:start(nodes, "root", start_node, function() end, function(ok, trigger)
            called = true
            assert.is_false(ok)
            assert.equals("interrupt", trigger)
        end)

        vim.wait(50)
        sched:terminate()

        vim.wait(200)
        assert.is_true(called)
        assert.is_true(sched:is_terminated())
    end)

    it("does not leak state on early failure (invalid node)", function()
        local sched = Scheduler:new()
        local nodes = { { id = "valid" } }
        local start_node = sync_start_node()

        local called = false
        sched:start(nodes, "invalid", start_node, function() end, function(ok, trigger)
            called = true
            assert.is_false(ok)
            assert.equals("invalid_node", trigger)
        end)

        assert.is_true(called)
        assert.is_true(sched:is_terminated())
        assert.is_nil(sched._current_run_id)

        local second_called = false
        sched:start(nodes, "valid", start_node, function() end, function(ok)
            second_called = true
            assert.is_true(ok)
        end)
        vim.wait(100)
        assert.is_true(second_called)
    end)

    it("handles termination while deps are still being resolved (visiting cleanup)", function()
        local start_node = function(id, on_exit)
            if id == "leaf" then
                vim.defer_fn(function() on_exit(true) end, 100)
            end
            return { terminate = function() end }
        end

        local nodes = {
            { id = "leaf" },
            { id = "mid",  deps = { "leaf" } },
            { id = "root", deps = { "mid" } },
        }

        local sched = Scheduler:new()
        local completed = false
        sched:start(nodes, "root", start_node, function() end, function(ok)
            completed = true
            assert.is_false(ok)
        end)

        vim.wait(30)
        sched:terminate()

        vim.wait(200)
        assert.is_true(completed)
        assert.is_true(sched:is_terminated())
    end)

    it("supports parallel dependencies with mixed success/failure", function()
        local nodes = {
            { id = "success1" },
            { id = "success2" },
            { id = "fail" },
            { id = "root",    deps = { "success1", "success2", "fail" }, order = "parallel" },
        }

        local behaviors = {
            success1 = { succeed = true },
            success2 = { succeed = true },
            fail     = { succeed = false, reason = "failed on purpose" },
        }

        local sched = Scheduler:new()
        local result_ok, result_trigger, result_param
        local done = false

        sched:start(nodes, "root", sync_start_node(behaviors), function() end, function(ok, trigger, param)
            result_ok = ok
            result_trigger = trigger
            result_param = param
            done = true
        end)

        vim.wait(100)
        assert.is_true(done)
        assert.is_false(result_ok)
        assert.equals("deps_failed", result_trigger)
    end)

    it("reuses completed nodes across multiple runs", function()
        local execution_log = {}
        local start_node = function(id, on_exit)
            table.insert(execution_log, id)
            on_exit(true)
            return { terminate = function() end }
        end

        local nodes = {
            { id = "shared" },
            { id = "root",  deps = { "shared" } },
        }

        local sched = Scheduler:new()

        local done1 = false
        sched:start(nodes, "root", start_node, function() end, function() done1 = true end)
        vim.wait(100)
        assert.is_true(done1)

        execution_log = {}
        local done2 = false
        sched:start(nodes, "root", start_node, function() end, function() done2 = true end)
        vim.wait(100)
        assert.is_true(done2)
        assert.equals(2, #execution_log)
    end)

    it("cleans up properly when terminate() called before any leaves start", function()
        local started = false
        local start_node = function(id, on_exit)
            started = true
            return { terminate = function() on_exit(false, "term") end }
        end

        local sched = Scheduler:new()
        local called = false
        local nodes = { { id = "task" } }

        sched:start(nodes, "task", start_node, function() end, function(ok, trigger)
            called = true
            assert.is_false(ok)
            assert.equals("node", trigger)
        end)

        sched:terminate()

        vim.wait(200)
        assert.is_true(started)
        assert.is_true(called)
        assert.is_true(sched:is_terminated())
    end)
end)
