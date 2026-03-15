local M = {}

local uitools = require("loop.tools.uitools")
local strtools = require("loop.tools.strtools")
local picker = require('loop.tools.picker')
local filetools = require("loop.tools.file")

---@param result table LSP Reference result
---@param list_width number
---@return loop.SelectorItem
local function lsp_item_to_picker_item(result, list_width)
    local uri = result.uri or result.targetUri
    local range = result.range or result.targetSelectionRange
    local filepath = vim.uri_to_fname(uri)
    local lnum = range.start.line + 1
    local col = range.start.character + 1

    -- Get the text of the line to show in the picker
    -- Note: This is synchronous for the current buffer, but we might
    -- need to read from disk for other files.
    local line_text = ""
    if vim.uri_from_bufnr(0) == uri then
        line_text = vim.api.nvim_buf_get_lines(0, lnum - 1, lnum, false)[1] or ""
    else
        -- Fallback: read line from file (or leave empty if too slow)
        line_text = vim.fn.getbufline(vim.fn.bufnr(filepath), lnum)[1] or "[External File]"
    end

    line_text = vim.trim(line_text)
    local display_path = strtools.smart_crop_path(vim.fn.fnamemodify(filepath, ":."), list_width)

    return {
        label = line_text,
        virt_lines = { { { string.format("%s:%d", display_path, lnum), "Comment" } } },
        data = {
            filepath = filepath,
            lnum = lnum,
            col = col,
        }
    }
end

function M.open()
    local params = vim.lsp.util.make_position_params(0, 'utf-8')
    params.context = { includeDeclaration = true }

    -- Request references from LSP
    vim.lsp.buf_request(0, "textDocument/references", params, function(err, result, ctx, _)
        if err then
            vim.notify("LSP Error: " .. err.message, vim.log.levels.ERROR)
            return
        end

        if not result or vim.tbl_isempty(result) then
            vim.notify("No references found", vim.log.levels.INFO)
            return
        end

        -- Initialize the picker with the results
        picker.select({
            prompt = "LSP References",
            file_preview = true,
            -- Since the result is static, we don't use async_fetch (query-based)
            -- We pass the items directly via sync items or a simple fetcher
            fetch = function(query, fetch_opts)
                local items = {}
                for _, ref in ipairs(result) do
                    local item = lsp_item_to_picker_item(ref, fetch_opts.list_width)

                    -- Simple fuzzy filtering if user types in the picker
                    if query == "" or item.label:lower():find(query:lower(), 1, true) then
                        table.insert(items, item)
                    end
                end
                return items
            end,
            async_preview = function(item_data, _, callback)
                local data = item_data
                return filetools.async_load_text_file(data.filepath,
                    { max_size = 50 * 1024 * 1024, timeout = 3000 },
                    function(_, content)
                        callback(content, {
                            filepath = data.filepath,
                            lnum = data.lnum,
                            col = data.col
                        })
                    end)
            end,
        }, function(selected)
            if selected then
                uitools.smart_open_file(selected.filepath, selected.lnum, selected.col)
            end
        end)
    end)
end

return M
