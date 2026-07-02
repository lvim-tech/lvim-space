-- lvim-space.utils: the utilities aggregate — a single require that exposes every utility submodule
-- (debug / file_system / levels / notify / string / table) as one namespaced table for the rest of the plugin.
--
---@module "lvim-space.utils"

local M = {}

M.debug = require("lvim-space.utils.debug")
M.file_system = require("lvim-space.utils.file_system")
M.levels = require("lvim-space.utils.levels")
M.notify = require("lvim-space.utils.notify")
M.string = require("lvim-space.utils.string")
M.table = require("lvim-space.utils.table")

return M
