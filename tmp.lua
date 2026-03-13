--
    -- track active buffer
    vim.api.nvim_create_autocmd("BufEnter", {
        callback = function()
            local buf = vim.api.nvim_get_current_buf()
            if vim.bo[buf].buftype ~= "" then return end

            local path = vim.api.nvim_buf_get_name(buf)
            if path ~= "" then
                self:reveal(path)
            end
        end
    })



---@return table?
local function _load_layout()
    if not _ws_data then return end
    local loaded, data = jsoncodec.load_from_file(vim.fs.joinpath(_ws_data.config_dir, "layout.json"))
    if not loaded then return end
    window.load_layout(data and data.window or {})
    sidepanel.load_layout(data and data.sidepanel or {})
    return data
end

local function _save_layout()
    if not _ws_data then
        return false
    end
    local filepath = vim.fs.joinpath(_ws_data.config_dir, "layout.json")
    local loaded, data = jsoncodec.load_from_file(filepath)
    local layout = loaded and data or {}
    layout.window = layout.window or {}
    layout.sidepanel = layout.sidepanel or {}
    window.save_layout(layout.window)
    sidepanel.save_layout(layout.sidepanel)
    jsoncodec.save_to_file(filepath, layout)
end
