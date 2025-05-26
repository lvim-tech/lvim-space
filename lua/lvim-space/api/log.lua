local config = require("lvim-space.config")
local state = require("lvim-space.api.state")

local M = {}

M.logger = function(msg)
	if not config.log then
		return
	end
	local log_path = config.save .. "/ctrlspace_errors.log"
	local file = io.open(log_path, "a")
	if file then
		local time = os.date("%Y-%m-%d %H:%M:%S")
		file:write(string.format("[%s] ERROR: %s\n", time, msg))
		file:close()
	else
		vim.schedule(function()
			vim.notify(state.lang.CANNOT_OPEN_ERROR_LOG_FILE .. log_path, vim.log.levels.ERROR, {
				title = "LVIM CTRLSPACE",
				icon = " ",
				timeout = 5000,
				replace = nil,
			})
		end)
	end
end

return M
