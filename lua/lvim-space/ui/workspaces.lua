local config = require("lvim-space.config")
local notify = require("lvim-space.api.notify")
local ui = require("lvim-space.ui")
local state = require("lvim-space.api.state")
local data = require("lvim-space.api.data")

local M = {}

local is_empty

local function get_workspace_id_at_cursor()
	if state.ui and state.ui.content and state.ui.content.win and vim.api.nvim_win_is_valid(state.ui.content.win) then
		local cursor_pos = vim.api.nvim_win_get_cursor(state.ui.content.win)
		local cursor_line = cursor_pos[1]
		return M.workspace_ids[cursor_line]
	end
	local cursor_pos = vim.api.nvim_win_get_cursor(0)
	local cursor_line = cursor_pos[1]
	return M.workspace_ids[cursor_line]
end

local add_workspace_db = function(workspace_name, workspace_tabs, project_id)
	local status = data.add_workspace(workspace_name, workspace_tabs, project_id)
	if status then
		vim.schedule(function()
			M.init()
		end)
	end

	return status
end

local function add_workspace()
	ui.create_input_field(state.lang.WORKSPACE_NAME, "", function(workspace_name)
		local workspace_tabs_raw = {}
		local workspace_tabs = vim.fn.json_encode(workspace_tabs_raw)
		local project_id = state.project_id
		local result = add_workspace_db(workspace_name, workspace_tabs, project_id)
		if result == "LEN_NAME" then
			notify.error(state.lang.WORKSPACE_NAME_LEN)
		elseif result == "EXIST_NAME" then
			notify.error(state.lang.WORKSPACE_NAME_EXIST)
		elseif not result then
			notify.error(state.lang.WORKSPACE_ADD_FAILED)
		end
	end)
end

local rename_workspace_db = function(workspace_id, workspace_new_name, project_id)
	local status = data.update_workspace_name(workspace_id, workspace_new_name, project_id)
	if status then
		vim.schedule(function()
			M.init()
		end)
	end

	return status
end

local rename_workspace = function()
	local project_id = state.project_id
	local workspace_id = get_workspace_id_at_cursor()
	local workspace = data.find_workspace_by_id(workspace_id, project_id)
	local workspace_name = workspace[1].name
	ui.create_input_field(state.lang.WORKSPACE_NEW_NAME, workspace_name, function(workspace_new_name)
		local result = rename_workspace_db(workspace_id, workspace_new_name, project_id)
		if result == "LEN_NAME" then
			notify.error(state.lang.WORKSPACE_NAME_LEN)
		elseif result == "EXIST_NAME" then
			notify.error(state.lang.WORKSPACE_NAME_EXIST)
		elseif not result then
			notify.error(state.lang.WORKSPACE_RENAME_FAILED)
		end
	end)
end

local delete_workspace_db = function(workspace_id, project_id)
	local status = data.delete_workspace(workspace_id, project_id)
	if status then
		vim.schedule(function()
			M.init()
		end)
	end
	return status
end

local delete_workspace = function()
	local project_id = state.project_id
	local workspace_id = get_workspace_id_at_cursor()
	local workspace = data.find_workspace_by_id(workspace_id)
	local name = workspace[1].name
	ui.create_input_field(string.format(state.lang.WORKSPACE_DELETE, name), "", function(answer)
		if answer:lower() == "y" or answer:lower() == "yes" then
			local result = delete_workspace_db(workspace_id, project_id)
			if not result then
				notify.error(state.lang.WORKSPACE_DELETE_FAILED)
			end
		end
	end)
end

M.init = function()
	is_empty = false
	local workspaces = data.find_project_workspaces() or {}
	local lines = {}
	M.workspace_ids = {}
	local icons = config.ui.icons

	local active_idx = 1
	for i, workspace in ipairs(workspaces) do
		local line = string.format(" %s ", workspace.name)
		table.insert(lines, line)
		M.workspace_ids[i] = workspace.id
		if workspace.active then
			active_idx = i
		end
	end
	if #lines == 0 then
		table.insert(lines, " " .. state.lang.WORKSPACES_EMPTY)
		is_empty = true
		active_idx = 1
	end

	local buf, win = ui.open_main(lines, state.lang.WORKSPACES, active_idx)
	if not buf or not win then
		return
	end

	vim.wo[win].signcolumn = "yes:1"
	if is_empty then
		local sign_name = "LvimWorkspaceEmpty"
		vim.fn.sign_define(sign_name, { text = icons.line_prefix, texthl = "LvimSpaceSign" })
		vim.fn.sign_place(1, "LvimSpaceSign", sign_name, buf, { lnum = 1 })
	else
		for i, workspace in ipairs(workspaces) do
			local icon = workspace.active and icons.line_prefix_current or icons.line_prefix
			local sign_name = "LvimWorkspace" .. i
			vim.fn.sign_define(sign_name, { text = icon, texthl = "LvimSpaceSign" })
			vim.fn.sign_place(i, "LvimSpaceSign", sign_name, buf, { lnum = i })
		end
	end

	vim.bo[buf].modifiable = false
	vim.bo[buf].buftype = "nofile"
	ui.open_actions(is_empty and state.lang.INFO_LINE_WORKSPACES_EMPTY or state.lang.INFO_LINE_WORKSPACES)

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

	vim.keymap.set("n", config.keymappings.global.projects, function()
		ui.close_all()
		require("lvim-space.ui.projects").init()
	end, {
		buffer = buf,
		noremap = true,
		silent = true,
		nowait = true,
	})
end

return M
