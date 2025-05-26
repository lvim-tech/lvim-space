local config = require("lvim-space.config")
local state = require("lvim-space.api.state")
local projects = require("lvim-space.ui.projects")
local workspaces = require("lvim-space.ui.workspaces")
local data = require("lvim-space.api.data")

local M = {}

function M.init()
	vim.keymap.set("n", config.keymappings.main, function()
		local pr = data.find_current_project()
		if pr == false then
			return false
		elseif pr == nil then
			state.project = nil
			projects.init()
			-- всички проекти - няма активен
		else
			state.project_id = pr[1].id
			local ws = data.find_project_workspaces()
			if ws == false then
				projects.init()
			else
				workspaces.init()
			end
		end
	end, {
		noremap = true,
		silent = true,
		nowait = true,
	})
end

function M.enable_base_maps(buf)
	vim.api.nvim_buf_set_keymap(buf, "n", "<Esc>", "", {
		nowait = true,
		noremap = true,
		silent = true,
		callback = function()
			require("lvim-space.ui").close_all()
		end,
	})
end

M.disable_all_maps = function(buf)
	local letters = {}
	for c = string.byte("a"), string.byte("z") do
		local ch = string.char(c)
		if ch ~= "j" and ch ~= "k" then
			table.insert(letters, ch)
		end
	end
	for c = string.byte("A"), string.byte("Z") do
		table.insert(letters, string.char(c))
	end
	for d = 0, 9 do
		table.insert(letters, tostring(d))
	end
	local keys = { "$", "gg", "G", "<C-d>", "<C-u>", "<Left>", "<Right>", "<Up>", "<Down>", "<Space>", "BS" }
	for _, k in ipairs(letters) do
		table.insert(keys, k)
	end
	for _, key in ipairs(keys) do
		vim.keymap.set("n", key, "<nop>", { buffer = buf })
	end
end

return M
