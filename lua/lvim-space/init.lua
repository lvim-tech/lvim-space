-- lvim-space.init: the plugin entry point. `setup()` merges the user's options into the live config, selects
-- the language pack, then boots every subsystem in dependency order (metrics → UI → autocommands → commands →
-- highlights). Idempotent: repeated calls are no-ops.
--
---@module "lvim-space"

local config = require("lvim-space.config")
local autocommands = require("lvim-space.hooks.autocommands")
local commands = require("lvim-space.hooks.commands")
local metrics = require("lvim-space.core.metrics")
local state = require("lvim-space.api.state")
local ui = require("lvim-space.ui")
local lvim_utils = require("lvim-utils.utils")

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
        lvim_utils.merge(config, user_config)
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

    local ok, hl = pcall(require, "lvim-utils.highlight")
    if ok then
        -- `bind` is the canonical self-theming seam: it applies the factory now and RE-applies it FORCED on
        -- every palette sync. The hand-rolled `colors.on_change` that used to sit here re-registered the same
        -- table unforced, and an unforced `register` is `define_if_missing` — the groups exist by then, so it
        -- was a no-op. `LvimSpace*` therefore kept the palette they were first built with: switch to a dark
        -- theme and this panel stayed light (measured: `LvimSpaceNormal.bg = #dadada` under a dark theme).
        hl.bind(function()
            return config.build()
        end)
        -- `highlights_force` is the user's "these groups win over whatever the colorscheme says" switch, which
        -- `bind`'s first, overwritable apply deliberately does not do — so honour it with one real apply on top.
        if config.highlights_force then
            hl.register(config.build(), true)
        end
        hl.setup()
    end
end

return M
