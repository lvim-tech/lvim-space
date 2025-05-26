-- Configuration module
local config = require("lvim-space.config")

-- State management
local state = require("lvim-space.api.state")

-- UI modules
local projects = require("lvim-space.ui.projects")
local workspaces = require("lvim-space.ui.workspaces")

-- Data module
local data = require("lvim-space.api.data")

local ui = require("lvim-space.ui")

local M = {}

function M.init()
	vim.keymap.set("n", config.keymappings.main, function()
		local pr = data.find_current_project()
		if pr == false then
			return false
		elseif pr == nil then
			vim.notify("aaa")
			state.project = nil
			projects.init()
			-- всички проекти - няма активен
		else
			vim.notify("bbb")
			vim.notify(vim.inspect(pr[1].id))
			state.project_id = pr[1].id
			local ws = data.find_current_workspace()
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

-- Добавете тази функция в съществуващия core/keymaps.lua файл

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
	-- local modes = { "n", "i", "v", "x", "s", "o", "c", "t" }
	--
	-- for _, mode in ipairs(modes) do
	-- 	for _, map in ipairs(vim.api.nvim_get_keymap(mode)) do
	-- 		pcall(function()
	-- 			vim.keymap.del(mode, map.lhs, { buffer = buf })
	-- 		end)
	-- 	end
	--
	-- 	for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf, mode)) do
	-- 		pcall(function()
	-- 			vim.keymap.del(mode, map.lhs, { buffer = buf })
	-- 		end)
	-- 	end
	-- end
	--
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
