local config = require("lvim-space.config")
local notify = require("lvim-space.api.notify")
local state = require("lvim-space.api.state")
local data = require("lvim-space.api.data")
local ui = require("lvim-space.ui")
local utils = require("lvim-space.utils")

local M = {}

local is_empty
local tabs_id_line = 1
local tabs_ids = {}

M.init = function(selected_line)
	is_empty = false
	local tabs = data.find_tabs() or {}
	local lines = {}
	tabs_ids = {}
	local icons = config.ui.icons

	local found = false
	for i, tab in ipairs(tabs) do

	end
	if #lines == 0 then
		table.insert(lines, " " .. state.lang.TABS_EMPTY)
		is_empty = true
	end
	if not found then
		tabs_id_line = 1
		state.workspace_id = nil
	end

	local cursor_line = selected_line or tabs_id_line
	cursor_line = math.max(1, math.min(cursor_line, #lines))

	local buf, win = ui.open_main(lines, state.lang.TABS, cursor_line)
	if not buf or not win then
		return
	end

	vim.wo[win].signcolumn = "yes:1"
	if is_empty then
		local sign_name = "LvimWorkspaceEmpty"
		vim.fn.sign_define(sign_name, { text = icons.line_prefix, texthl = "LvimSpaceSign" })
		vim.fn.sign_place(1, "LvimSpaceSign", sign_name, buf, { lnum = 1 })
	else
		for i, workspace in ipairs(tabs) do
			local icon = workspace.active and icons.line_prefix_current or icons.line_prefix
			local sign_name = "LvimTabs" .. i
			vim.fn.sign_define(sign_name, { text = icon, texthl = "LvimSpaceSign" })
			vim.fn.sign_place(i, "LvimSpaceSign", sign_name, buf, { lnum = i })
		end
	end

	vim.bo[buf].modifiable = false
	vim.bo[buf].buftype = "nofile"
	ui.open_actions(is_empty and state.lang.INFO_LINE_TABS_EMPTY or state.lang.INFO_LINE_TABS)

	vim.keymap.set("n", config.keymappings.action.add, function()
		add_workspace()
	end, {
		buffer = buf,
		noremap = true,
		silent = true,
		nowait = true,
	})

	vim.keymap.set("n", config.keymappings.action.rename, function()
		if is_empty then
			return
		end
		rename_workspace()
	end, {
		buffer = buf,
		noremap = true,
		silent = true,
		nowait = true,
	})

	vim.keymap.set("n", config.keymappings.action.delete, function()
		if is_empty then
			return
		end
		delete_workspace()
		if is_empty then
			return
		end
	end, {
		buffer = buf,
		noremap = true,
		silent = true,
		nowait = true,
	})

	vim.keymap.set("n", config.keymappings.action.switch, function()
		if is_empty then
			return
		end
		switch_workspace()
	end, {
		buffer = buf,
		noremap = true,
		silent = true,
		nowait = true,
	})

	vim.keymap.set("n", config.keymappings.global.projects, function()
		ui.close_all()
		require("lvim-space.ui.projects").init()
	end, {
		buffer = buf,
		noremap = true,
		silent = true,
		nowait = true,
	})

	vim.keymap.set("n", config.keymappings.global.tabs, function()
		if state.project_id and state.workspace_id then
			vim.notify(vim.inspect(state.workspace_id))
		else
			return
		end

		-- ui.close_all()
		-- require("lvim-space.ui.projects").init()
	end, {
		buffer = buf,
		noremap = true,
		silent = true,
		nowait = true,
	})
end

return M

-- vim: foldmethod=indent foldlevel=0
