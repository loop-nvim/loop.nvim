local uv = vim.loop

local class = require('loop.utils.class')
local utils = require('loop.utils.utils')

---@class loop.utils.Spinner
---@field frames string[]
---@field interval integer
---@diagnostic disable-next-line: undefined-doc-name
---@field cancel_timer fun()?
---@field frame integer
---@field running boolean
---@field on_update fun(frame:string, index:integer)?


local default_frames = {
    "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"
}


---@alias loop.utils.SpinnerOpts {frames?:string[], interval?:integer, on_update?:fun(frame:string, index:integer)}

---@class loop.utils.Spinner
---@field new fun(self:loop.utils.Spinner,opts:loop.utils.SpinnerOpts):loop.utils.Spinner
local Spinner = class()

---@param opts loop.utils.SpinnerOpts?
function Spinner:init(opts)
    opts = opts or {}
    self.frames = opts.frames or default_frames
    self.interval = opts.interval or 80
    self.cancel_timer = nil
    self.frame = 1
    self.running = false
    self.on_update = opts.on_update
end

function Spinner:start()
    if self.running then
        return
    end
    self.running = true
    self.cancel_timer = utils.start_timer(self.interval,
        vim.schedule_wrap(function()
            if not self.running then return end
            local frame = self.frames[self.frame]
            if self.on_update then self.on_update(frame, self.frame) end
            self.frame = (self.frame % #self.frames) + 1
        end))
end

function Spinner:stop()
    if not self.running then
        return
    end
    self.running = false
    if self.cancel_timer then self.cancel_timer() end
end

return Spinner
