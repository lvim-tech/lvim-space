-- lua/lvim-space/utils/notify.lua
-- Low-level notification sender used internally by the plugin.
-- Respects config.notify.enabled and config.notify.min_level independently.
-- For UI-level notifications (info / warn / error helpers) see api/notify.lua.

local config = require("lvim-space.config")
local levels = require("lvim-space.utils.levels")

--- Send a notification via vim.notify().
---
--- Behaviour:
---   - Silently dropped when config.notify.enabled is false.
---   - Silently dropped when `level` is below config.notify.min_level.
---   - Runs inside vim.schedule() so it is safe to call from any context.
---
---@param msg   string         Human-readable message to display
---@param level string|integer vim.log.levels constant (default: INFO)
return function(msg, level)
    local cfg = config.notify

    -- Respect the master switch (supports both boolean and table forms)
    if cfg == false or (type(cfg) == "table" and not cfg.enabled) then
        return
    end

    -- Validate message
    if type(msg) ~= "string" or msg == "" then
        return
    end

    -- Filter by minimum log level
    local min_level = (type(cfg) == "table" and cfg.min_level) or levels.INFO
    if not levels.should_show(level, min_level) then
        return
    end

    local level_num = levels.to_level_number(level)
    local title = (type(cfg) == "table" and cfg.title) or config.title or "LVIM Space"
    local timeout = (type(cfg) == "table" and cfg.timeout) or 5000

    vim.schedule(function()
        pcall(vim.notify, msg, level_num, { title = title, timeout = timeout })
    end)
end
