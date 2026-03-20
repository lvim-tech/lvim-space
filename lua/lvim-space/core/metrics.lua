-- lua/lvim-space/core/metrics.lua
-- In-memory metrics collection for lvim-space.
--
-- Architecture
-- ============
-- metrics.setup() is called once from init.lua.  It initialises the stats
-- table, subscribes handle_debug() to the "debug" event emitted by
-- utils/debug.lua, and starts the optional auto-save timer.
--
-- Key metrics recorded:
--   • Session activity  – tab switches, workspace switches, session restores,
--                         files opened, state saves.
--   • Debug messages    – count by log level + top message-type buckets.
--   • Performance       – timing samples from start_measure/end_measure.
--   • Errors            – total count and breakdown by error type.
--
-- Display
-- =======
-- :LvimSpaceMetrics       – static report window  (keymaps: r R y s l q)
-- :LvimSpaceMetrics live  – auto-refreshing window (keymaps: r s q)

local events = require("lvim-space.core.events")
local levels = require("lvim-space.utils.levels")
local notify = require("lvim-space.utils.notify")
local config = require("lvim-space.config")

-- ============================================================================
-- Configuration helpers
-- ============================================================================

--- Read a value from config.metrics with a fallback default.
---@param key     string
---@param default any
---@return any
local function mcfg(key, default)
    local m = config.metrics
    return (m and m[key] ~= nil) and m[key] or default
end

-- ============================================================================
-- Module-level constants (resolved lazily so config can be patched by setup())
-- ============================================================================

--- Known error categories used in record_error().
local ERROR_TYPES = {
    OTHER = "other",
    NOT_FOUND = "not_found",
    PERMISSION = "permission",
    IO = "io",
}

--- Event name emitted by utils/debug.lua that this module subscribes to.
local EVENT_DEBUG = "debug"

-- Performance-sensitive aliases
local os_time = os.time
local os_difftime = os.difftime
local math_floor = math.floor
local math_min = math.min
local math_max = math.max
local table_concat = table.concat
local str_format = string.format
local vim_uv = vim.uv or vim.loop

-- ============================================================================
-- Module table
-- ============================================================================

---@class LvimSpace.Metrics
---@field stats            LvimSpace.MetricsStats|nil  Live statistics (nil before setup())
---@field _current_measure table|nil                   Active start_measure() context
local M = {
    stats = nil,
    _current_measure = nil,
}

-- ============================================================================
-- Stats structure
-- ============================================================================

---@class LvimSpace.MetricsSession
---@field tab_switches        integer  Number of successful tab switches
---@field workspace_switches  integer  Number of workspace switches
---@field session_restores    integer  Number of tab-state restores
---@field files_opened        integer  Cumulative files opened via restore
---@field start_time          integer  Unix timestamp of session start

---@class LvimSpace.MetricsPerf
---@field load_times  number[]  Timing samples in milliseconds (capped at 1 000)
---@field slowest     {name:string, time:number}  Single slowest operation

---@class LvimSpace.MetricsErrors
---@field total   integer              Total error count
---@field by_type table<string,integer> Count per ERROR_TYPES bucket

---@class LvimSpace.MetricsOperations
---@field total_saves integer  Number of successful state saves

---@class LvimSpace.MetricsTimeline
---@field operations  {name:string, duration:number, timestamp:integer}[]
---@field max_entries integer

---@class LvimSpace.MetricsStats
---@field session     LvimSpace.MetricsSession
---@field by_level    table<integer,integer>   Message count per vim.log.levels value
---@field msg_types   table<string,integer>    Message count per type-key
---@field msg_examples table<string,{messages:string[],timestamp:integer}>
---@field performance LvimSpace.MetricsPerf
---@field errors      LvimSpace.MetricsErrors
---@field operations  LvimSpace.MetricsOperations
---@field timestamps  {start:integer, last_reset:integer}
---@field timeline    LvimSpace.MetricsTimeline

--- Allocate a fresh, zeroed stats structure.
---@return LvimSpace.MetricsStats
local function create_stats()
    local L = vim.log.levels
    return {
        session = {
            tab_switches = 0,
            workspace_switches = 0,
            session_restores = 0,
            files_opened = 0,
            start_time = os_time(),
        },
        -- One counter per vim.log.levels value (0/1/2/3/4)
        by_level = {
            [L.DEBUG] = 0,
            [L.INFO] = 0,
            [L.WARN] = 0,
            [L.ERROR] = 0,
        },
        msg_types = {},
        msg_examples = {},
        performance = {
            load_times = {},
            slowest = { name = "", time = 0 },
        },
        errors = {
            total = 0,
            by_type = {},
        },
        operations = {
            total_saves = 0,
        },
        timestamps = {
            start = os_time(),
            last_reset = os_time(),
        },
        timeline = {
            operations = {},
            max_entries = 100,
        },
    }
end

-- ============================================================================
-- Private helpers
-- ============================================================================

--- Derive a short type-key from the first 1–3 words of a message.
--- Used to bucket similar messages together in msg_types.
---@param msg string
---@return string
local function get_message_type(msg)
    local words = {}
    for word in msg:gmatch("%S+") do
        words[#words + 1] = word
        if #words >= 3 then
            break
        end
    end
    if #words >= 3 then
        return table_concat(words, " ") .. "..."
    end
    return msg:sub(1, 30) .. (#msg > 30 and "..." or "")
end

--- Store up to max_examples example strings per message-type bucket.
--- Older examples are evicted after 1 hour to prevent stale data.
---@param msg_type string  Key returned by get_message_type()
---@param msg      string  Original message
local function store_example(msg_type, msg)
    local max = mcfg("max_examples", 3)
    local slot = M.stats.msg_examples[msg_type]
    local now = os_time()

    if not slot then
        M.stats.msg_examples[msg_type] = { messages = { msg }, timestamp = now }
    elseif #slot.messages < max then
        slot.messages[#slot.messages + 1] = msg
    elseif now - slot.timestamp > 3600 then
        -- Rotate after one hour so stale examples don't pile up
        slot.messages = { msg }
        slot.timestamp = now
    end
end

--- Build a unicode sparkline string from an array of numeric values.
--- Only the most recent `max_width` samples are rendered.
---@param values    number[]
---@param max_width integer   Maximum character width of the output (default 30)
---@return string
local function generate_sparkline(values, max_width)
    max_width = max_width or 30
    if #values == 0 then
        return ""
    end

    local max_val = 0
    for _, v in ipairs(values) do
        max_val = math_max(max_val, v)
    end
    if max_val == 0 then
        return ""
    end

    local chars = { "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█" }
    local result = {}

    for i = 1, math_min(max_width, #values) do
        local idx = #values - max_width + i
        if idx >= 1 then
            local normalized = values[idx] / max_val
            local char_idx = math_floor(normalized * (#chars - 1)) + 1
            result[#result + 1] = chars[char_idx]
        end
    end

    return table_concat(result)
end

--- Extract a millisecond duration from a debug message (pattern: "NNms").
--- Records it in the performance sparkline and the operation timeline.
---@param msg string
local function record_performance_from_msg(msg)
    local duration = tonumber(msg:match("(%d+)ms"))
    if not duration then
        return
    end

    local times = M.stats.performance.load_times
    times[#times + 1] = duration
    -- Keep ring buffer bounded at 1 000 entries
    if #times > 1000 then
        table.remove(times, 1)
    end

    M.record_operation("debug_timing", duration)
end

--- Classify an error message into an ERROR_TYPES bucket.
---@param msg string
local function record_error_from_msg(msg)
    local error_type = (msg:match("not found") and ERROR_TYPES.NOT_FOUND)
        or (msg:match("permission") and ERROR_TYPES.PERMISSION)
        or (msg:match("%bio%b") and ERROR_TYPES.IO)
        or ERROR_TYPES.OTHER
    M.record_error(nil, error_type)
end

-- ============================================================================
-- Public API – debug message handler (called via event bus)
-- ============================================================================

--- Process a debug message emitted by utils/debug.lua.
--- Updates level counters, message-type buckets, performance, and errors.
---@param msg   string
---@param level string|integer vim.log.levels constant
function M.handle_debug(msg, level)
    if not M.stats then
        return
    end

    -- Count by severity level
    local level_num = type(level) == "string" and levels.to_level_number(level) or level
    M.stats.by_level[level_num] = (M.stats.by_level[level_num] or 0) + 1

    -- Bucket by message type and store an example
    local msg_type = get_message_type(msg)
    M.stats.msg_types[msg_type] = (M.stats.msg_types[msg_type] or 0) + 1
    store_example(msg_type, msg)

    -- Extract timing samples when the message contains "NNms"
    if msg:find("%d+ms") then
        record_performance_from_msg(msg)
    end

    -- Promote ERROR-level messages to the error counter
    if level_num >= vim.log.levels.ERROR then
        record_error_from_msg(msg)
    end
end

-- ============================================================================
-- Public API – direct recording (called by session.lua / workspaces.lua)
-- ============================================================================

--- Record an error with an optional error-type classification.
---@param _manager_type? string  Reserved for future per-subsystem breakdowns
---@param error_type?    string  One of the ERROR_TYPES constants
function M.record_error(_manager_type, error_type)
    if not M.stats then
        return
    end
    M.stats.errors.total = M.stats.errors.total + 1
    local et = error_type or ERROR_TYPES.OTHER
    M.stats.errors.by_type[et] = (M.stats.errors.by_type[et] or 0) + 1
end

--- Record a named operation and its duration in the timeline.
--- Also updates hourly trends.
---@param name     string
---@param duration number  Duration in milliseconds
function M.record_operation(name, duration)
    if not M.stats then
        return
    end
    local tl = M.stats.timeline
    tl.operations[#tl.operations + 1] = {
        name = name,
        duration = duration,
        timestamp = os_time(),
    }
    -- Evict oldest entry when the ring buffer is full
    if #tl.operations > tl.max_entries then
        table.remove(tl.operations, 1)
    end
end

--- Mark the start of a timed operation.
--- Call end_measure() to complete the measurement.
---@param name string  Descriptive label for the operation
function M.start_measure(name)
    M._current_measure = {
        name = name,
        start = vim_uv.hrtime(),
    }
end

--- Complete a timed operation started with start_measure().
--- Records the duration in the performance sparkline and the timeline.
---@return number duration  Elapsed time in milliseconds
function M.end_measure()
    if not M._current_measure then
        return 0
    end
    if not M.stats then
        M._current_measure = nil
        return 0
    end

    local duration = (vim_uv.hrtime() - M._current_measure.start) / 1e6
    local times = M.stats.performance.load_times
    times[#times + 1] = duration
    if #times > 1000 then
        table.remove(times, 1)
    end

    -- Track the single slowest operation seen so far
    if duration > M.stats.performance.slowest.time then
        M.stats.performance.slowest = { name = M._current_measure.name, time = duration }
    end

    M.record_operation(M._current_measure.name, duration)
    M._current_measure = nil
    return duration
end

--- Increment the state-save counter.
--- Called by session.save_current_state() on every successful write.
function M.record_save()
    if not M.stats then
        return
    end
    M.stats.operations.total_saves = M.stats.operations.total_saves + 1
end

-- ============================================================================
-- Computed getters
-- ============================================================================

--- Average duration of all recorded timing samples (milliseconds).
---@return number
function M.get_avg_load_time()
    if not M.stats then
        return 0
    end
    local times = M.stats.performance.load_times
    if #times == 0 then
        return 0
    end
    local sum = 0
    for i = 1, #times do
        sum = sum + times[i]
    end
    return math_floor((sum / #times) * 100) / 100
end

--- Error rate as a percentage of total meaningful operations.
---@return number
function M.get_error_rate()
    local s = M.stats
    if not s then
        return 0
    end
    local total_ops = s.session.tab_switches
        + s.session.workspace_switches
        + s.session.files_opened
        + s.operations.total_saves
    return total_ops == 0 and 0 or math_floor((s.errors.total / total_ops) * 10000) / 100
end

--- Top N message-type buckets sorted by count descending.
---@param  n? integer  Number of results (default: config.metrics.max_top_messages)
---@return {type:string, count:integer}[]
function M.get_top_message_types(n)
    if not M.stats then
        return {}
    end
    n = n or mcfg("max_top_messages", 5)
    local sorted = {}
    for msg_type, count in pairs(M.stats.msg_types) do
        sorted[#sorted + 1] = { type = msg_type, count = count }
    end
    table.sort(sorted, function(a, b)
        return a.count > b.count
    end)
    local result = {}
    for i = 1, math_min(n, #sorted) do
        result[i] = sorted[i]
    end
    return result
end

--- Reset all statistics while preserving the original session start time.
function M.reset()
    if not M.stats then
        return
    end
    local original_start = M.stats.timestamps.start
    M.stats = create_stats()
    M.stats.timestamps.start = original_start
    M.stats.timestamps.last_reset = os_time()
end

-- ============================================================================
-- Persistence (save / load)
-- ============================================================================

--- Recursively prepare a Lua value for vim.json.encode().
--- Sparse arrays (e.g. by_level uses vim.log.levels as keys: 0,1,2,4)
--- are converted to string-keyed objects to avoid encoding errors.
---@param val any
---@return any
local function prepare_for_json(val)
    if type(val) ~= "table" then
        return val
    end

    local n, count = #val, 0
    for _ in pairs(val) do
        count = count + 1
    end

    if n > 0 and n == count then
        -- Dense array: recurse values only
        local out = {}
        for i, v in ipairs(val) do
            out[i] = prepare_for_json(v)
        end
        return out
    else
        -- Sparse array or map: stringify all keys
        local out = {}
        for k, v in pairs(val) do
            out[tostring(k)] = prepare_for_json(v)
        end
        return out
    end
end

--- Default path for the metrics JSON file.
---@return string
local function default_metrics_path()
    return vim.fn.stdpath("data") .. "/lvim-space-metrics.json"
end

--- Persist current stats to a JSON file.
---@param filepath? string  Destination path (default: stdpath("data")/lvim-space-metrics.json)
function M.save(filepath)
    filepath = filepath or default_metrics_path()

    local ok, encoded = pcall(vim.json.encode, prepare_for_json(M.stats))
    if not ok or not encoded then
        notify(str_format("Metrics encode failed: %s", tostring(encoded)), vim.log.levels.ERROR)
        return
    end

    local file, err = io.open(filepath, "w")
    if not file then
        notify(str_format("Metrics file open failed: %s", tostring(err)), vim.log.levels.ERROR)
        return
    end

    local write_ok, write_err = pcall(function()
        file:write(encoded)
        file:close()
    end)

    if write_ok then
        notify(str_format("Metrics saved to %s", filepath), vim.log.levels.INFO)
    else
        notify(str_format("Metrics write failed: %s", tostring(write_err)), vim.log.levels.ERROR)
    end
end

--- Load previously saved stats from a JSON file.
--- Replaces the current in-memory stats on success.
---@param filepath? string  Source path (default: stdpath("data")/lvim-space-metrics.json)
function M.load(filepath)
    filepath = filepath or default_metrics_path()

    local f = io.open(filepath, "r")
    if not f then
        notify(str_format("No metrics file at %s", filepath), vim.log.levels.WARN)
        return
    end

    local content = f:read("*a")
    f:close()

    if not content or content == "" then
        notify("Metrics file is empty", vim.log.levels.ERROR)
        return
    end

    local ok, data = pcall(vim.json.decode, content)
    if ok and type(data) == "table" then
        M.stats = data
        notify(str_format("Metrics loaded from %s", filepath), vim.log.levels.INFO)
    else
        notify(str_format("Metrics parse failed: %s", tostring(data)), vim.log.levels.ERROR)
    end
end

-- ============================================================================
-- Report generation
-- ============================================================================

--- Build a Markdown-formatted metrics report string.
---@return string
function M.report()
    local s = M.stats
    if not s then
        return "No metrics available (setup not called)."
    end

    local lines = {}
    local function add(...)
        for i = 1, select("#", ...) do
            lines[#lines + 1] = select(i, ...)
        end
    end
    local duration = os_difftime(os_time(), s.session.start_time)
    local uptime = str_format("%dm %ds", math_floor(duration / 60), duration % 60)

    -- Header
    add("# LvimSpace Metrics", "")

    -- Session activity
    add("## Session", "")
    add(str_format("- **Uptime:** %s", uptime))
    add(str_format("- **Tab switches:** %d", s.session.tab_switches))
    add(str_format("- **Workspace switches:** %d", s.session.workspace_switches))
    add(str_format("- **Session restores:** %d", s.session.session_restores))
    add(str_format("- **Files opened:** %d", s.session.files_opened))
    add(str_format("- **State saves:** %d", s.operations.total_saves))
    add("")

    -- Log-level counters
    add("## Messages", "")
    for _, name in ipairs({ "DEBUG", "INFO", "WARN", "ERROR" }) do
        local val = vim.log.levels[name]
        add(str_format("- **%s:** %d", name, s.by_level[val] or 0))
    end
    add("")

    -- Top message-type buckets
    local top_msgs = M.get_top_message_types()
    if #top_msgs > 0 then
        add(str_format("### Top %d Message Types", #top_msgs), "")
        add("| # | Type | Count |")
        add("|---|------|-------|")
        for i, item in ipairs(top_msgs) do
            local display = #item.type > 50 and item.type:sub(1, 47) .. "..." or item.type
            add(str_format("| %d | %s | %d |", i, display, item.count))
        end
        -- Show examples for the most common type
        local top_examples = s.msg_examples[top_msgs[1].type]
        if top_examples and top_examples.messages then
            add("", "### Examples (top type)", "")
            for i, ex in ipairs(top_examples.messages) do
                add(str_format("%d. `%s`", i, ex))
            end
        end
        add("")
    end

    -- Performance sparkline
    if #s.performance.load_times > 0 then
        add("## Performance", "")
        add(str_format("- **Avg time:** %.2f ms", M.get_avg_load_time()))
        if s.performance.slowest.time > 0 then
            add(str_format("- **Slowest:** `%s` (%.2f ms)", s.performance.slowest.name, s.performance.slowest.time))
        end
        local recent = {}
        local from = math_max(1, #s.performance.load_times - 50)
        for i = from, #s.performance.load_times do
            recent[#recent + 1] = s.performance.load_times[i]
        end
        if #recent > 0 then
            add(str_format("- **Trend:** %s", generate_sparkline(recent, 30)))
        end
        add("")
    end

    -- Errors
    if s.errors.total > 0 then
        add("## Errors", "")
        add(str_format("- **Total:** %d", s.errors.total))
        add(str_format("- **Rate:** %.1f%%", M.get_error_rate()))
        if next(s.errors.by_type) then
            add("### By Type", "")
            for err_type, count in pairs(s.errors.by_type) do
                add(str_format("- **%s:** %d", err_type, count))
            end
        end
        add("")
    end

    add(str_format("*Reset at: %s*", os.date("%H:%M:%S", s.timestamps.last_reset)))
    return table_concat(lines, "\n")
end

-- ============================================================================
-- Floating window display
-- ============================================================================

--- Open a centred floating window displaying `content`.
--- Returns buf and win handles.
---@param title   string
---@param content string
---@return integer buf
---@return integer win
local function open_float(title, content)
    local api = vim.api
    local buf = api.nvim_create_buf(false, true)
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].filetype = "markdown"

    local raw_lines = vim.split(content, "\n")
    local width = math_min(90, math_max(60, vim.o.columns - 10))
    local height = math_min(40, math_max(10, #raw_lines + 2))
    local row = math_floor((vim.o.lines - height) / 2)
    local col = math_floor((vim.o.columns - width) / 2)

    local win = api.nvim_open_win(buf, true, {
        relative = "editor",
        width = width,
        height = height,
        row = row,
        col = col,
        style = "minimal",
        border = "rounded",
        title = " " .. title .. " ",
        title_pos = "center",
    })

    vim.bo[buf].modifiable = true
    api.nvim_buf_set_lines(buf, 0, -1, false, raw_lines)
    vim.bo[buf].modifiable = false

    -- Universal close keymaps
    local opts = { buffer = buf, silent = true, nowait = true }
    vim.keymap.set("n", "q", function()
        api.nvim_win_close(win, true)
    end, opts)
    vim.keymap.set("n", "<ESC>", function()
        api.nvim_win_close(win, true)
    end, opts)

    return buf, win
end

--- Replace buffer content without moving the cursor unnecessarily.
---@param buf     integer
---@param content string
---@return boolean  true if the buffer was still valid and was updated
local function update_buf(buf, content)
    if not vim.api.nvim_buf_is_valid(buf) then
        return false
    end
    local lines = vim.split(content, "\n")
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    return true
end

--- Open a static metrics window.
---
--- Keymaps inside the window:
---   r  – refresh report
---   R  – reset stats then refresh
---   y  – yank report to system clipboard
---   s  – save stats to disk
---   l  – load stats from disk then refresh
---   q / <ESC> – close
---
---@return integer|nil buf
---@return integer|nil win
function M.show()
    local buf, win = open_float("LvimSpace Metrics", M.report())
    if not buf then
        return nil, nil
    end

    local opts = { buffer = buf, silent = true, nowait = true }

    vim.keymap.set("n", "r", function()
        vim.api.nvim_win_close(win, true)
        M.show()
    end, opts)

    vim.keymap.set("n", "y", function()
        vim.fn.setreg("+", M.report())
        notify("Metrics copied to clipboard", vim.log.levels.INFO)
    end, opts)

    vim.keymap.set("n", "R", function()
        M.reset()
        vim.api.nvim_win_close(win, true)
        M.show()
    end, opts)

    vim.keymap.set("n", "s", function()
        M.save()
    end, opts)

    vim.keymap.set("n", "l", function()
        M.load()
        vim.api.nvim_win_close(win, true)
        M.show()
    end, opts)

    return buf, win
end

--- Open a live-refreshing metrics window.
---
--- Keymaps inside the window:
---   r        – force immediate refresh
---   s        – save stats to disk
---   q / <ESC> – stop timer and close
---
---@param refresh_interval? integer  Seconds between auto-refreshes (default: config value)
---@return integer buf
---@return integer win
function M.show_live(refresh_interval)
    refresh_interval = refresh_interval or mcfg("default_refresh_interval", 2)

    local buf, win = open_float("LvimSpace Metrics (live)", M.report())
    if not buf or not vim.api.nvim_win_is_valid(win) then
        return buf, win
    end

    local timer = vim_uv.new_timer()
    if not timer then
        return buf, win
    end

    local interval_ms = refresh_interval * 1000
    timer:start(
        interval_ms,
        interval_ms,
        vim.schedule_wrap(function()
            if not vim.api.nvim_win_is_valid(win) then
                pcall(function()
                    timer:stop()
                    timer:close()
                end)
                return
            end
            update_buf(buf, M.report())
        end)
    )

    local function close_live()
        pcall(function()
            timer:stop()
            timer:close()
        end)
        if vim.api.nvim_win_is_valid(win) then
            vim.api.nvim_win_close(win, true)
        end
    end

    local opts = { buffer = buf, silent = true, nowait = true }
    vim.keymap.set("n", "q", close_live, opts)
    vim.keymap.set("n", "<ESC>", close_live, opts)
    vim.keymap.set("n", "r", function()
        update_buf(buf, M.report())
    end, opts)
    vim.keymap.set("n", "s", function()
        M.save()
    end, opts)

    return buf, win
end

-- ============================================================================
-- Setup
-- ============================================================================

--- Timer handle for the optional periodic auto-save.
local _auto_save_timer = nil

--- Initialise the metrics system.
--- Must be called once from init.lua before any recording takes place.
--- Respects config.metrics.enabled — if false, the module is a no-op.
function M.setup()
    -- Respect the master switch
    if not mcfg("enabled", true) then
        return
    end

    -- Initialise the stats table
    M.stats = create_stats()

    -- Subscribe to the "debug" event so every log call is counted
    events.on(EVENT_DEBUG, M.handle_debug)

    -- Optional periodic auto-save
    local interval = mcfg("auto_save_interval", 3600000)
    if interval and interval > 0 then
        if _auto_save_timer then
            pcall(function()
                _auto_save_timer:stop()
                _auto_save_timer:close()
            end)
        end
        _auto_save_timer = vim_uv.new_timer()
        if _auto_save_timer then
            _auto_save_timer:start(
                interval,
                interval,
                vim.schedule_wrap(function()
                    M.save()
                end)
            )
        end
    end
end

return M
