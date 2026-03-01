local M = {}

local simple_selector = require('loop.tools.simpleselector')

---@param opts loop.selector.opts
---@param callback loop.SelectorCallback
function M.select(opts, callback)
    return simple_selector.select(opts, callback)
end

return M
