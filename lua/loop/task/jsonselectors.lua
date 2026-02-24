local M = {}

local selector = require("loop.tools.selector")
local taskmgr = require("loop.task.taskmgr")

---@params task loop.Task
function M.select_taskobj(callback)
    taskmgr.select_task_template(callback)
end

function M.select_taskname(callback, data, path)
    local tasks = data and data.tasks
    if tasks then
        local choices = {}
        for _, task in ipairs(tasks) do
            --if cur_name ~= task.name then
            ---@type loop.SelectorItem
            local item = { label = task.name, data = task.name }
            if item.label then
                table.insert(choices, item)
            end
            --end
        end
        if #choices == 0 then
            callback(nil)
        else
            selector.select({
                prompt = "Select dependency",
                items = choices,
                callback = function(name)
                    if name then callback(name) end
                end
            })
        end
    else
        callback(nil)
    end
end

return M
