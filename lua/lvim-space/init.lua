local config = require("lvim-space.config")
local autocommands = require("lvim-space.core.autocommands")
local keymaps = require("lvim-space.core.keymaps")
local state = require("lvim-space.api.state")
local highlight = require("lvim-space.ui.highlight")
local utils = require("lvim-space.utils")

local M = {}

function M.setup(user_config)
    if user_config ~= nil then
        utils.merge(config, user_config)
    end

    local success, lang_data = pcall(require, "lvim-space.lang." .. config.lang)
    if success then
        state.lang = lang_data
    else
        state = require("lvim-space.lang.en")
    end

    autocommands.init()
    keymaps.init()
    highlight.setup()
end

return M
