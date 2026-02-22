local class = require("loop.tools.class")

---@alias loop.scheduler.exit_trigger "cycle"|"invalid_node"|"interrupt"|"node"|"deps_failed"
---@alias loop.scheduler.exit_fn fun(success:boolean,trigger:loop.scheduler.exit_trigger,param:any)
---@alias loop.scheduler.NodeId string
---@alias loop.scheduler.StartNodeFn fun(id: loop.scheduler.NodeId, on_exit: fun(ok:boolean, reason:string|nil)): { terminate:fun() }|nil, string|nil
---@alias loop.scheduler.NodeEvent "start"|"stop"

---@alias loop.scheduler.NodeEventFn fun(id: loop.scheduler.NodeId, event: loop.scheduler.NodeEvent, success:boolean,trigger:loop.scheduler.exit_trigger,param:any)

---@class loop.scheduler.Node
---@field id loop.scheduler.NodeId
---@field deps loop.scheduler.NodeId[]?
---@field order "sequence"|"parallel"|nil

---@class loop.tools.Scheduler
---@field new fun(self:loop.tools.Scheduler):loop.tools.Scheduler
---@field _nodes table<loop.scheduler.NodeId, loop.scheduler.Node>
---@field _start_node loop.scheduler.StartNodeFn
---@field _running table<loop.scheduler.NodeId, { terminate:fun() }>
---@field _current_run_id any
---@field _pending_running integer
---@field _terminating boolean
---@field _run_id integer
local Scheduler = class()

---@param nodes loop.scheduler.Node[]
---@param root string
---@return boolean, string? -- returns true + node name if a cycle is found
local function _detect_loop(nodes, root)
    local node_map = {}
    for _, n in ipairs(nodes) do
        node_map[n.id] = n
    end

    local visiting = {}
    local visited = {}

    local function dfs(node_id)
        if visiting[node_id] then
            return true, node_id -- cycle detected
        end
        if visited[node_id] then
            return false
        end

        visiting[node_id] = true
        local node = node_map[node_id]
        if not node then
            visiting[node_id] = nil
            return false -- missing nodes are ignored here
        end

        for _, dep_id in ipairs(node.deps or {}) do
            local has_cycle, cycle_node = dfs(dep_id)
            if has_cycle then
                return true, cycle_node
            end
        end

        visiting[node_id] = nil
        visited[node_id] = true
        return false
    end

    return dfs(root)
end


--──────────────────────────────────────────────────────────────────────────────
-- Constructor
--──────────────────────────────────────────────────────────────────────────────
function Scheduler:init()
    self._nodes = {}
    ---@type {loop.scheduler.NodeId: {on_node_event:loop.scheduler.NodeEventFn,on_exit:loop.scheduler.exit_fn}[]}
    self._inflight = {} -- NodeId → list of waiting callbacks
    self._running = {}
    self._visiting = {}
    self._done = {}

    self._pending_running = 0
    self._current_run_id = nil
    self._terminating = false
    self._run_id = 0
end

--──────────────────────────────────────────────────────────────────────────────
-- Public API
--──────────────────────────────────────────────────────────────────────────────
---@param nodes loop.scheduler.Node[]
---@param root loop.scheduler.NodeId
---@param start_node loop.scheduler.StartNodeFn
---@param on_exit loop.scheduler.exit_fn
---@param on_node_event loop.scheduler.NodeEventFn
function Scheduler:start(nodes, root, start_node, on_node_event, on_exit)
    if self._current_run_id then
        vim.schedule(function()
            on_exit(false, "interrupt", "another schedule is running")
        end)
        return
    end

    -- Check for cycles before starting
    local has_cycle, cycle_node = _detect_loop(nodes, root)
    if has_cycle then
        vim.schedule(function()
            on_exit(false, "cycle", cycle_node)
        end)
        return
    end


    self._nodes = {}
    for _, n in ipairs(nodes) do
        self._nodes[n.id] = n
    end
    self._start_node = start_node

    self._run_id = self._run_id + 1
    local my_run = self._run_id

    ---@diagnostic disable-next-line: undefined-field
    self._current_run_id = {} --  a unique id
    self._visiting = {}
    self._running = {}
    self._done = {}
    self._inflight = {}
    self._pending_running = 0

    self:_run_node(self._current_run_id, root, on_node_event, function(ok, trigger, param)
        if my_run ~= self._run_id then return end
        on_exit(ok, trigger, param)
        self:_check_termination_complete()
    end)
end

function Scheduler:terminate()
    if self._terminating then return end
    self:_begin_termination()
end

--──────────────────────────────────────────────────────────────────────────────
-- Internal: lifecycle
--──────────────────────────────────────────────────────────────────────────────
function Scheduler:_begin_termination()
    if self._terminating then return end
    self._terminating = true

    -- Terminate running leaf nodes
    for _, ctl in pairs(self._running) do
        ctl.terminate()
    end

    -- Also fail any nodes still in dependency resolution
    for node_id, _ in pairs(self._visiting) do
        if self._inflight[node_id] then
            for _, cb in ipairs(self._inflight[node_id]) do
                cb.on_node_event(node_id, "stop", false, "interrupt")
                cb.on_exit(false, "interrupt")
            end
            self._inflight[node_id] = nil
        end
    end
    self._visiting = {}
    self:_check_termination_complete()
end

function Scheduler:_check_termination_complete()
    if not self._current_run_id then return end
    if self._pending_running > 0 then return end
    if next(self._visiting) then return end

    self._terminating = false
    self._current_run_id = nil
    self._running = {}
    self._visiting = {}
    self._done = {}
end

--──────────────────────────────────────────────────────────────────────────────
-- Internal: graph execution
--──────────────────────────────────────────────────────────────────────────────
---@param run_id any
---@param node_id loop.scheduler.NodeId
---@param on_node_event loop.scheduler.NodeEventFn
---@param on_exit loop.scheduler.exit_fn
function Scheduler:_run_node(run_id, node_id, on_node_event, on_exit)
    if self._terminating or run_id ~= self._current_run_id then
        on_exit(false, "interrupt")
        return
    end

    -- Already done → succeed immediately
    if self._done[node_id] then
        on_node_event(node_id, "stop", true, "node")
        on_exit(true, "node")
        return
    end

    if self._visiting[node_id] then
        on_node_event(node_id, "stop", false, "cycle")
        on_exit(false, "cycle", node_id)
        return
    end

    -- Already running → queue callback
    if self._inflight[node_id] then
        table.insert(self._inflight[node_id],
            {
                on_node_event = on_node_event,
                on_exit = on_exit,
            })
        return
    end

    local node = self._nodes[node_id]
    if not node then
        on_node_event(node_id, "stop", false, "invalid_node")
        on_exit(false, "invalid_node", node_id)
        return
    end

    self._visiting[node_id] = true
    self._inflight[node_id] = {
        {
            on_node_event = on_node_event,
            on_exit = on_exit,
        }
    }

    -- Run dependencies first
    self:_run_deps(run_id, node.deps or {}, node.order or "sequence", function(ok, trigger, param)
            self._visiting[node_id] = nil
            if not ok then
                if self._inflight[node_id] then
                    for _, cb in ipairs(self._inflight[node_id]) do
                        cb.on_node_event(node_id, "stop", false, "deps_failed")
                        cb.on_exit(false, "deps_failed")
                    end
                end
                self._inflight[node_id] = nil
                return
            end
            -- Node starts
            on_node_event(node_id, "start", true, "node")
            self:_run_leaf(run_id, node_id, function(ok2, trigger2, param2)
                if ok2 then self._done[node_id] = true end
                if self._inflight[node_id] then
                    for _, cb in ipairs(self._inflight[node_id]) do
                        cb.on_node_event(node_id, "stop", ok2, trigger2, param2)
                        cb.on_exit(ok2, trigger2, param2)
                    end
                end
                self._inflight[node_id] = nil
            end)
        end,
        on_node_event)
end

---@param run_id any
---@param deps loop.scheduler.NodeId[]
---@param order "sequence"|"parallel"
---@param on_exit loop.scheduler.exit_fn
---@param on_node_event loop.scheduler.NodeEventFn
function Scheduler:_run_deps(run_id, deps, order, on_exit, on_node_event)
    if #deps == 0 then
        on_exit(true, "node")
        return
    end
    if self._terminating then
        on_exit(false, "interrupt")
        return
    end
    if order == "parallel" then
        local remaining = #deps
        local failed = false
        for _, dep in ipairs(deps) do
            self:_run_node(run_id, dep, on_node_event, function(ok, trigger, param)
                if failed then return end
                if not ok then
                    failed = true
                    on_exit(false, trigger, param)
                    return
                end
                remaining = remaining - 1
                if remaining == 0 then
                    on_exit(true, "node")
                end
            end)
        end
    else
        local i = 1
        local function next_dep()
            if i > #deps then
                on_exit(true, "node")
                return
            end
            self:_run_node(run_id, deps[i], on_node_event, function(ok, trigger, param)
                if not ok then
                    on_exit(false, trigger, param)
                    return
                end
                i = i + 1
                next_dep()
            end)
        end
        next_dep()
    end
end

---@param run_id any
---@param id loop.scheduler.NodeId
---@param on_exit loop.scheduler.exit_fn
function Scheduler:_run_leaf(run_id, id, on_exit)
    if run_id ~= self._current_run_id then
        on_exit(false, "interrupt")
        return
    end
    self._pending_running = self._pending_running + 1

    local ctl, err = self._start_node(id, function(ok, reason)
        vim.schedule(function() -- important to schedule because on_exit my be called before the ctrl is returned
            self._running[id] = nil
            self._pending_running = math.max(0, self._pending_running - 1)
            self:_check_termination_complete()
            on_exit(ok, "node", reason)
        end)
    end)

    if not ctl then
        self._pending_running = math.max(0, self._pending_running - 1)
        self:_check_termination_complete()
        on_exit(false, "node", err or "Failed to start node")
        return
    end

    self._running[id] = ctl
end

function Scheduler:is_running() return self._current_run_id ~= nil end

function Scheduler:is_terminated() return self._current_run_id == nil end

function Scheduler:is_terminating() return self._terminating end

return Scheduler
