local class = require('loop.tools.class')
local Trackers = require('loop.tools.Trackers')
local throttle = require('loop.tools.throttle')

---@alias loop.comp.Keymaps table<string,loop.KeyMap>

---@class loop.comp.Tracker
---@field on_change fun()|nil
---@field on_delete fun()|nil

---@class loop.comp.BaseBufferOpts
---@field name string
---@field filetype string
---@field listed boolean
---@field bufhidden ""|"hide"|"wipe"

---@class loop.comp.BaseBuffer
---@field new fun(self: loop.comp.BaseBuffer, opts:loop.comp.BaseBufferOpts): loop.comp.BaseBuffer
local BaseBuffer = class()

---@param opts loop.comp.BaseBufferOpts
function BaseBuffer:init(opts)
    vim.validate("opts", opts, "table")
    vim.validate("opts.name", opts.name, "string")
    vim.validate("opts.filetype", opts.filetype, "string")
    vim.validate("opts.listed", opts.listed, "boolean")
    vim.validate("opts.bufhidden", opts.bufhidden, "string")
    assert(opts.bufhidden == "" or opts.bufhidden == "hide" or opts.bufhidden == "wipe",
        "Invalid bufhidden value in opts")
    self._filetype = opts.filetype
    self._name = opts.name
    self._listed = opts.listed
    self._bufhidden_action = opts.bufhidden
    self._keymaps = {}
    self._buf = -1

    self._trackers = Trackers:new()

    self._throttled_change_notif = throttle.throttle_wrap(100, function()
        self._trackers:invoke("on_change")
    end)
end

function BaseBuffer:destroy()
    if self._destroyed then
        return
    end
    self._destroyed = true
    if self._buf > 0 then
        if vim.v.exiting == vim.NIL then
            vim.api.nvim_buf_delete(self._buf, { force = true })
        end
    end
end

---@return loop.BaseBufferController
function BaseBuffer:make_controller()
    local obj = self
    ---@type loop.BaseBufferController
    return {
        set_user_data = function(user_data)
            obj:set_user_data(user_data)
        end,
        get_user_data = function()
            return obj:get_user_data()
        end,
        add_keymap = function(key, keymap)
            obj:add_keymap(key, keymap)
        end,
        disable_change_events = function()
            obj:disable_change_events()
        end
    }
end

function BaseBuffer:request_change_notif()
    if not self._no_change_events then
        self._throttled_change_notif()
    end
end

function BaseBuffer:set_user_data(data)
    self._user_data = data
end

function BaseBuffer:get_user_data()
    return self._user_data
end

---@param callbacks loop.comp.Tracker>
---@return loop.TrackerRef
function BaseBuffer:add_tracker(callbacks)
    return self._trackers:add_tracker(callbacks)
end

function BaseBuffer:disable_change_events()
    self._no_change_events = true
end

function BaseBuffer:_on_buf_enter()
    self:_apply_keymaps()
end

---@return string
function BaseBuffer:get_name()
    return self._name
end

---@return number -- buffer number
function BaseBuffer:get_buf()
    if self._destroyed then
        return -1
    end
    return self._buf
end

function BaseBuffer:is_destroyed()
    return self._destroyed
end

---@return number -- buffer number
---@return boolean refresh_needed
function BaseBuffer:get_or_create_buf()
    assert(not self._destroyed)

    if self._buf ~= -1 then
        local refresh_needed = false
        if not vim.api.nvim_buf_is_loaded(self._buf) then
            vim.fn.bufload(self._buf)
            self:_setup_buf()
            refresh_needed = true
        end
        return self._buf, refresh_needed
    end

    self._buf = vim.api.nvim_create_buf(false, true)
    self:_setup_buf()
    return self._buf, true
end

function BaseBuffer:_setup_buf()
    assert(self._buf > 0)
    assert(type(self._filetype) == "string" and self._filetype ~= "")

    local buf = self._buf

    local bufname = "loop://" .. self._name
    if vim.fn.bufexists(bufname) == 1 then
        bufname = "loop://" .. tostring(buf) .. '/' .. self._name
    end
    if vim.fn.bufexists(bufname) == 1 then
        ---@diagnostic disable-next-line: undefined-field
        local timestamp = ("%d"):format(vim.uv.hrtime())
        bufname = "loop://" .. tostring(buf) .. timestamp .. '/' .. self._name
    end

    vim.api.nvim_buf_set_name(buf, bufname)

    do
        local b = vim.bo[buf]
        b.buftype = "nofile"
        b.bufhidden = self._bufhidden_action
        b.filetype = self._filetype
        b.modifiable = false
        b.swapfile = false
        b.undolevels = -1          -- buffer can't become "modified"
        b.buflisted = self._listed -- hide from :ls
    end

    vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
        buffer = buf,
        once = true,
        callback = function(ev)
            assert(ev.buf == buf)
            self._buf = -1
            vim.schedule(function()
                self._trackers:invoke("on_delete")
            end)
        end,
    })

    vim.api.nvim_create_autocmd("BufEnter", {
        buffer = buf,
        callback = function(ev)
            assert(ev.buf == buf)
            self:_on_buf_enter()
        end
    })
end

---@param key string
---@param keymap loop.KeyMap
function BaseBuffer:add_keymap(key, keymap)
    assert(not self._keymaps[key])
    self._keymaps[key] = keymap
    self:_apply_keymap(key, keymap)
end

---@param keymaps table<string, loop.KeyMap>
function BaseBuffer:add_keymaps(keymaps)
    for key, keymap in pairs(keymaps) do
        assert(not self._keymaps[key])
        self._keymaps[key] = keymap
        self:_apply_keymap(key, keymap)
    end
end

function BaseBuffer:_apply_keymaps()
    if self._keymaps then
        for key, item in pairs(self._keymaps) do
            self:_apply_keymap(key, item)
        end
    end
end

---@param key string
---@param item loop.KeyMap
function BaseBuffer:_apply_keymap(key, item)
    if self._buf ~= -1 then
        local modes = { "n" }
        --local ok =
        pcall(function() vim.keymap.del(modes, key, { buffer = self._buf }) end)
        vim.keymap.set(modes, key, function() item.callback() end, { buffer = self._buf, desc = item.desc })
    end
end

return BaseBuffer
