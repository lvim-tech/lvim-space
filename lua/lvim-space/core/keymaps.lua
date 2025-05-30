local config = require("lvim-space.config")
local state = require("lvim-space.api.state")
local projects = require("lvim-space.ui.projects")
local workspaces = require("lvim-space.ui.workspaces")
local tabs = require("lvim-space.ui.tabs")
local data = require("lvim-space.api.data")

local M = {}

function M.init()
	vim.keymap.set("n", config.keymappings.main, function()
		local current_project = data.find_project_by_cwd()
		if current_project == false or current_project == nil then
			state.project = nil
			projects.init()
			-- всички проекти - няма активен
		else
			state.project_id = current_project.id
			local current_workspace = data.find_current_workspace(state.project_id)
			if current_workspace == false or current_workspace == nil then
				projects.init()
			else
				state.workspace_id = current_workspace.id
                local workspace_tabs = vim.fn.json_decode(current_workspace.tabs)
                state.tab_ids = workspace_tabs.tab_ids
				state.tab_active = workspace_tabs.tab_active
                -- vim.notify(vim.inspect(state))
				if not state.tab_active then
					workspaces.init()
				else
					tabs.init()
				end
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
