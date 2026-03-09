local M = {}

local Process = require("loop.tools.Process")
local uitools = require("loop.tools.uitools")
local strtools = require("loop.tools.strtools")
local picker = require('loop.tools.picker')
local filetools = require("loop.tools.file")

---@class loop.livegrep.opts
---@field cwd string? Optional directory to start search (defaults to getcwd)
---@field include_globs string[]? Optional patterns to filter visible files
---@field exclude_globs string[]? Optional patterns for fd to skip (e.g. .git, node_modules)
---@field max_results number?

---@param query string
---@param opts loop.livegrep.opts
---@return string, string[]
local function get_grep_cmd(query, opts)
    if vim.fn.executable("rg") == 1 then
        local args = {
            "--column",
            "--line-number",
            "--no-heading",
            "--color", "never",
            "--smart-case",
            "--fixed-strings",
        }

        if opts.exclude_globs then
            for _, glob in ipairs(opts.exclude_globs) do
                table.insert(args, "-g")
                table.insert(args, "!" .. glob)
            end
        end

        table.insert(args, "--")
        table.insert(args, query)
        table.insert(args, ".")
        return "rg", args
    end

    -- Fallback to standard grep
    local args = { "-RIn", "--exclude-dir=.git" }

    if opts.exclude_globs then
        for _, glob in ipairs(opts.exclude_globs) do
            table.insert(args, "--exclude-dir=" .. glob)
            table.insert(args, "--exclude=" .. glob)
        end
    end

    table.insert(args, query)
    table.insert(args, ".")
    return "grep", args
end

---@param query string
---@param grep_opts loop.livegrep.opts
---@param fetch_opts loop.Picker.AsyncFetcherOpts
---@param callback fun(items:table[]?)
---@return fun() cancel
local function async_grep_search(query, grep_opts, fetch_opts, callback)
    local cmd, args = get_grep_cmd(query, grep_opts)
    local count = 0
    local process

    local max_results = grep_opts.max_results or 10000
    local read_stop = false

    local buffered_feed = strtools.create_line_buffered_feed(function(lines)
        local items = {}
        for _, line in ipairs(lines) do
            if read_stop then
                return
            end
            -- Pattern matches filename:line:column:text OR filename:line:text
            -- rg: file:line:col:content | grep: file:line:content
            local file, lnum, col, text = line:match("^(.-):(%d+):(%d+):(.*)$")
            if not file then
                file, lnum, text = line:match("^(.-):(%d+):(.*)$")
                col = "1"
            end
            local location = string.format("%s:%s", file, lnum)
            location = strtools.smart_crop_path(location, fetch_opts.list_width)
            if file and lnum then
                local abs_path = vim.fs.joinpath(grep_opts.cwd, file)
                ---@type loop.SelectorItem
                local item = {
                    -- Display label: "path/to/file:12: content of the line"
                    label_chunks = { { vim.fn.trim(text, "", 0), nil } },
                    virt_lines = { { { location, "Comment" } } },
                    file = abs_path,
                    lnum = tonumber(lnum),
                    col = tonumber(col),
                    data = abs_path
                }
                table.insert(items, item)
                count = count + 1
            end
            if count >= max_results then -- Cap results for performance
                process:kill()
                read_stop = true
                break
            end
        end
        if #items > 0 then
            vim.schedule(function() callback(items) end)
        end
    end)

    process = Process:new(cmd, {
        cmd = cmd,
        cwd = grep_opts.cwd,
        args = args,
        on_output = function(data, is_stderr)
            if read_stop then
                return
            end
            if not data then
                return
            end
            if is_stderr then
                vim.notify_once(data, vim.log.levels.ERROR)
                return
            end
            buffered_feed(data)
        end,
        on_exit = function(code, signal)
            callback(nil)
        end
    })

    local start_ok, start_err = process:start()
    if not start_ok and start_err and #start_err > 0 then
        callback(nil)
        vim.notify_once(start_err, vim.log.levels.ERROR)
    end

    return function()
        if process then process:kill() end
    end
end

---Opens a file picker using fd for discovery and LPeg for glob filtering.
---@param opts loop.livegrep.opts?
function M.live_grep(opts)
    opts = opts or {}
    local cwd = opts.cwd or vim.fn.getcwd()

    return picker.select({
        prompt = "Live Grep",
        file_preview = true,
        async_fetch = function(query, fetch_opts, callback)
            if not query or #query < 1 then -- Optimization: don't grep for 1 char
                callback()
                return function() end
            end
            return async_grep_search(query, {
                cwd = cwd,
                exclude_globs = opts.exclude_globs or {},
            }, fetch_opts, callback)
        end,
        async_preview = function(item_data, _, callback)
            local filepath = item_data
            local cancel_fn = filetools.async_load_text_file(filepath, { max_size = 50 * 1024 * 1024, timeout = 3000 },
                function(load_err, content)
                    callback(content)
                end)
            return cancel_fn
        end,
    }, function(selected)
        if selected then
            -- Open file and jump to line/column
            uitools.smart_open_file(selected.file)
            if selected.lnum then
                vim.api.nvim_win_set_cursor(0, { selected.lnum, (selected.col or 1) - 1 })
            end
        end
    end)
end

return M
