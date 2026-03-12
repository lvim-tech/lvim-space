-- lua/lvim-space/config/init.lua
-- Aggregates all configuration submodules into a single flat table.
-- Consumers do: require("lvim-space.config").notify  etc.

---@class LvimSpace.NotifyConfig
---@field enabled   boolean   Master switch for vim.notify() output
---@field min_level integer   Minimum vim.log.levels value to display
---@field title     string    Popup title (e.g. used by nvim-notify)
---@field timeout   integer   Visibility duration in milliseconds

---@class LvimSpace.DebugConfig
---@field enabled   boolean   Master switch for file logging
---@field min_level integer   Minimum vim.log.levels value to write
---@field file      string    Absolute path to the log file

---@class LvimSpace.MetricsConfig
---@field enabled                  boolean  Master switch for metrics collection
---@field max_examples             integer  Example messages stored per bucket
---@field max_top_messages         integer  Top message types shown in report
---@field default_refresh_interval integer  Live-window refresh interval (seconds)
---@field auto_save_interval       integer  Auto-save period in milliseconds (0 = off)

local base     = require("lvim-space.config.base")
local ui       = require("lvim-space.config.ui")
local keys     = require("lvim-space.config.keys")
local messages = require("lvim-space.config.messages")

local M = {}

-- Core / persistence settings
M.save                   = base.save
M.lang                   = base.lang
M.autosave               = base.autosave
M.autorestore            = base.autorestore
M.open_panel_on_add_file = base.open_panel_on_add_file
M.search                 = base.search

-- UI settings (also exposed flat at root for backward compatibility)
M.filetype               = ui.filetype
M.title                  = ui.title
M.title_position         = ui.title_position
M.max_height             = ui.max_height
M.ui                     = ui

-- Keymaps
M.keymappings            = keys.keymappings
M.key_control            = keys.key_control

-- Messaging: notify, debug logging, and metrics (each independently controlled)
M.notify                 = messages.notify
M.debug                  = messages.debug
M.metrics                = messages.metrics

-- Expand the save path once at load time so callers always get an absolute path.
if M.save then
    M.save = vim.fn.expand(M.save)
end

--- Return a snapshot of all configuration values as a plain table.
--- Useful for serialisation or debug inspection.
---@return table
function M.get_all()
    return {
        save                   = M.save,
        lang                   = M.lang,
        autosave               = M.autosave,
        autorestore            = M.autorestore,
        open_panel_on_add_file = M.open_panel_on_add_file,
        search                 = M.search,
        filetype               = M.filetype,
        title                  = M.title,
        title_position         = M.title_position,
        max_height             = M.max_height,
        ui                     = M.ui,
        keymappings            = M.keymappings,
        key_control            = M.key_control,
        notify                 = M.notify,
        debug                  = M.debug,
        metrics                = M.metrics,
    }
end

--- Get a specific configuration value using dot-notation keys.
---
--- Examples:
---   config.get("notify")             --> notify table
---   config.get("notify", "enabled")  --> true / false
---   config.get("ui", "icons", "tab") --> icon string
---
---@param key string Top-level config key
---@param ... string Additional nested keys
---@return any
function M.get(key, ...)
    local current = M[key]
    for _, k in ipairs({ ... }) do
        if type(current) ~= "table" then
            return nil
        end
        current = current[k]
    end
    return current
end

return M
