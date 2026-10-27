-- The counters, and the filesystem helpers that never raise.
--
-- Most of lvim-space is a store, and sqlite.lua is a declared dependency that is not installed
-- here -- those parts skip in the baseline and say so. Two modules need nothing of the sort:
-- the metrics are plain in-memory arithmetic, and the filesystem helpers exist precisely so a
-- caller gets a pair back instead of an error. Both are cheap to state and easy to break.

local metrics = require("lvim-space.core.metrics")
local fs = require("lvim-space.utils.file_system")

--- A metrics module with fresh statistics.
---@return nil
local function fresh()
    if not metrics.stats then
        metrics.setup()
    end
    metrics.reset()
end

describe("lvim-space: the metrics counters")

it("there are statistics to count into only after setup", function()
    metrics.setup()
    truthy(metrics.stats, "setup() builds the statistics table")
    truthy(metrics.stats.timeline, "with a timeline")
    truthy(metrics.stats.errors, "and an error tally")
end)

it("an error is counted in total and by type, defaulting to other", function()
    fresh()
    metrics.record_error(nil, nil)
    metrics.record_error(nil, "db")
    metrics.record_error(nil, "db")

    eq(3, metrics.stats.errors.total)
    eq(2, metrics.stats.errors.by_type["db"])
    eq(1, metrics.stats.errors.by_type["other"], "an unclassified error still has to land somewhere")
end)

it("the timeline is a ring buffer that evicts its oldest entry", function()
    fresh()
    local cap = metrics.stats.timeline.max_entries
    truthy(cap and cap > 0, "there has to be a cap, or a long session grows without bound")

    for i = 1, cap + 5 do
        metrics.record_operation("op" .. i, i)
    end

    local ops = metrics.stats.timeline.operations
    eq(cap, #ops, "the cap is a cap")
    eq("op6", ops[1].name, "the five oldest were evicted from the FRONT")
    eq("op" .. (cap + 5), ops[#ops].name, "and the newest is last")
end)

it("a measured operation lands in the timeline with a duration", function()
    fresh()
    metrics.start_measure("thing")
    local duration = metrics.end_measure()
    truthy(type(duration) == "number" and duration >= 0, "a duration is a number of milliseconds")

    local ops = metrics.stats.timeline.operations
    truthy(#ops >= 1, "the measurement has to be recorded")
    eq("thing", ops[#ops].name)
end)

it("ending a measurement that never started is zero, not an error", function()
    fresh()
    metrics._current_measure = nil
    eq(0, metrics.end_measure())
end)

it("the average load time is zero with no samples, and rounded to two decimals", function()
    fresh()
    eq(0, metrics.get_avg_load_time())

    metrics.handle_debug("Loaded in 10ms", vim.log.levels.INFO)
    metrics.handle_debug("Loaded in 21ms", vim.log.levels.INFO)
    eq(15.5, metrics.get_avg_load_time())

    metrics.handle_debug("Loaded in 1ms", vim.log.levels.INFO)
    eq(10.66, metrics.get_avg_load_time(), "two decimals, truncated rather than carried")
end)

it("the error rate is zero until there are operations to divide by", function()
    fresh()
    metrics.record_error(nil, "db")
    eq(0, metrics.get_error_rate(), "one error and no operations is not an infinite rate")

    metrics.stats.session.tab_switches = 2
    metrics.stats.session.files_opened = 2
    eq(25, metrics.get_error_rate(), "one error in four operations")
end)

it("a debug message is counted by level and bucketed by type", function()
    fresh()
    metrics.handle_debug("something happened", vim.log.levels.INFO)
    metrics.handle_debug("something happened", vim.log.levels.INFO)
    metrics.handle_debug("a warning", vim.log.levels.WARN)

    eq(2, metrics.stats.by_level[vim.log.levels.INFO])
    eq(1, metrics.stats.by_level[vim.log.levels.WARN])
    eq(2, vim.tbl_count(metrics.stats.msg_types), "two distinct messages, two buckets")
end)

it("an ERROR-level message is promoted to the error counter", function()
    fresh()
    eq(0, metrics.stats.errors.total)
    metrics.handle_debug("could not open the store", vim.log.levels.ERROR)
    eq(1, metrics.stats.errors.total, "an error logged is an error counted")
end)

it("a timing inside a message becomes a sample", function()
    fresh()
    eq(0, #metrics.stats.performance.load_times)
    metrics.handle_debug("Session restored in 42ms", vim.log.levels.INFO)
    eq({ 42 }, metrics.stats.performance.load_times)
    metrics.handle_debug("no timing here", vim.log.levels.INFO)
    eq(1, #metrics.stats.performance.load_times, "a message without a timing is not a sample")
end)

it("the top message types come back biggest first, capped", function()
    fresh()
    for _ = 1, 5 do
        metrics.handle_debug("five of these", vim.log.levels.INFO)
    end
    for _ = 1, 3 do
        metrics.handle_debug("three of these", vim.log.levels.INFO)
    end
    metrics.handle_debug("one of these", vim.log.levels.INFO)

    local top = metrics.get_top_message_types(2)
    eq(2, #top, "the cap is honoured")
    eq(5, top[1].count, "biggest first")
    eq(3, top[2].count)

    eq(3, #metrics.get_top_message_types(10), "asking for more than exists gives what exists")
end)

it("a reset clears the counters but keeps the session's start time", function()
    fresh()
    local started = metrics.stats.timestamps.start
    metrics.record_error(nil, "db")
    metrics.record_operation("op", 1)

    metrics.reset()

    eq(0, metrics.stats.errors.total)
    eq(0, #metrics.stats.timeline.operations)
    eq(started, metrics.stats.timestamps.start, "the session did not restart; only its tally did")
end)

it("the statistics survive a save and a load", function()
    fresh()
    metrics.record_error(nil, "db")
    metrics.handle_debug("Loaded in 7ms", vim.log.levels.INFO)
    local before = metrics.stats.errors.total
    local avg = metrics.get_avg_load_time()

    -- save() writes with io.open and does not create directories -- its own default path lives in
    -- stdpath("data"), which exists -- so the destination has to exist here too.
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    local path = dir .. "/metrics.json"
    metrics.save(path)
    eq(1, vim.fn.filereadable(path), "nothing was written to save")

    metrics.reset()
    eq(0, metrics.stats.errors.total)

    metrics.load(path)
    eq(before, metrics.stats.errors.total, "what was counted comes back")
    eq(avg, metrics.get_avg_load_time())
end)

describe("lvim-space: the filesystem helpers answer, they do not raise")

--- A path inside a directory that does not exist yet.
---@param name string
---@return string
local function unmade_path(name)
    return vim.fn.tempname() .. "/deep/deeper/" .. name
end

it("writing creates the directories the path needs", function()
    local path = unmade_path("written.txt")
    eq(0, vim.fn.isdirectory(vim.fn.fnamemodify(path, ":h")), "precondition: the directory is not there")

    local ok, err = fs.write_lines(path, { "one", "two" })
    eq(true, ok, tostring(err))
    eq(1, vim.fn.filereadable(path))
end)

it("what was written is what is read", function()
    local path = unmade_path("round.txt")
    fs.write_lines(path, { "one", "two", "" })
    local lines, err = fs.read_lines(path)
    eq(nil, err)
    eq({ "one", "two", "" }, lines)
end)

it("appending adds a line, and supplies the newline itself", function()
    local path = unmade_path("appended.txt")
    eq(true, (fs.append_line(path, "first")))
    eq(true, (fs.append_line(path, "second\n")), "a line that already ends in a newline is not doubled")
    eq({ "first", "second" }, (fs.read_lines(path)))
end)

it("reading a file that is not there answers with a reason", function()
    local lines, err = fs.read_lines(unmade_path("absent.txt"))
    eq(nil, lines, "nil, not an empty list: nothing was read")
    truthy(type(err) == "string" and err ~= "", "and the caller is told why")
end)

it("an empty path is refused by every helper, without raising", function()
    for _, call in ipairs({
        function()
            return fs.ensure_dir("")
        end,
        function()
            return fs.write_lines("", { "x" })
        end,
        function()
            return fs.append_line("", "x")
        end,
    }) do
        local ok, result, err = pcall(call)
        truthy(ok, "the helper raised: " .. tostring(result))
        eq(false, result)
        truthy(type(err) == "string" or err == nil)
    end
    eq(nil, (fs.read_lines("")), "and reading nothing reads nothing")
end)

it("writing something that is not a list of lines is refused", function()
    local ok, err = fs.write_lines(unmade_path("bad.txt"), "not a table")
    eq(false, ok)
    truthy(type(err) == "string" and err ~= "")
end)
