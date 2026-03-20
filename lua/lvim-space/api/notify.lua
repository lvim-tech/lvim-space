-- lua/lvim-space/api/notify.lua
-- Public notification helpers used throughout the plugin UI layer.
-- Wraps utils/notify.lua with convenience methods (info / warn / error)
-- and applies config.notify.min_level filtering independently.

local config = require("lvim-space.config")
local levels = require("lvim-space.utils.levels")

local M = {}

--- Internal dispatcher.
--- Checks enabled + min_level before calling vim.notify().
---@param msg   string
---@param level integer  vim.log.levels constant
local function notify(msg, level)
    local cfg = config.notify

    -- Master switch (boolean or table form)
    if not cfg or (type(cfg) == "table" and not cfg.enabled) then
        return
    end

    -- Filter by minimum log level
    local min_level = (type(cfg) == "table" and cfg.min_level) or vim.log.levels.INFO
    if not levels.should_show(level, min_level) then
        return
    end

    local title = (type(cfg) == "table" and cfg.title) or config.title or "LVIM Space"
    local timeout = (type(cfg) == "table" and cfg.timeout) or 5000

    -- Pick an icon based on severity when one is available
    local icons = config.ui and config.ui.icons or {}
    local icon
    if level >= vim.log.levels.ERROR then
        icon = icons.error
    elseif level >= vim.log.levels.WARN then
        icon = icons.warn
    else
        icon = icons.info
    end

    vim.schedule(function()
        vim.notify(msg, level, {
            title = title,
            icon = icon,
            timeout = timeout,
        })
    end)
end

--- Send an informational notification.
---@param msg string
function M.info(msg)
    notify(msg or "INFO", vim.log.levels.INFO)
end

--- Send a warning notification.
---@param msg string
function M.warn(msg)
    notify(msg or "WARN", vim.log.levels.WARN)
end

--- Send an error notification.
---@param msg string
function M.error(msg)
    notify(msg or "ERROR", vim.log.levels.ERROR)
end

return M
