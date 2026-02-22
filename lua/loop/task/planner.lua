local M = {}

---@param task_name string
---@param name_to_task table<string, loop.Task>
---@param visiting table<string, boolean>
---@param visited table<string, boolean>
---@return loop.TaskTreeNode? node, string? error
function M.build_task_tree(task_name, name_to_task, visiting, visited)
    -- True cycle (back-edge)
    if visiting[task_name] then
        return nil, "Cycle detected at task: " .. task_name
    end
    local task = name_to_task[task_name]
    if not task then
        return nil, "Unknown task: " .. task_name
    end
    -- Option B: already expanded elsewhere → return leaf
    if visited[task_name] then
        return {
            name = task.name,
            order = task.depends_order or "sequence",
            deps = {}, -- no re-expansion
        }, nil
    end
    visiting[task_name] = true
    local deps = {}
    for _, dep_name in ipairs(task.depends_on or {}) do
        local dep_node, err =
            M.build_task_tree(dep_name, name_to_task, visiting, visited)
        if err then
            return nil, err
        end
        table.insert(deps, dep_node)
    end
    visiting[task_name] = nil
    visited[task_name] = true
    return {
        name = task.name,
        order = task.depends_order or "sequence",
        deps = deps,
    }, nil
end

---@param tasks loop.Task[]
---@param root string
---@return loop.TaskTreeNode|nil task_tree
---@return loop.Task[]? used_tasks
---@return string? error_msg
function M.generate_task_plan(tasks, root)
    local name_to_task = {}
    for _, t in ipairs(tasks) do
        if name_to_task[t.name] then
            return nil, nil, "Duplicate task: " .. t.name
        end
        name_to_task[t.name] = t
    end
    local visited = {}
    local visiting = {}
    local tree, err = M.build_task_tree(root, name_to_task, visiting, visited)
    if err then return nil, nil, err end

    ---@type loop.Task[]
    local used_tasks = {}
    for name, _ in pairs(visited) do
        table.insert(used_tasks, name_to_task[name])
    end

    return tree, used_tasks, nil
end

---@param node table Task node from generate_task_plan_tree
---@param prefix? string Internal use for indentation
---@param is_last? boolean Internal use to determine tree branch
function M.print_task_tree(node, prefix, is_last)
    prefix = prefix or ""
    is_last = is_last or true

    local branch = is_last and "└─ " or "├─ "
    local line = prefix .. branch .. node.name .. " (" .. (node.order or "sequence") .. ")"
    local new_prefix = prefix .. (is_last and "   " or "│  ")
    if node.deps then
        for i, child in ipairs(node.deps) do
            line = line .. '\n' .. M.print_task_tree(child, new_prefix, i == #node.deps)
        end
    end
    return line
end

return M
