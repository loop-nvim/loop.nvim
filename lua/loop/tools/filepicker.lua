local M = {}

local Process = require("loop.tools.Process")
local uitools = require("loop.tools.uitools")
local strtools = require("loop.tools.strtools")
local simple_selector = require('loop.tools.simpleselector')

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

---@class loop.filepicker.fdopts
---@field cwd string The root directory for the search
---@field include_globs string[] List of glob patterns to include (filtered in Lua)
---@field exclude_globs string[] List of glob patterns for fd to ignore

---@param query string User input for literal string matching
---@param fd_opts loop.filepicker.fdopts Configuration for fd and filtering
---@param fetch_opts loop.selector.AsyncFetcherOpts Layout constraints from the UI
---@param callback fun(items:loop.SelectorItem[]) Called when new items are ready
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

    local count = 0
    local process
    process = Process:new(cmd, {
        cwd = fd_opts.cwd,
        cmd = cmd,
        args = args,
        on_output = function(data, is_stderr)
            if not data then return end
            if is_stderr and #data > 0 then
                vim.notify_once(data, vim.log.levels.ERROR)
                return
            end
            local items = {}
            for line in data:gmatch("[^\r\n]+") do
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
                        if count < 1000 then
                            local path = vim.fs.joinpath(fd_opts.cwd, line)
                            table.insert(items, {
                                label = strtools.smart_crop_path(line, fetch_opts.list_width),
                                file = path,
                                data = path,
                            })
                            count = count + 1
                        else
                            process:kill()
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
        end,
        on_exit = function(code, signal)
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

    ---@type loop.selector.opts
    local selector_opts = {
        prompt = "Files",
        file_preview = true,
        async_fetch = function(query, fetch_opts, cb)
            -- We only search if there is a query, or you can remove this check
            -- to show all files in the CWD on open.
            if not query or query == "" then
                cb({})
                return function() end
            end

            local fd_opts = {
                cwd = opts.cwd or vim.fn.getcwd(),
                include_globs = opts.include_globs or {},
                exclude_globs = opts.exclude_globs or { ".git", "node_modules", "target" },
            }
            return async_fd_search(query, fd_opts, fetch_opts, cb)
        end
    }

    return simple_selector.select(selector_opts, function(path)
        if path then
            uitools.smart_open_file(path)
        end
    end)
end

return M
