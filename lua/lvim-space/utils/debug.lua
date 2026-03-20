-- lua/lvim-space/utils/debug.lua
-- Structured file-based debug logger.
-- Controlled independently from notifications via config.debug.
-- Each log line is written asynchronously to avoid blocking the UI.

local config = require("lvim-space.config")
local file_system = require("lvim-space.utils.file_system")
local levels = require("lvim-space.utils.levels")

--- Build a formatted log line with ISO timestamp and level name.
---@param msg       string
---@param level_num integer vim.log.levels constant
---@return string
local function format_log_line(msg, level_num)
    local timestamp = os.date("%Y-%m-%d %H:%M:%S")
    local level_name = levels.get_level_name(level_num)
    return string.format("%s [%s] %s\n", timestamp, level_name, tostring(msg))
end

--- Append one log line to the configured debug file.
--- Runs inside vim.schedule() to avoid blocking the main loop.
---@param msg       string
---@param level_num integer
local function write_to_file(msg, level_num)
    local file = config.debug and config.debug.file
    if not file or file == "" then
        return
    end
    vim.schedule(function()
        local expanded = vim.fn.expand(file)
        local line = format_log_line(msg, level_num)
        file_system.ensure_dir(expanded)
        file_system.append_line(expanded, line)
    end)
end

--- Log a debug message.
---
--- Gating:
---   1. config.debug.enabled must be true.
---   2. `level` must be >= config.debug.min_level.
---
--- Side-effects:
---   - Appends to config.debug.file (async).
---   - Emits "debug" event on the event bus so metrics can record it.
---
---@param msg   string         Message to log
---@param level string|integer vim.log.levels constant
return function(msg, level)
    -- Check master switch
    if not config.debug or not config.debug.enabled then
        return
    end

    -- Check minimum level
    local min_level = config.debug.min_level or levels.DEBUG
    if not levels.should_show(level, min_level) then
        return
    end

    local level_num = levels.to_level_number(level)

    -- Write to the log file
    write_to_file(msg, level_num)

    -- Emit on the event bus so metrics.handle_debug() picks it up.
    -- Uses pcall + lazy require to avoid circular dependency at load time.
    local ok, events = pcall(require, "lvim-space.core.events")
    if ok then
        events.emit("debug", msg, level_num)
    end
end
