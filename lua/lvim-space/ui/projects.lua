local config = require("lvim-space.config")
local notify = require("lvim-space.api.notify")
local state = require("lvim-space.api.state")
local data = require("lvim-space.api.data")
local ui = require("lvim-space.ui")
local utils = require("lvim-space.utils")

local M = {}

local is_empty

local function get_project_id_at_cursor()
	if state.ui and state.ui.content and state.ui.content.win and vim.api.nvim_win_is_valid(state.ui.content.win) then
		local cursor_pos = vim.api.nvim_win_get_cursor(state.ui.content.win)
		local cursor_line = cursor_pos[1]
		return M.project_ids[cursor_line]
	end
	local cursor_pos = vim.api.nvim_win_get_cursor(0)
	local cursor_line = cursor_pos[1]
	return M.project_ids[cursor_line]
end

local add_project_db = function(project_path, project_name)
	local status = data.add_project(project_path, project_name)
	if status then
		vim.schedule(function()
			local cwd = vim.loop.cwd()
			if cwd ~= nil and not cwd:match("/$") then
				cwd = cwd .. "/"
			end
			if cwd == project_path then
				local project = data.find_project_by_path(project_path)
				if project and project[1] then
					state.project_id = project[1].id
				end
			end
			M.init()
		end)
	end

	return status
end

local add_project

local function handle_project_name(project_path, default_name, project_name)
	if not project_name or vim.fn.strchars(project_name) < 3 then
		notify.error(state.lang.PROJECT_NAME_LEN)
		vim.schedule(function()
			ui.create_input_field(state.lang.PROJECT_NAME, default_name, function(new_name)
				handle_project_name(project_path, default_name, new_name)
			end)
		end)
		return
	end

	local existing = data.is_project_name_exist(project_name)
	if existing and #existing > 0 then
		notify.error(state.lang.PROJECT_NAME_EXIST)
		vim.schedule(function()
			ui.create_input_field(state.lang.PROJECT_NAME, default_name, function(new_name)
				handle_project_name(project_path, default_name, new_name)
			end)
		end)
		return
	end

	if not utils.has_permission(project_path) then
		notify.error(state.lang.DIRECTORY_NOT_ACCESS)
		vim.schedule(function()
			ui.create_input_field(state.lang.PROJECT_NAME, default_name, function(new_name)
				handle_project_name(project_path, default_name, new_name)
			end)
		end)
        return
	end

	local result = add_project_db(project_path, project_name)
	if not result then
		notify.error(state.lang.PROJECT_ADD_FAILED)
		M.restore_main()
		M.init()
	else
		M.init()
	end
end

local function handle_project_path(project_path)
	if not project_path or project_path == "" then
		notify.error(state.lang.PROJECT_PATH_EMPTY)
		add_project()
		return
	elseif data.is_project_path_exist(project_path) then
		notify.error(state.lang.PROJECT_PATH_EXIST)
		add_project()
		return
	end
	local path = project_path:gsub("/$", "")
	path = vim.fn.expand(path)
	path = vim.fn.fnamemodify(path, ":p")
	if not path:match("/$") then
		path = path .. "/"
	end
	local path_exists = vim.fn.isdirectory(vim.fn.expand(path)) == 1
	if not path_exists then
		notify.error(string.format(state.lang.DIRECTORY_NOT_FOUND, project_path))
		add_project()
		return
	end
	if not utils.has_permission(path) then
		notify.error(state.lang.DIRECTORY_NOT_ACCESS)
		add_project()
		return
	end
	local default_name = vim.fn.fnamemodify(project_path, ":t")
	ui.close_actions()
	ui.create_input_field(state.lang.PROJECT_NAME, default_name, function(project_name)
		handle_project_name(path, default_name, project_name)
	end)
end

add_project = function()
	ui.create_input_field(state.lang.PROJECT_PATH, "", handle_project_path)
end

local rename_project_db = function(project_name, new_name)
	local status = data.update_project_name(project_name, new_name)
	if status then
		vim.schedule(function()
			M.init()
		end)
	end

	return status
end

local rename_project = function()
	local id = get_project_id_at_cursor()
	local project = data.find_project_by_id(id)
	local name = project[1].name
	ui.create_input_field(state.lang.PROJECT_NEW_NAME, name, function(new_name)
		local result = rename_project_db(name, new_name)
		if result == "LEN_NAME" then
			notify.error(state.lang.PROJECT_NAME_LEN)
		elseif result == "EXIST_NAME" then
			notify.error(state.lang.PROJECT_NAME_EXIST)
		elseif not result then
			notify.error(state.lang.PROJECT_RENAME_FAILED)
		end
	end)
end

local remove_project_db = function(project_name)
	local status = data.remove_project(project_name)
	if status then
		vim.schedule(function()
			M.init()
		end)
	end
	return status
end

local remove_project = function()
	local id = get_project_id_at_cursor()
	local project = data.find_project_by_id(id)
	local name = project[1].name
	ui.create_input_field(string.format(state.lang.PROJECT_DELETE, name), "", function(answer)
		if answer:lower() == "y" or answer:lower() == "yes" then
			local result = remove_project_db(name)
			if not result then
				notify.error(state.lang.PROJECT_DELETE_FAILED)
			end
		end
	end)
end

local switch_cwd = function()
	local id = get_project_id_at_cursor()
	local project = data.find_project_by_id(id)
	local project_path = project[1].path
	local path_exists = vim.fn.isdirectory(vim.fn.expand(project_path)) == 1
	if not path_exists then
		notify.error(state.lang.DIRECTORY_NOT_FOUND)
		return
	end

	if not utils.has_permission(project_path) then
		notify.error(state.lang.DIRECTORY_NOT_ACCESS)
		return
	end

	if project and project[1] then
		local ok = pcall(function()
			vim.api.nvim_set_current_dir(project_path)
		end)
		if not ok then
			notify.error(state.lang.DIRECTORY_NOT_FOUND)
			return
		end
		state.project_id = project[1].id
		M.init()
	end
end

M.init = function()
	is_empty = false
	local projects = data.find_projects() or {}
	local lines = {}
	M.project_ids = {}
	local icons = config.ui.icons

	local active_idx = 1
	for i, project in ipairs(projects) do
		local line = string.format(" %s [%s] ", project.name, project.path)
		table.insert(lines, line)
		M.project_ids[i] = project.id
		if tostring(project.id) == tostring(state.project_id) then
			active_idx = i
		end
	end
	if #lines == 0 then
		table.insert(lines, " " .. state.lang.PROJECTS_EMPTY)
		is_empty = true
		active_idx = 1
	end

	local buf, win = ui.open_main(lines, state.lang.PROJECTS, active_idx)
	if not buf or not win then
		return
	end

	vim.wo[win].signcolumn = "yes:1"
	if is_empty then
		local sign_name = "LvimProjectEmpty"
		vim.fn.sign_define(sign_name, { text = icons.line_prefix, texthl = "LvimSpaceSign" })
		vim.fn.sign_place(1, "LvimSpaceSign", sign_name, buf, { lnum = 1 })
	else
		for i, project in ipairs(projects) do
			local icon = (project.id == state.project_id) and icons.line_prefix_current or icons.line_prefix
			local sign_name = "LvimProject" .. i
			vim.fn.sign_define(sign_name, { text = icon, texthl = "LvimSpaceSign" })
			vim.fn.sign_place(i, "LvimSpaceSign", sign_name, buf, { lnum = i })
		end
	end

	vim.bo[buf].modifiable = false
	vim.bo[buf].buftype = "nofile"
	ui.open_actions(is_empty and state.lang.INFO_LINE_PROJECTS_EMPTY or state.lang.INFO_LINE_PROJECTS)

	vim.keymap.set("n", config.keymappings.action.add, function()
		add_project()
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
		rename_project()
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
		remove_project()
		if is_empty then
			return
		end
	end, {
		buffer = buf,
		noremap = true,
		silent = true,
		nowait = true,
	})

	vim.keymap.set("n", "<Space>", function()
		if is_empty then
			return
		end
		switch_cwd()
	end, {
		buffer = buf,
		noremap = true,
		silent = true,
		nowait = true,
	})

	vim.keymap.set("n", "<CR>", function()
		if is_empty then
			return
		end
		-- local id = get_project_id_at_cursor()
	end, {
		buffer = buf,
		noremap = true,
		silent = true,
		nowait = true,
	})

	vim.keymap.set("n", config.keymappings.global.workspaces, function()
		if is_empty then
			return
		end
		ui.close_all()
		require("lvim-space.ui.workspaces").init()
	end, {
		buffer = buf,
		noremap = true,
		silent = true,
		nowait = true,
	})
end

return M

-- vim: foldmethod=indent foldlevel=0
