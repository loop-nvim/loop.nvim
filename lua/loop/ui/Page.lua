local class = require('loop.tools.class')
local throttle = require('loop.tools.throttle')
local Trackers = require('loop.tools.Trackers')

---@class loop.pages.Page
---@field new fun(self: loop.pages.Page, basebuf:loop.comp.BaseBuffer): loop.pages.Page
---@field _renderer loop.CompRenderer|nil
local Page = class()

---@class loop.page.Tracker
---@field on_ui_flags_update fun()|nil
---@field on_change fun()|nil

---@param basebuf loop.comp.BaseBuffer
function Page:init(basebuf)
    self._basebuf = basebuf
    self._ui_flags = ""
    self._trackers = Trackers:new()
    self._throttled_ui_flags_notification = throttle.throttle_wrap(100, function()
        self._trackers:invoke("on_ui_flags_update")
    end)
    self._basebuf:add_tracker({
        on_change = function()
            self._trackers:invoke("on_change")
        end
    })
end

---@return string
function Page:get_name()
    return self._basebuf:get_name()
end

function Page:request_change_notif()
    self._basebuf:request_change_notif()
end

---@param callbacks loop.page.Tracker>
---@return loop.TrackerRef
function Page:add_tracker(callbacks)
    return self._trackers:add_tracker(callbacks)
end

---@return number -- buffer number
---@return boolean refresh_needed
function Page:get_or_create_buf()
    return self._basebuf:get_or_create_buf()
end

---@return number -- buffer number
function Page:get_buf()
    return self._basebuf:get_buf()
end

---@return string
function Page:get_ui_flags()
    return self._ui_flags
end

function Page:destroy()
    self._basebuf:destroy()
end

---@param keymaps table<string, loop.KeyMap>
function Page:add_keymaps(keymaps)
    self._basebuf:add_keymaps(keymaps)
end

---@param str string
function Page:set_ui_flags(str)
    self._ui_flags = str
    self._throttled_ui_flags_notification()
end

---@return loop.PageController
function Page:make_controller()
    ---@type loop.PageController
    return {
        set_ui_flags = function(flags)
            self:set_ui_flags(flags)
        end,
    }
end

return Page
