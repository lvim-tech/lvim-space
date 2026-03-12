-- lua/lvim-space/config/messages.lua
-- Notification, debug logging, and metrics configuration.
-- Each subsystem can be enabled or disabled independently.

local file_system = require("lvim-space.utils.file_system")

return {
    -- -------------------------------------------------------------------------
    -- Notification settings
    -- Controls vim.notify() output shown to the user.
    -- -------------------------------------------------------------------------
    notify = {
        -- Master switch: set to false to silence all plugin notifications.
        enabled   = true,

        -- Minimum log level to display.
        -- Messages below this level are silently dropped.
        -- vim.log.levels: TRACE=0, DEBUG=1, INFO=2, WARN=3, ERROR=4
        min_level = vim.log.levels.INFO,

        -- Title shown in the notification popup (e.g. nvim-notify).
        title     = "Lvim Space",

        -- How long (ms) the notification stays visible.
        timeout   = 3000,
    },

    -- -------------------------------------------------------------------------
    -- Debug / file logging settings
    -- Writes structured log lines to a file for offline inspection.
    -- -------------------------------------------------------------------------
    debug = {
        -- Master switch: set to true to enable file logging.
        -- Disabled by default to avoid unexpected disk writes for end users.
        enabled   = false,

        -- Minimum log level to write to the log file.
        min_level = vim.log.levels.DEBUG,

        -- Absolute path of the log file.
        -- Uses the Neovim state directory so it survives plugin updates.
        file      = file_system.get_state_file("debug.log"),
    },

    -- -------------------------------------------------------------------------
    -- Metrics collection settings
    -- Controls the in-memory stats engine (tab switches, saves, errors, etc.).
    -- -------------------------------------------------------------------------
    metrics = {
        -- Master switch: set to true to enable metrics collection.
        -- Disabled by default; opt-in for users who want usage statistics.
        enabled = false,

        -- Maximum number of example messages stored per message-type bucket.
        max_examples = 3,

        -- Number of top message types shown in the metrics report.
        max_top_messages = 5,

        -- Refresh interval (seconds) for the live metrics window.
        default_refresh_interval = 2,

        -- How often (ms) metrics are auto-saved to disk.
        -- Default: 1 hour.  Set to 0 to disable auto-save.
        auto_save_interval = 3600000,
    },
}
