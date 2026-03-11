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