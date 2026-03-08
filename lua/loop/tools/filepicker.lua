local M = {}

local Process = require("loop.tools.Process")
local uitools = require("loop.tools.uitools")
local strtools = require("loop.tools.strtools")
local simple_selector = require('loop.tools.simpleselector')

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

    -- 1. Setup fd arguments.
    -- We use --fixed-strings for the query to ensure maximum performance and literal matching.
    local args = { "--type", "f", "--fixed-strings", "--color", "never" }

    if fd_opts.exclude_globs then
        for _, glob in ipairs(fd_opts.exclude_globs) do
            table.insert(args, "--exclude")
            table.insert(args, glob)
        end
    end

    table.insert(args, "--")
    table.insert(args, query)

    -- 2. Pre-compile include globs into LPeg matchers
    -- LPeg is significantly faster than Vim Regex for high-frequency string matching.
    ---@type table[]
    local matchers = {}
    if fd_opts.include_globs and #fd_opts.include_globs > 0 then
        for _, glob in ipairs(fd_opts.include_globs) do
            local matcher = vim.glob.to_lpeg(glob)
            table.insert(matchers, matcher)
        end
    end

    local count = 0
    local process
    process = Process:new("fd", {
        cwd = fd_opts.cwd,
        cmd = "fd",
        args = args,
        on_output = function(data, is_stderr)
            if not data then return end
            if is_stderr and #data > 0 then
                vim.notify_once(data, vim.log.levels.ERROR)
                return
            end

            local items = {}
            for line in data:gmatch("[^\r\n]+") do
                -- LPeg Matching Logic
                local allowed = (#matchers == 0)
                if not allowed then
                    for i = 1, #matchers do
                        if matchers[i]:match(line) then
                            allowed = true
                            break
                        end
                    end
                end

                if allowed then
                    if count < 1000 then
                        table.insert(items, {
                            label = line,
                            file = vim.fs.joinpath(fd_opts.cwd, line),
                            data = line,
                        })
                        count = count + 1
                    else
                        process:kill()
                        break
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
            -- Note: path here is 'item.data', which is the relative path from FD.
            -- We re-join with CWD to ensure the open command is absolute.
            local full_path = vim.fs.joinpath(opts.cwd or vim.fn.getcwd(), path)
            uitools.smart_open_file(full_path)
        end
    end)
end

return M
