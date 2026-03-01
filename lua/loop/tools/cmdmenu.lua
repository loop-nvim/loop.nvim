local M = {}

local selector = require('loop.tools.selector')

---@class loop.tools.Cmd
---@field vimcmd string
---@field help string

---@param cmd_list loop.tools.Cmd[]
function M.select_and_run_command(cmd_list)
    local choices = {}
    for _, cmd in ipairs(cmd_list) do
        ---@type loop.SelectorItem
        local item = {
            label = cmd.vimcmd,
            data = cmd,
        }
        table.insert(choices, item)
    end
    selector.select({
            prompt = "Select command",
            items = choices,
        },
        function(cmd)
            if cmd then
                vim.cmd(cmd.vimcmd)
            end
        end
    )
end

return M
