local uv = vim.loop

local class = require('loop.tools.class')
local fntools = require('loop.tools.fntools')

---@class loop.tools.Spinner
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


---@alias loop.tools.SpinnerOpts {frames?:string[], interval?:integer, on_update?:fun(frame:string, index:integer)}

---@class loop.tools.Spinner
---@field new fun(self:loop.tools.Spinner,opts:loop.tools.SpinnerOpts):loop.tools.Spinner
local Spinner = class()

---@param opts loop.tools.SpinnerOpts?
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
    self.cancel_timer = fntools.start_timer(self.interval,
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
