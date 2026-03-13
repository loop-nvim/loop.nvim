local M = {}

local loopconfig = require('loop').config
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

local uv = vim.loop

-- Async recursive directory search
local function async_walk_dir(dir, query, include_globs, exclude_globs, max_results, on_chunk, on_done)
    max_results = max_results or 1000
    local results_count = 0
    local pending_dirs = { dir }

    local function is_excluded(path)
        for _, pat in ipairs(exclude_globs or {}) do
            if path:match(pat) then return true end
        end
        return false
    end

    local function is_included(path)
        if not include_globs or #include_globs == 0 then return true end
        for _, pat in ipairs(include_globs) do
            if path:match(pat) then return true end
        end
        return false
    end

    local function process_next_dir()
        if results_count >= max_results or #pending_dirs == 0 then
            vim.schedule(function()
                on_done()
            end)
            return
        end

        local path = table.remove(pending_dirs, 1)
        local fd = uv.fs_scandir(path)
        if fd then
            local chunk = {}
            while true do
                local name, type_ = uv.fs_scandir_next(fd)
                if not name then break end
                local full_path = vim.fs.joinpath(path, name)
                if type_ == "file" then
                    if full_path:lower():find(query:lower(), 1, true)
                        and is_included(full_path)
                        and not is_excluded(full_path)
                    then
                        table.insert(chunk, full_path)
                        results_count = results_count + 1
                        if results_count >= max_results then break end
                    end
                elseif type_ == "directory" then
                    table.insert(pending_dirs, full_path)
                end
            end
            if #chunk > 0 then
                vim.schedule(function()
                    on_chunk(chunk)
                end)
            end
        end

        -- Continue processing next directory in the next event loop tick
        vim.schedule(function()
            process_next_dir()
        end)
    end

    -- Start processing
    process_next_dir()

    -- Return a cancel function
    return function()
        pending_dirs = {}
    end
end

local function _build_label_chunks(display, query)
    local chunks = {}
    if query and query ~= "" then
        local lower_display = display:lower()
        local lower_query = query:lower()
        local start_idx = 1

        while true do
            local s, e = lower_display:find(lower_query, start_idx, true)
            if not s then
                if start_idx <= #display then
                    table.insert(chunks, { display:sub(start_idx) })
                end
                break
            end
            if s > start_idx then
                table.insert(chunks, { display:sub(start_idx, s - 1) })
            end
            table.insert(chunks, { display:sub(s, e), "Label" })
            start_idx = e + 1
        end
    else
        table.insert(chunks, { display })
    end
    return chunks
end

local function async_lua_search(query, fd_opts, fetch_opts, callback)
    local cancel_fn
    cancel_fn = async_walk_dir(
        fd_opts.cwd,
        query,
        fd_opts.include_globs,
        fd_opts.exclude_globs,
        fd_opts.max_results,
        function(chunk)
            local items = {}
            for _, path in ipairs(chunk) do
                local display = path:gsub("^" .. fd_opts.cwd .. "[/\\]?", "")
                table.insert(items,
                    {
                        label_chunks = _build_label_chunks(display, query),
                        data = path
                    })
            end
            callback(items)
        end,
        function()
            -- Finished
            callback(nil)
        end
    )
    return cancel_fn
end

---@param query string
---@param opts loop.filepicker.fdopts
---@return string?, string[]?
local function get_search_cmd(query, opts)
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
    return "fd", args
end

---@param query string User input for literal string matching
---@param fd_opts loop.filepicker.fdopts Configuration for fd and filtering
---@param fetch_opts loop.Picker.AsyncFetcherOpts Layout constraints from the UI
---@param callback fun(items:loop.SelectorItem[]?) Called when new items are ready
---@return fun() cancel Function to kill the underlying process
local function async_fd_search(query, fd_opts, fetch_opts, callback)
    assert(fd_opts.cwd, "CWD must be provided for file searching")
    local cmd, args = get_search_cmd(query, fd_opts)

    -- LPeg matchers for include/exclude globs
    local function to_matchers(globs)
        local matchers = {}
        for _, glob in ipairs(globs or {}) do
            local ok, matcher = pcall(vim.glob.to_lpeg, glob)
            if ok then table.insert(matchers, matcher) end
        end
        return matchers
    end

    local include_matchers = to_matchers(fd_opts.include_globs)

    local process
    local read_stop = false
    local count = 0
    local max_results = fd_opts.max_results or 1000

    local buffered_feed = strtools.create_line_buffered_feed(function(lines)
        local items = {}
        for _, line in ipairs(lines) do
            if read_stop then return end

            line = line:gsub("^%.[/]", "")

            -- Apply include globs
            local allowed = (#include_matchers == 0)
            if not allowed then
                for i = 1, #include_matchers do
                    if include_matchers[i]:match(line) then
                        allowed = true
                        break
                    end
                end
            end

            if not allowed then goto continue end

            if count < max_results then
                local path = vim.fs.joinpath(fd_opts.cwd, line)
                local display = strtools.smart_crop_path(line, fetch_opts.list_width)

                -- Build label_chunks with case-insensitive substring highlighting
                local chunks = _build_label_chunks(display, query)
                table.insert(items, {
                    label_chunks = chunks, -- use chunks instead of label
                    data = path,
                })
                count = count + 1
            else
                process:kill({
                    stop_read = true
                })
                read_stop = true
                break
            end

            ::continue::
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
            if read_stop then return end
            if not data then return end
            if is_stderr then
                vim.notify_once(data, vim.log.levels.ERROR)
                return
            end
            buffered_feed(data)
        end,
        on_exit = function()
            callback(nil)
        end,
    })

    local start_ok, start_err = process:start()
    if not start_ok and start_err and #start_err > 0 then
        vim.notify_once(start_err, vim.log.levels.ERROR)
    end

    return function()
        if process then
            process:kill({
                stop_read = true
            })
        end
    end
end
---@class loop.filepicker.opts
---@field cwd string? Optional directory to start search (defaults to getcwd)
---@field include_globs string[]? Optional patterns to filter visible files
---@field exclude_globs string[]? Optional patterns for fd to skip (e.g. .git, node_modules)
---@field history_provider loop.Picker.QueryHistoryProvider?
---@field max_results number?

---Opens a file picker using fd for discovery and LPeg for glob filtering.
---@param opts loop.filepicker.opts?
function M.open(opts)
    opts = opts or {}

    ---@type loop.Picker.opts
    local selector_opts = {
        prompt = "Files",
        file_preview = true,
        history_provider = opts.history_provider,
        async_fetch = function(query, fetch_opts, callback)
            -- We only search if there is a query, or you can remove this check
            -- to show all files in the CWD on open.
            if not query or query == "" then
                callback()
                return function() end
            end
            ---@type loop.filepicker.fdopts
            local fd_opts = {
                cwd = opts.cwd or vim.fn.getcwd(),
                include_globs = opts.include_globs or {},
                exclude_globs = opts.exclude_globs or { ".git", "node_modules", "target" },
                max_results = opts.max_results,
            }
            if loopconfig.use_fd_find then
                return async_fd_search(query, fd_opts, fetch_opts, callback)
            else
                return async_lua_search(query, fd_opts, fetch_opts, callback)
            end
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
