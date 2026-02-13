local class        = require('loop.tools.class')
local ItemListComp = require('loop.comp.ItemList')
local config       = require("loop.config")

---@alias loop.task.TasksStatusComp.Item loop.comp.ItemList.Item

-- Example state-to-highlight mapping
local _highlights  = {
    pending = "LoopPluginTaskPending",
    running = "LoopPluginTaskRunning",
    success = "LoopPluginTaskSuccess",
    warning = "LoopPluginTaskWarning",
    failure = "LoopPluginTaskFailure",
}

vim.api.nvim_set_hl(0, _highlights.pending, { link = "Comment" })
vim.api.nvim_set_hl(0, _highlights.running, { link = "DiffChange" })
vim.api.nvim_set_hl(0, _highlights.success, { link = "DiffAdd" })
vim.api.nvim_set_hl(0, _highlights.warning, { link = "WarningMsg" })
vim.api.nvim_set_hl(0, _highlights.failure, { link = "ErrorMsg" })

local _line_id = 0

---@alias loop.comp.StatusComp.Status loop.TaskScheduler.TaskState?

---@param id any
---@param data table
---@return loop.comp.ItemList.Chunk[]
local function _item_formatter(id, data)
    local chunks = {}
    local symbols = config.current.window.symbols

    if data.log_message then
        local hl = data.log_level == vim.log.levels.ERROR and _highlights.failure or nil
        table.insert(chunks, { data.log_message, hl })
        return chunks
    end

    local hl = nil
    local icon = nil

    ---@type loop.comp.StatusComp.Status
    local status = data.status

    if status == "running" then
        icon = symbols.running
        hl = _highlights.running
    elseif status == "success" then
        icon = symbols.success
        hl = _highlights.success
    elseif status == "waiting" then
        icon = symbols.waiting
        hl = _highlights.pending
    elseif status == "failure" then
        icon = symbols.failure
        hl = _highlights.failure
    end

    -- icon prefix
    table.insert(chunks, { "[" .. (icon or "?") .. "]", hl })

    -- main name
    table.insert(chunks, { data.name })

    -- optional error message
    if type(data.error_msg) == "string" and #data.error_msg > 0 then
        table.insert(chunks, {" - "})
        table.insert(chunks, {data.error_msg, _highlights.failure })
    end

    return chunks
end


---@class loop.task.TasksStatusComp : loop.comp.ItemList
---@field new fun(self: loop.task.TasksStatusComp): loop.task.TasksStatusComp
local TasksStatusComp = class(ItemListComp)

function TasksStatusComp:init()
    ---@type loop.comp.ItemList.InitArgs
    local comp_args = {
        formatter = _item_formatter,
    }
    ItemListComp.init(self, comp_args)
end

---@param name string
---@param status loop.comp.StatusComp.Status
---@return number
function TasksStatusComp:add_task(name, status)
    _line_id = _line_id + 1
    local id = _line_id
    ---@type loop.comp.ItemList.Item
    local item = {
        id = _line_id,
        data = {
            name = name,
            status = status
        }
    }
    self:upsert_item(item, {
        index = 1
    })
    return id
end

---@param id number
---@param status loop.comp.StatusComp.Status
---@param msg string?
function TasksStatusComp:set_task_status(id, status, msg)
    local item = self:get_item(id)
    if item then
        item.data.status = status
        item.data.error_msg = msg
        self:refresh_content()
    end
end

return TasksStatusComp
