-- Configuration module
local config = require("lvim-space.config")

local M = {}

---@private
local function notify(msg, level)
	if not config.notify then
		return
	end
	vim.schedule(function()
		vim.notify(msg, level, {
			title = config.title,
			icon = level == 4 and config.ui.icons.error or level == 3 and config.ui.icons.warn or config.ui.icons.info,
			timeout = 5000,
			replace = nil,
		})
	end)
end

-- Public helpers -------------------------------------------------------------

---@param msg string
function M.info(msg)
	notify(msg, vim.log.levels.INFO)
end

---@param msg string
function M.warn(msg)
	notify(msg, vim.log.levels.WARN)
end

---@param msg string
function M.error(msg)
	notify(msg, vim.log.levels.ERROR)
end

return M
