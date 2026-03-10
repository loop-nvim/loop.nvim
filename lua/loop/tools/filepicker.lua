local M = {}

local Process = require("loop.tools.Process")
local uitools = require("loop.tools.uitools")
local strtools = require("loop.tools.strtools")
local filetools = require("loop.tools.file")
local picker = require('loop.tools.picker')

---@class loop.filepicker.fdopts
---@field cwd string The root directory for the search
---@field include_globs string[] List of glob patterns to include (filtered in Lua)
---@field exclude_globs string[] List of glob patterns for fd to ignore
---@field max_results number?

---@param query string
---@param opts loop.filepicker.fdopts
---@return string, string[],boolean
local function get_search_cmd(query, opts)
    if vim.fn.executable("fd") == 1 then
        local args = { "--type", "f", "--fixed-strings", "--color", "never" }
        -- fd ignores hidden files by default; use --hidden if you wanted them.
        if opts.exclude_globs then
            for _, glob in ipairs(opts.exclude_globs) do
                table.insert(args, "--exclude")
                table.insert(args, glob)
            end
        end
        table.insert(args, "--")
        table.insert(args, query)
        return "fd", args, true
    end

    -- Fallback to find
    -- Logic: find . -type f -not -path '*/.*' ...
    local args = { ".", "-type", "f" }

    -- 1. Ignore hidden files and directories (starts with a dot)
    table.insert(args, "-not")
    table.insert(args, "-path")
    table.insert(args, "*/.*")

    -- 2. Add explicit exclude globs
    if opts.exclude_globs then
        for _, glob in ipairs(opts.exclude_globs) do
            table.insert(args, "-not")
            table.insert(args, "-path")
            -- Wrapping in wildcards to match anywhere in the path
            table.insert(args, "*/" .. glob .. "/*")
        end
    end

    -- 3. Case-insensitive path search for the query
    if query and query ~= "" then
        table.insert(args, "-ipath")
        table.insert(args, "*" .. query .. "*")
    end

    return "find", args, false
end

---@param query string User input for literal string matching
---@param fd_opts loop.filepicker.fdopts Configuration for fd and filtering
---@param fetch_opts loop.Picker.AsyncFetcherOpts Layout constraints from the UI
---@param callback fun(items:loop.SelectorItem[]?) Called when new items are ready
---@return fun() cancel Function to kill the underlying process
local function async_fd_search(query, fd_opts, fetch_opts, callback)
    assert(fd_opts.cwd, "CWD must be provided for file searching")
    local cmd, args, exclude_globs_handled = get_search_cmd(query, fd_opts)
    -- 2. Pre-compile include globs into LPeg matchers
    -- LPeg is significantly faster than Vim Regex for high-frequency string matching.

    local function to_matchers(globs)
        local matchers = {}
        for _, glob in ipairs(globs or {}) do
            -- pcall handles invalid glob strings gracefully
            local ok, matcher = pcall(vim.glob.to_lpeg, glob)
            if ok then table.insert(matchers, matcher) end
        end
        return matchers
    end

    -- Refactored block
    local include_matchers = to_matchers(fd_opts.include_globs)
    local exclude_matchers = (not exclude_globs_handled) and to_matchers(fd_opts.exclude_globs) or {}

    local process
    local read_stop = false
    local count = 0
    local max_results = fd_opts.max_results or 10000

    local buffered_feed = strtools.create_line_buffered_feed(function(lines)
        local items = {}
        for _, line in ipairs(lines) do
            if read_stop then
                return
            end
            line = line:gsub("^%.[/]", "")
            local excluded = false
            for i = 1, #exclude_matchers do
                if exclude_matchers[i]:match(line) then
                    excluded = true
                    break
                end
            end
            if not excluded then
                -- LPeg Matching Logic
                local allowed = (#include_matchers == 0)
                if not allowed then
                    for i = 1, #include_matchers do
                        if include_matchers[i]:match(line) then
                            allowed = true
                            break
                        end
                    end
                end
                if allowed then
                    if count < max_results then
                        local path = vim.fs.joinpath(fd_opts.cwd, line)
                        table.insert(items, {
                            label = strtools.smart_crop_path(line, fetch_opts.list_width),
                            data = path,
                        })
                        count = count + 1
                    else
                        process:kill()
                        read_stop = true
                        break
                    end
                end
            end
        end
        if #items > 0 then
            vim.schedule(function()
                callback(items)
            end)
        end
    end)

    process = Process:new(cmd, {
        cwd = fd_opts.cwd,
        cmd = cmd,
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
            -- Optional exit handling
        end,
    })

    local start_ok, start_err = process:start()
    if not start_ok and start_err and #start_err > 0 then
        vim.notify_once(start_err, vim.log.levels.ERROR)
    end

    return function()
        if process then process:kill() end
    end
end

---@class loop.filepicker.opts
---@field cwd string? Optional directory to start search (defaults to getcwd)
---@field include_globs string[]? Optional patterns to filter visible files
---@field exclude_globs string[]? Optional patterns for fd to skip (e.g. .git, node_modules)

---Opens a file picker using fd for discovery and LPeg for glob filtering.
---@param opts loop.filepicker.opts?
function M.open(opts)
    opts = opts or {}

    ---@type loop.Picker.opts
    local selector_opts = {
        prompt = "Files",
        file_preview = true,
        async_fetch = function(query, fetch_opts, callback)
            -- We only search if there is a query, or you can remove this check
            -- to show all files in the CWD on open.
            if not query or query == "" then
                callback()
                return function() end
            end
            local fd_opts = {
                cwd = opts.cwd or vim.fn.getcwd(),
                include_globs = opts.include_globs or {},
                exclude_globs = opts.exclude_globs or { ".git", "node_modules", "target" },
            }
            return async_fd_search(query, fd_opts, fetch_opts, callback)
        end,
        async_preview = function(item_data, preview_opts, callback)
            local filepath = item_data
            local cancel_fn = filetools.async_load_text_file(filepath, { max_size = 50 * 1024 * 1024, timeout = 3000 },
                function(load_err, content)
                    callback(content, {
                        filepath = filepath
                    })
                end)
            return cancel_fn
        end
    }

    return picker.select(selector_opts, function(path)
        if path then
            uitools.smart_open_file(path)
        end
    end)
end

return M
