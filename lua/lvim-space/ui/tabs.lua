local config = require("lvim-space.config")
local notify = require("lvim-space.api.notify")
local state = require("lvim-space.api.state")
local data = require("lvim-space.api.data")
local ui = require("lvim-space.ui")

local M = {}

local is_empty
local tab_id_line = 1
local tab_ids = {}

local get_tab_id_at_cursor = function()
	if state.ui and state.ui.content and state.ui.content.win and vim.api.nvim_win_is_valid(state.ui.content.win) then
		local cursor_pos = vim.api.nvim_win_get_cursor(state.ui.content.win)
		local cursor_line = cursor_pos[1]
		return tab_ids[cursor_line]
	end
	local cursor_pos = vim.api.nvim_win_get_cursor(0)
	local cursor_line = cursor_pos[1]
	return tab_ids[cursor_line]
end

local add_tab_db = function(tab_name, tab_data, workspace_id)
	local row_id = data.add_tab(tab_name, tab_data, workspace_id)
	if row_id then
		table.insert(state.tab_ids, row_id)
		local workspace_tabs_raw = {
			tab_ids = state.tab_ids,
			tab_active = state.tab_active,
		}
		local workspace_tabs = vim.fn.json_encode(workspace_tabs_raw)
		data.update_workspace_tabs(workspace_tabs, workspace_id)
	end
	M.init()
	return row_id
end

local add_tab = function()
	ui.create_input_field(state.lang.TAB_NAME, "", function(tab_name)
		local tab_data_raw = {}
		local tab_data = vim.fn.json_encode(tab_data_raw)
		local workspace_id = state.workspace_id
		local result = add_tab_db(tab_name, tab_data, workspace_id)
		if result == "LEN_NAME" then
			notify.error(state.lang.TAB_NAME_LEN)
		elseif result == "EXIST_NAME" then
			notify.error(state.lang.TAB_NAME_EXIST)
		elseif not result then
			notify.error(state.lang.TAB_ADD_FAILED)
		end
	end)
end

local rename_tab_db = function(tab_id, tab_new_name, workspace_id, selected_line)
	local status = data.update_tab_name(tab_id, tab_new_name, workspace_id)
	if status then
		vim.schedule(function()
			M.init(selected_line)
		end)
	end

	return status
end

local rename_tab = function()
	local workspace_id = state.workspace_id
	local tab_id = get_tab_id_at_cursor()
	local tab = data.find_tab_by_id(tab_id, workspace_id)
	local tab_name = tab.name

	ui.create_input_field(state.lang.TAB_NEW_NAME, tab_name, function(tab_new_name, selected_line)
		local result = rename_tab_db(tab_id, tab_new_name, workspace_id, selected_line)
		if result == "LEN_NAME" then
			notify.error(state.lang.TAB_NAME_LEN)
		elseif result == "EXIST_NAME" then
			notify.error(state.lang.TAB_NAME_EXIST)
		elseif not result then
			notify.error(state.lang.TAB_RENAME_FAILED)
		end
	end)
end

local delete_tab_db = function(tab_id, workspace_id, selected_line)
	local status = data.delete_tab(tab_id, workspace_id)
	if status then
		vim.schedule(function()
			table.remove(state.tab_ids, tab_id)
			if tostring(state.tab_active) == tostring(tab_id) then
				state.tab_active = nil
			end
			local workspace_tabs_raw = {
				tab_ids = state.tab_ids,
				tab_active = state.tab_active,
			}
			local workspace_tabs = vim.fn.json_encode(workspace_tabs_raw)
			data.update_workspace_tabs(workspace_tabs, workspace_id)
			M.init(selected_line)
		end)
	end
	return status
end

local delete_tab = function()
	local workspace_id = state.project_id
	local tab_id = get_tab_id_at_cursor()
	local tab = data.find_tab_by_id(tab_id)
	local name = tab.name

	ui.create_input_field(string.format(state.lang.TAB_DELETE, name), "", function(answer, selected_line)
		if answer:lower() == "y" or answer:lower() == "yes" then
			local result = delete_tab_db(tab_id, workspace_id, selected_line)
			if not result then
				notify.error(state.lang.TAB_DELETE_FAILED)
			end
		end
	end)
end

local switch_tab = function()
	local tab_id = get_tab_id_at_cursor()
	state.tab_active = tab_id
	local workspace_id = state.workspace_id
	local workspace_tabs_raw = {
		tab_ids = state.tab_ids,
		tab_active = state.tab_active,
	}
	local workspace_tabs = vim.fn.json_encode(workspace_tabs_raw)
	data.update_workspace_tabs(workspace_tabs, workspace_id)
    vim.notify(vim.inspect(state))
	M.init()
	-- end
	-- return status
end

M.init = function(selected_line)
	is_empty = false
	local tabs = data.find_tabs() or {}
	local lines = {}
	tab_ids = {}
	local icons = config.ui.icons

	local found = false
	for i, tab in ipairs(tabs) do
		local line = string.format(" %s ", tab.name)
		table.insert(lines, line)
		tab_ids[i] = tab.id
		if tostring(state.tab_active) == tostring(tab.id) then
			tab_id_line = i
			found = true
		end
	end
	if #lines == 0 then
		table.insert(lines, " " .. state.lang.TABS_EMPTY)
		is_empty = true
	end
	if not found then
		tab_id_line = 1
		state.tab_active = nil
	end

	local cursor_line = selected_line or tab_id_line
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
		for i, tab in ipairs(tabs) do
			local icon = tostring(state.tab_active) == tostring(tab.id) and icons.line_prefix_current
				or icons.line_prefix
			local sign_name = "LvimTabs" .. i
			vim.fn.sign_define(sign_name, { text = icon, texthl = "LvimSpaceSign" })
			vim.fn.sign_place(i, "LvimSpaceSign", sign_name, buf, { lnum = i })
		end
	end

	vim.bo[buf].modifiable = false
	vim.bo[buf].buftype = "nofile"
	ui.open_actions(is_empty and state.lang.INFO_LINE_TABS_EMPTY or state.lang.INFO_LINE_TABS)

	vim.keymap.set("n", config.keymappings.action.add, function()
		add_tab()
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
		rename_tab()
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
		delete_tab()
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
		switch_tab()
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
	--
	-- vim.keymap.set("n", config.keymappings.global.tabs, function()
	-- 	if state.project_id and state.workspace_id then
	-- 		vim.notify(vim.inspect(state.workspace_id))
	-- 	else
	-- 		return
	-- 	end
	--
	-- 	-- ui.close_all()
	-- 	-- require("lvim-space.ui.projects").init()
	-- end, {
	-- 	buffer = buf,
	-- 	noremap = true,
	-- 	silent = true,
	-- 	nowait = true,
	-- })
end

return M

-- vim: foldmethod=indent foldlevel=0
