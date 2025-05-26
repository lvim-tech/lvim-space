-- Neovim API
local api = vim.api

-- Database module
local db = require("lvim-space.persistence.db")

-- Autocommand group
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
			--
			-- local projects = db.find("projects")
			-- if projects == false then
			-- 	return
			-- elseif projects == nil then
			-- 	state.projects = {}
			-- else
			-- 	state.projects = projects
			-- end
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
