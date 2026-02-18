local M = {}

-- ===================================================================
-- Types
-- ===================================================================

---@class loop.extmarks.Mark
---@field id number
---@field group string
---@field ns number
---@field lnum number        -- 1-based
---@field col number        -- 0-based
---@field opts vim.api.keyset.set_extmark

---@alias loop.extmarks.ById table<number, loop.extmarks.Mark>
---@alias loop.extmarks.ByFile table<string, loop.extmarks.ById>

---@class loop.extmarks.GroupData
---@field ns number
---@field byfile loop.extmarks.ByFile
---@field id_to_file table<number, string>

---@class loop.extmarks.GroupInfo
---@field priority number
---@field update_handler fun(file:string,marks:loop.extmarks.ById)?
---@field data loop.extmarks.GroupData

---@type table<string, loop.extmarks.GroupInfo>
local _defined_groups = {}

local _init_done = false

-- ===================================================================
-- Helpers
-- ===================================================================

local function _normalize_file(file)
    return vim.fn.fnamemodify(file, ":p")
end

---@param file string
---@return integer
local function _get_loaded_bufnr(file)
    local bufnr = vim.fn.bufnr(file, false)
    return (bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr)) and bufnr or -1
end

---@param bufnr integer
---@param mark loop.extmarks.Mark
local function _place_extmark(bufnr, mark)
    if not vim.api.nvim_buf_is_loaded(bufnr) then return end

    local line_count = vim.api.nvim_buf_line_count(bufnr)
    if line_count == 0 then return end

    local lnum = math.max(1, math.min(mark.lnum, line_count))
    local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, true)[1] or ""
    local col = math.max(0, math.min(mark.col, #line))

    mark.lnum, mark.col = lnum, col

    assert(type(mark.id) == "number")
    local id = vim.api.nvim_buf_set_extmark(bufnr, mark.ns, lnum - 1, col, mark.opts)
    assert(id == mark.id)
end

---@param bufnr integer
---@param ns integer
local function _clear_buf_namespace(bufnr, ns)
    vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
end

---@param bufnr integer
---@param group string
local function _apply_buffer_extmarks(bufnr, group)
    local group_info = _defined_groups[group]
    assert(group_info)

    local file = vim.api.nvim_buf_get_name(bufnr)
    if file == "" then return end
    file = _normalize_file(file)

    local group_data = group_info.data
    local file_data = group_data.byfile[file]
    if not file_data then return end

    for _, mark in pairs(file_data) do
        _place_extmark(bufnr, mark)
    end
end

---@param group string
---@param file string
local function _notify_group_update(group, file)
    local group_info = _defined_groups[group]
    assert(group_info)

    if not group_info.update_handler then return end

    ---@type loop.extmarks.ById
    local update = {}

    local group_data = group_info.data
    local file_table = group_data.byfile[file]
    if file_table then
        for id, mark in pairs(file_table) do
            ---@type loop.extmarks.Mark
            update[id] = mark
        end
    end

    group_info.update_handler(file, update)
end

---@param bufnr number
local function _sync_file_extmarks(bufnr)
    local file = vim.api.nvim_buf_get_name(bufnr)
    if file == "" then return end
    file = _normalize_file(file)

    for group, group_info in pairs(_defined_groups) do
        local group_data = group_info.data
        local file_table = group_data.byfile[file]
        if not file_table then
            goto continue
        end

        local placed = vim.api.nvim_buf_get_extmarks(
            bufnr,
            group_data.ns,
            0,
            -1,
            { details = false }
        )

        for _, m in ipairs(placed) do
            local id, row, col = m[1], m[2], m[3]
            local mark = file_table[id]
            if mark then
                mark.lnum = row + 1
                mark.col = col
            end
        end

        _notify_group_update(group, file)

        ::continue::
    end
end


local function _ensure_init()
    if _init_done then return end
    _init_done = true

    local augroup = vim.api.nvim_create_augroup("loopplugin_extmarks", { clear = true })

    -- "BufWinEnter" most likely not needed, adding will cause double callback
    vim.api.nvim_create_autocmd({ "BufReadPost" }, {
        group = augroup,
        callback = function(ev)
            for group in pairs(_defined_groups) do
                _apply_buffer_extmarks(ev.buf, group)
            end
        end,
    })


    vim.api.nvim_create_autocmd("BufWritePost", {
        group = augroup,
        callback = function(ev)
            local bufnr = ev.buf
            _sync_file_extmarks(bufnr)
        end
    })
end

-- ===================================================================
-- Public API immplementation
-- ===================================================================

---@param id number
---@param file string
---@param lnum number        -- 1-based
---@param col number        -- 0-based
---@param group string
---@param opts vim.api.keyset.set_extmark       -- extmark opts
---@see vim.api.nvim_buf_set_extmark
local function _place_file_extmark(id, file, lnum, col, group, opts)
    _ensure_init()

    assert(lnum >= 1, "lnum must be 1-based")

    local group_info = _defined_groups[group]
    assert(group_info)

    file = _normalize_file(file)
    local bufnr = _get_loaded_bufnr(file)

    local group_data = group_info.data

    -- remove previous instance of this id
    local old_file = group_data.id_to_file[id]
    if old_file then
        local old_bufnr = _get_loaded_bufnr(old_file)
        if old_bufnr >= 0 then
            vim.api.nvim_buf_del_extmark(old_bufnr, group_data.ns, id)
        end
    end

    group_data.id_to_file[id] = file
    group_data.byfile[file] = group_data.byfile[file] or {}

    ---@type loop.extmarks.Mark
    local mark = {
        id = id,
        group = group,
        ns = group_data.ns,
        lnum = lnum, -- 1 based
        col = col,   -- 0 based
        opts = vim.tbl_extend("force", {
            id = id,
            priority = group_info.priority,
        }, opts or {}),
    }

    group_data.byfile[file][id] = mark

    if bufnr >= 0 then
        _place_extmark(bufnr, mark)
    end
end

---@param id number
---@param group string
local function _remove_extmark(id, group)
    _ensure_init()

    local group_info = _defined_groups[group]
    assert(group_info)

    local group_data = group_info.data
    if not group_data then return end

    local file = group_data.id_to_file[id]
    if not file then return end

    group_data.id_to_file[id] = nil

    local file_table = group_data.byfile[file]
    if not file_table then return end

    local bufnr = _get_loaded_bufnr(file)
    if bufnr >= 0 then
        vim.api.nvim_buf_del_extmark(bufnr, group_data.ns, id)
    end

    file_table[id] = nil
end

---@param file string
---@param group string
local function _remove_file_extmarks(file, group)
    _ensure_init()

    local group_info = _defined_groups[group]
    assert(group_info)

    file = _normalize_file(file)

    local group_data = group_info.data

    local file_table = group_data.byfile[file]
    if not file_table then return end

    for id in pairs(file_table) do
        group_data.id_to_file[id] = nil
    end

    group_data.byfile[file] = nil

    local bufnr = _get_loaded_bufnr(file)
    if bufnr >= 0 then
        _clear_buf_namespace(bufnr, group_data.ns)
    end
end

---@param group string
local function _remove_extmarks(group)
    _ensure_init()

    local group_info = _defined_groups[group]
    assert(group_info)

    local group_data = group_info.data
    if not group_data then return end

    for file in pairs(group_data.byfile) do
        local bufnr = _get_loaded_bufnr(file)
        if bufnr >= 0 then
            _clear_buf_namespace(bufnr, group_data.ns)
        end
    end

    group_data.byfile = {}
    group_data.id_to_file = {}
end

---@param group string
local function _refresh_group(group)
    _ensure_init()

    local group_info = _defined_groups[group]
    assert(group_info)

    local group_data = group_info.data

    for file in pairs(group_data.byfile) do
        local bufnr = _get_loaded_bufnr(file)
        if bufnr >= 0 then
            _clear_buf_namespace(bufnr, group_data.ns)
            _apply_buffer_extmarks(bufnr, group)
        end
    end
end

---@class loop.extmarks.GroupFunctions
---@field place_file_extmark fun(id:number, file:string,lnum:number,col:number,opts:vim.api.keyset.set_extmark )
---@field remove_extmarks fun()
---@field remove_extmark fun(id:number)
---@field remove_file_extmarks fun(file:string)
---@field refresh fun()

---@param group string
---@param opts { priority: number}
---@param on_update fun(file:string,marks:loop.extmarks.ById)?
---@return loop.extmarks.GroupFunctions
function M.define_group(group, opts, on_update)
    assert(group, "group required")
    assert(type(opts.priority) == "number", "missing opts")
    assert(not _defined_groups[group], "group already defined")
    ---@type loop.extmarks.GroupInfo
    local group_info = {
        priority = opts.priority,
        update_handler = on_update,
        data = {
            ns = vim.api.nvim_create_namespace("loopplugin_extmarks_" .. group),
            byfile = {},
            id_to_file = {},
        }
    }
    _defined_groups[group] = group_info
    ---@type loop.extmarks.GroupFunctions
    return {
        place_file_extmark = function(id, file, lnum, col, opts)
            _place_file_extmark(id, file, lnum, col, group, opts)
        end
        ,
        remove_extmark = function(id)
            _remove_extmark(id, group)
        end,
        remove_file_extmarks = function(file)
            _remove_file_extmarks(file, group)
        end,
        remove_extmarks = function()
            _remove_extmarks(group)
        end,
        refresh = function()
            _refresh_group(group)
        end
    }
end

return M
