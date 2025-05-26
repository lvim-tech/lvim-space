local api = vim.api
local db = require("lvim-space.persistence.db")

local group = api.nvim_create_augroup("NvimCtrlSpaceAutocommands", { clear = true })

local M = {}

function M.init()
	api.nvim_create_autocmd("VimEnter", {
		group = group,
		callback = function()
			local db_success = db.init()
			if db_success == false then
				return
			end
		end,
	})

	api.nvim_create_autocmd("VimLeavePre", {
		group = group,
		callback = function()
			db.close_db_connection()
		end,
	})
end

return M
