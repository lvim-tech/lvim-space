local config = require("lvim-space.config")
local notify = require("lvim-space.api.notify")
local state = require("lvim-space.api.state")
local data = require("lvim-space.api.data")
local ui = require("lvim-space.ui")
local utils = require("lvim-space.utils")

local M = {}

local is_empty
local workspace_id_line = 1
local workspace_ids = {}

local get_workspace_id_at_cursor = function()
	if state.ui and state.ui.content and state.ui.content.win and vim.api.nvim_win_is_valid(state.ui.content.win) then
		local cursor_pos = vim.api.nvim_win_get_cursor(state.ui.content.win)
		local cursor_line = cursor_pos[1]
		return workspace_ids[cursor_line]
	end
	local cursor_pos = vim.api.nvim_win_get_cursor(0)
	local cursor_line = cursor_pos[1]
	return workspace_ids[cursor_line]
end

local add_workspace_db = function(workspace_name, workspace_tabs, project_id)
	local row_id = data.add_workspace(workspace_name, workspace_tabs, project_id)
	if row_id then
		vim.schedule(function()
			state.workspace_id = row_id
            workspace_tabs = vim.fn.json_decode(workspace_tabs)
            state.tab_ids = workspace_tabs["order"]
            state.tab_active = workspace_tabs.active
			M.init()
		end)
	end
	return row_id
end

local add_workspace = function()
	ui.create_input_field(state.lang.WORKSPACE_NAME, "", function(workspace_name)
		local workspace_tabs_raw = {
			tab_ids = {},
			tab_active = nil,
		}
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

local rename_workspace_db = function(workspace_id, workspace_new_name, project_id, selected_line)
	local status = data.update_workspace_name(workspace_id, workspace_new_name, project_id)
	if status then
		vim.schedule(function()
			M.init(selected_line)
		end)
	end

	return status
end

local rename_workspace = function()
	local project_id = state.project_id
	local workspace_id = get_workspace_id_at_cursor()
	local workspace = data.find_workspace_by_id(workspace_id, project_id)
	local workspace_name = workspace.name

	ui.create_input_field(state.lang.WORKSPACE_NEW_NAME, workspace_name, function(workspace_new_name, selected_line)
		local result = rename_workspace_db(workspace_id, workspace_new_name, project_id, selected_line)
		if result == "LEN_NAME" then
			notify.error(state.lang.WORKSPACE_NAME_LEN)
		elseif result == "EXIST_NAME" then
			notify.error(state.lang.WORKSPACE_NAME_EXIST)
		elseif not result then
			notify.error(state.lang.WORKSPACE_RENAME_FAILED)
		end
	end)
end

local delete_workspace_db = function(workspace_id, project_id, selected_line)
	local status = data.delete_workspace(workspace_id, project_id)
	if status then
		vim.schedule(function()
			M.init(selected_line)
		end)
	end
	return status
end

local delete_workspace = function()
	local project_id = state.project_id
	local workspace_id = get_workspace_id_at_cursor()
	local workspace = data.find_workspace_by_id(workspace_id)
	local name = workspace.name

	ui.create_input_field(string.format(state.lang.WORKSPACE_DELETE, name), "", function(answer, selected_line)
		if answer:lower() == "y" or answer:lower() == "yes" then
			local result = delete_workspace_db(workspace_id, project_id, selected_line)
			if not result then
				notify.error(state.lang.WORKSPACE_DELETE_FAILED)
			end
		end
	end)
end

local switch_workspace = function()
	local workspace_id = get_workspace_id_at_cursor()
	local project_id = state.project_id
	local status = data.set_workspace_active(workspace_id, project_id)
	if status then
		local current_workspace = data.find_current_workspace(project_id)
		if current_workspace then
			state.workspace_id = current_workspace.id
			local workspace_tabs = vim.fn.json_decode(current_workspace.tabs)
			state.tab_ids = workspace_tabs.tab_ids
			state.tab_active = workspace_tabs.tab_active
		end
		M.init()
	end
	return status
end

M.init = function(selected_line)
	is_empty = false
	local workspaces = data.find_workspaces() or {}
	local lines = {}
	workspace_ids = {}
	local icons = config.ui.icons

	local found = false
	for i, workspace in ipairs(workspaces) do
		local tabs_raw = workspace.tabs
		local tabs = vim.fn.json_decode(tabs_raw)
		local num_tabs = tabs and #tabs or 0
		local num_tabs_script = utils.to_superscript(num_tabs)
		local line = string.format(" %s%s ", workspace.name, num_tabs_script)
		table.insert(lines, line)
		workspace_ids[i] = workspace.id
		if tostring(workspace.id) == tostring(state.workspace_id) then
            local workspace_tabs = vim.fn.json_decode(workspace.tabs)
            state.tab_ids = workspace_tabs.tab_ids
            state.tab_active = workspace_tabs.tab_active
			workspace_id_line = i
			found = true
		end
	end
	if #lines == 0 then
		table.insert(lines, " " .. state.lang.WORKSPACES_EMPTY)
		is_empty = true
	end
	if not found then
		workspace_id_line = 1
		state.workspace_id = nil
	end

	local cursor_line = selected_line or workspace_id_line
	cursor_line = math.max(1, math.min(cursor_line, #lines))

	local buf, win = ui.open_main(lines, state.lang.WORKSPACES, cursor_line)
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
		if is_empty then
			return
		end
		if not state.project_id and not state.workspace_id then
			notify.info(state.lang.WORKSPACE_NOT_ACTIVE)
			return
		end
		ui.close_all()
		require("lvim-space.ui.tabs").init()
	end, {
		buffer = buf,
		noremap = true,
		silent = true,
		nowait = true,
	})

	vim.keymap.set("n", config.keymappings.global.files, function()
		if is_empty then
			return
		end
		if not state.project_id and not state.workspace_id then
			notify.info(state.lang.WORKSPACE_NOT_ACTIVE)
			return
		end
		if not state.project_id and not state.workspace_id then
			notify.info(state.lang.TAB_NOT_ACTIVE)
			return
		end
		ui.close_all()
		require("lvim-space.ui.tabs").init()
	end, {
		buffer = buf,
		noremap = true,
		silent = true,
		nowait = true,
	})
end

return M

-- vim: foldmethod=indent foldlevel=0
