local extmarks = require("loop.extmarks")

local M = {}

-- ===================================================================
-- Types
-- ===================================================================

---@class loop.signs.Group
---@field define_sign fun(name:string, text:string, texthl:string)
---@field set_file_sign fun(id:number, file:string, lnum:number, name:string,user_data:any)
---@field remove_file_sign fun(id:number)
---@field remove_file_signs fun(file:string)
---@field remove_signs fun()
---@field get_signs fun(committed:boolean): loop.signs.SignInfo[]
---@field get_file_signs fun(file:string,committed:boolean): loop.signs.SignInfo[]
---@field get_sign_by_location fun(file:string, lnum:number, committed:boolean): loop.signs.SignInfo?
---@field get_sign_by_id fun(id:number): loop.signs.SignInfo?
---@field refresh fun()

---@class loop.signs.SignInfo
---@field id number
---@field file string
---@field name string
---@field lnum number
---@field priority number
---@field user_data any

-- ===================================================================
-- Public API
-- ===================================================================

---@param group string
---@param opts { priority:number }
---@return loop.signs.Group
function M.define_group(group, opts)
    assert(group, "group required")
    assert(opts and opts.priority, "priority required")

    local priority = opts.priority
    local sign_defs = {} ---@type table<string,{text:string,texthl:string}>

    local ext = extmarks.define_group(group, {
        priority = priority,
    })

    --------------------------------------------------------------------
    -- Internal: convert extmark → sign
    --------------------------------------------------------------------
    local function _convert_mark(mark)
        if not mark then return nil end

        local user = mark.user_data
        if not user or not user.name then
            return nil
        end

        return {
            id = mark.id,
            file = mark.file,
            name = user.name,
            lnum = mark.lnum,
            priority = priority,
            user_data = user.user_data,
        }
    end

    return {

        ----------------------------------------------------------------
        -- Define sign appearance
        ----------------------------------------------------------------
        define_sign = function(name, text, texthl)
            assert(name and text and texthl, "invalid sign definition")
            assert(not sign_defs[name], "sign already defined")

            sign_defs[name] = {
                text = text,
                texthl = texthl,
            }
        end,

        ----------------------------------------------------------------
        -- Place sign
        ----------------------------------------------------------------
        set_file_sign = function(id, file, lnum, name, user_data)
            assert(sign_defs[name], "sign not defined")
            assert(lnum >= 1, "lnum must be 1-based")

            local def = sign_defs[name]

            ext.set_file_extmark(
                id,
                file,
                lnum,
                0,
                {
                    sign_text = def.text,
                    sign_hl_group = def.texthl,
                },
                {
                    name = name,
                    user_data = user_data,
                }
            )
        end,

        ----------------------------------------------------------------
        -- Remove
        ----------------------------------------------------------------
        remove_file_sign = function(id)
            ext.remove_extmark(id)
        end,

        remove_file_signs = function(file)
            ext.remove_file_extmarks(file)
        end,

        remove_signs = function()
            ext.remove_extmarks()
        end,

        ----------------------------------------------------------------
        -- Get all signs
        ----------------------------------------------------------------
        get_signs = function(committed)
            local marks = ext.get_extmarks(committed)

            ---@type loop.signs.SignInfo[]
            local result = {}

            for _, mark in ipairs(marks) do
                local sign = _convert_mark(mark)
                if sign then
                    result[#result + 1] = sign
                end
            end

            return result
        end,

        get_file_signs = function(file, committed)
            local marks = ext.get_file_extmarks(file, committed)
            ---@type loop.signs.SignInfo[]
            local result = {}
            for _, mark in ipairs(marks) do
                local user = mark.user_data
                if user and user.name then
                    result[#result + 1] = {
                        id = mark.id,
                        file = mark.file,
                        name = user.name,
                        lnum = mark.lnum,
                        priority = priority,
                        user_data = user.user_data,
                    }
                end
            end
            return result
        end,

        ----------------------------------------------------------------
        -- Get by file + line  (NEW API)
        ----------------------------------------------------------------
        get_sign_by_location = function(file, lnum, committed)
            local mark = ext.get_extmark_by_location(file, lnum, committed)
            return _convert_mark(mark)
        end,

        ----------------------------------------------------------------
        -- Get by ID (O(1))
        ----------------------------------------------------------------
        get_sign_by_id = function(id)
            local mark = ext.get_extmark_by_id(id)
            return _convert_mark(mark)
        end,

        ----------------------------------------------------------------
        -- Refresh
        ----------------------------------------------------------------
        refresh = function()
            ext.refresh()
        end,
    }
end

return M
