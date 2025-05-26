-- Configuration
local config = require("lvim-space.config")

-- Core modules
local utils = require("lvim-space.utils")
local autocommands = require("lvim-space.core.autocommands")
local keymaps = require("lvim-space.core.keymaps")

-- State module
local state = require("lvim-space.api.state")

-- UI modules
local highlight = require("lvim-space.ui.highlight")

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
