-- lvim-space.config: the live config — merges every configuration submodule (base / ui / keys /
-- messages / highlights) into one table. setup() merges user opts into it in place, and readers do
-- require("lvim-space.config").notify etc. to see the effective values.
--
---@module "lvim-space.config"

local base = require("lvim-space.config.base")
local ui = require("lvim-space.config.ui")
local keys = require("lvim-space.config.keys")
local messages = require("lvim-space.config.messages")
local highlights = require("lvim-space.config.highlights")

-- Merge all sections flat; ui is also kept as a sub-table for nested access.
local M = vim.tbl_deep_extend("force", base, ui, keys, messages)
M.ui = ui
M.build = highlights.build

-- Expand the save path once at load time so callers always get an absolute path.
if M.save then
    M.save = vim.fn.expand(M.save)
end

return M
