-- lua/lvim-space/init.lua
-- Plugin entry point. Exposes M.setup() which merges user configuration,
-- loads the appropriate language pack, and initialises every subsystem
-- (metrics, UI, autocommands, keymaps, commands, and highlights).

local config = require("lvim-space.config")
local autocommands = require("lvim-space.hooks.autocommands")
local commands = require("lvim-space.hooks.commands")
local metrics = require("lvim-space.core.metrics")
local state = require("lvim-space.api.state")
local highlight = require("lvim-space.ui.highlight")
local ui = require("lvim-space.ui")
local utils = require("lvim-space.utils")

local M = {}

---@type boolean
local _initialized = false

---Bootstrap the lvim-space plugin.
---Merges `user_config` into the default configuration, selects the language
---pack specified by `config.lang` (falling back to English), then initialises
---all plugin subsystems in order. Safe to call multiple times; subsequent
---calls are no-ops.
---@param user_config table|nil User-supplied configuration table (partial overrides are accepted)
function M.setup(user_config)
    if _initialized then
        return
    end
    _initialized = true
    if user_config ~= nil then
        utils.table.merge(config, user_config)
    end
    local success, lang_data = pcall(require, "lvim-space.lang." .. config.lang)
    if success then
        state.lang = lang_data
    else
        state.lang = require("lvim-space.lang.en")
    end
    metrics.setup()
    ui.init()
    autocommands.init()
    commands.init()
    highlight.setup()
end

return M
