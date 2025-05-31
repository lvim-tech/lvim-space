local config = require("lvim-space.config")
local notify = require("lvim-space.api.notify")
local state = require("lvim-space.api.state")
local data = require("lvim-space.api.data")
local ui = require("lvim-space.ui")
local utils = require("lvim-space.utils")
local common = require("lvim-space.ui.common")
local session = require("lvim-space.core.session")
local log = require("lvim-space.api.log")

local M = {}

-- Optimized cache for project operations
local cache = {
	project_ids_map = {},
}

local is_empty = false

-- Enhanced project validation
local function validate_project_name(project_name)
	if not project_name or vim.trim(project_name) == "" then
		return nil, "LEN_NAME"
	end

	local trimmed_name = vim.trim(project_name)
	if #trimmed_name < 3 then
		return nil, "LEN_NAME"
	end

	return trimmed_name, nil
end

local function validate_project_path(project_path)
	if not project_path or vim.trim(project_path) == "" then
		return nil, "PATH_EMPTY"
	end

	-- Normalize and expand path
	local normalized_path = vim.trim(project_path):gsub("/$", "")
	normalized_path = vim.fn.expand(normalized_path)
	normalized_path = vim.fn.fnamemodify(normalized_path, ":p")

	if not normalized_path:match("/$") then
		normalized_path = normalized_path .. "/"
	end

	-- Check if directory exists
	if vim.fn.isdirectory(normalized_path) ~= 1 then
		return nil, "PATH_NOT_FOUND"
	end

	-- Check permissions
	if not utils.has_permission(normalized_path) then
		return nil, "PATH_NO_ACCESS"
	end

	-- Check if path already exists in database
	if data.is_project_path_exist(normalized_path) then
		return nil, "PATH_EXISTS"
	end

	return normalized_path, nil
end

-- Enhanced project operations
local function add_project_db(project_path, project_name)
	local validated_path, path_error = validate_project_path(project_path)
	if not validated_path then
		return nil, path_error
	end

	local validated_name, name_error = validate_project_name(project_name)
	if not validated_name then
		return nil, name_error
	end

	-- Check for duplicate name
	local existing_projects = data.is_project_name_exist(validated_name)
	if existing_projects and #existing_projects > 0 then
		return nil, "NAME_EXISTS"
	end

	local row_id = data.add_project(validated_path, validated_name)
	if not row_id then
		log.error("add_project_db: Failed to add project to database")
		return nil, "ADD_FAILED"
	end

	log.info(
		string.format(
			"add_project_db: Successfully added project '%s' at '%s' (ID: %s)",
			validated_name,
			validated_path,
			row_id
		)
	)

	return row_id, nil
end

local function rename_project_db(project_id, new_project_name, _, selected_line_num)
	local validated_name, error_code = validate_project_name(new_project_name)
	if not validated_name then
		return error_code
	end

	-- Check for duplicate name
	local existing_projects = data.is_project_name_exist(validated_name)
	if existing_projects and #existing_projects > 0 then
		-- Check if it's the same project (allow renaming to same name)
		local is_same_project = false
		for _, existing_id in ipairs(existing_projects) do
			if tostring(existing_id) == tostring(project_id) then
				is_same_project = true
				break
			end
		end
		if not is_same_project then
			return "EXIST_NAME"
		end
	end

	local success = data.update_project_name(project_id, validated_name)
	if not success then
		log.warn("rename_project_db: Failed to rename project ID " .. project_id)
		return nil
	end

	log.info(string.format("rename_project_db: Project ID %s renamed to '%s'", project_id, validated_name))

	vim.schedule(function()
		M.init(selected_line_num)
	end)

	return true
end

-- Enhanced delete with proper cleanup
local function delete_project_db(project_id, _, selected_line_num)
	local success = data.delete_project(project_id)
	if not success then
		log.warn("delete_project_db: Failed to delete project ID " .. project_id)
		return nil
	end

	log.info("delete_project_db: Project ID " .. project_id .. " deleted successfully")

	vim.schedule(function()
		-- Handle active project deletion
		local was_active_project = tostring(state.project_id) == tostring(project_id)
		if was_active_project then
			log.info("delete_project_db: Deleted active project, clearing all state")

			-- Clear all state
			state.project_id = nil
			state.workspace_id = nil
			state.tab_ids = {}
			state.tab_active = nil
			state.file_active = nil

			-- Clear session
			session.clear_current_state()
		end

		M.init(selected_line_num)
	end)

	return true
end

-- Enhanced project switching with proper session management
local function switch_project()
	local project_id_selected = common.get_id_at_cursor(cache.project_ids_map)

	if not project_id_selected then
		log.warn("switch_project: No project selected from list")
		return
	end

	if tostring(state.project_id) == tostring(project_id_selected) then
		log.info("switch_project: Already in project ID: " .. tostring(project_id_selected))
		ui.close_all() -- Close UI even if same project
		return
	end

	-- Get project data
	local selected_project = data.find_project_by_id(project_id_selected)
	if not selected_project then
		notify.error("Project not found")
		log.error("switch_project: Project ID " .. project_id_selected .. " not found")
		return
	end

	-- Validate project path still exists
	if vim.fn.isdirectory(selected_project.path) ~= 1 then
		notify.error(state.lang.DIRECTORY_NOT_FOUND or "Project directory not found")
		log.error("switch_project: Directory not found: " .. selected_project.path)
		return
	end

	-- Check permissions
	if not utils.has_permission(selected_project.path) then
		notify.error(state.lang.DIRECTORY_NOT_ACCESS or "No access to project directory")
		log.error("switch_project: No access to directory: " .. selected_project.path)
		return
	end

	log.info(
		string.format(
			"switch_project: Switching from project %s to project %s (%s)",
			tostring(state.project_id),
			tostring(project_id_selected),
			selected_project.name
		)
	)

	-- Save current session if active tab exists
	if state.tab_active then
		log.debug("switch_project: Saving current session for tab: " .. state.tab_active)
		session.save_current_state(state.tab_active, true)
	end

	-- Change working directory
	local success, error_msg = pcall(function()
		vim.api.nvim_set_current_dir(selected_project.path)
	end)

	if not success then
		notify.error("Failed to change directory: " .. tostring(error_msg))
		log.error("switch_project: Failed to change directory: " .. tostring(error_msg))
		return
	end

	-- Store old state for comparison
	local old_project_id = state.project_id
	local old_workspace_id = state.workspace_id
	local old_tab_active = state.tab_active

	-- Update project state
	state.project_id = selected_project.id

	-- Load workspace data for new project
	local current_workspace = data.find_current_workspace(state.project_id)
	if current_workspace then
		state.workspace_id = current_workspace.id

		-- Parse workspace tabs
		local success_decode, workspace_tabs = pcall(vim.fn.json_decode, current_workspace.tabs)
		if success_decode and workspace_tabs then
			state.tab_ids = workspace_tabs.tab_ids or {}
			state.tab_active = workspace_tabs.tab_active
		else
			log.error("switch_project: Failed to parse workspace tabs JSON")
			state.tab_ids = {}
			state.tab_active = nil
		end

		-- Restore session if there's an active tab and state has changed
		if
			state.tab_active
			and (
				old_project_id ~= state.project_id
				or old_workspace_id ~= state.workspace_id
				or old_tab_active ~= state.tab_active
			)
		then
			log.debug("switch_project: Restoring session for tab: " .. state.tab_active)
			session.restore_state(state.tab_active, true)
		end
	else
		-- No active workspace - clear workspace state
		log.info("switch_project: No active workspace found, clearing workspace state")
		state.workspace_id = nil
		state.tab_ids = {}
		state.tab_active = nil
		session.clear_current_state()
	end

	ui.close_all()
	notify.info("Project switched to: " .. selected_project.name)
	log.info(
		string.format(
			"switch_project: Successfully switched to project '%s' (ID: %s)",
			selected_project.name,
			selected_project.id
		)
	)
end

-- Enhanced add project with better UX and validation flow
local function add_project()
	local current_dir = vim.fn.getcwd()

	ui.create_input_field(state.lang.PROJECT_PATH or "Project Path:", current_dir, function(input_project_path)
		if not input_project_path or vim.trim(input_project_path) == "" then
			notify.info("Operation cancelled")
			return
		end

		local validated_path, path_error = validate_project_path(vim.trim(input_project_path))
		if not validated_path then
			local error_messages = {
				PATH_EMPTY = state.lang.PROJECT_PATH_EMPTY or "Project path is empty",
				PATH_NOT_FOUND = state.lang.DIRECTORY_NOT_FOUND or "Directory not found",
				PATH_NO_ACCESS = state.lang.DIRECTORY_NOT_ACCESS or "No access to directory",
				PATH_EXISTS = state.lang.PROJECT_PATH_EXIST or "Project path already exists",
			}

			notify.error(error_messages[path_error] or "Invalid project path")

			-- Retry with same path for correction
			vim.schedule(function()
				add_project()
			end)
			return
		end

		-- Get default name from path
		local default_name = vim.fn.fnamemodify(validated_path:gsub("/$", ""), ":t")

		-- Ask for project name
		ui.create_input_field(state.lang.PROJECT_NAME or "Project Name:", default_name, function(input_project_name)
			if not input_project_name or vim.trim(input_project_name) == "" then
				notify.info("Operation cancelled")
				return
			end

			local _, error_code = add_project_db(validated_path, vim.trim(input_project_name))

			if error_code then
				local error_messages = {
					LEN_NAME = state.lang.PROJECT_NAME_LEN or "Project name is too short",
					NAME_EXISTS = state.lang.PROJECT_NAME_EXIST or "Project name already exists",
					ADD_FAILED = state.lang.PROJECT_ADD_FAILED or "Failed to add project",
				}

				notify.error(error_messages[error_code] or "Failed to add project")

				-- Retry name input on validation error
				if error_code == "LEN_NAME" or error_code == "NAME_EXISTS" then
					vim.schedule(function()
						ui.create_input_field(
							state.lang.PROJECT_NAME or "Project Name:",
							default_name,
							function(retry_name)
								if retry_name and vim.trim(retry_name) ~= "" then
									local _, retry_error = add_project_db(validated_path, vim.trim(retry_name))
									if retry_error then
										notify.error(error_messages[retry_error] or "Failed to add project")
									else
										notify.info("Project added successfully")
									end
									M.init()
								end
							end
						)
					end)
				else
					M.init()
				end
			else
				notify.info("Project added successfully")
				M.init()
			end
		end)
	end)
end

-- Enhanced navigation helpers
local function navigate_to_workspaces()
	if not state.project_id then
		notify.info(state.lang.PROJECT_NOT_ACTIVE or "No active project selected")
		return
	end

	ui.close_all()
	require("lvim-space.ui.workspaces").init()
end

local function navigate_to_tabs()
	if not state.project_id then
		notify.info(state.lang.PROJECT_NOT_ACTIVE or "No active project selected")
		return
	end

	if not state.workspace_id then
		notify.info(state.lang.WORKSPACE_NOT_ACTIVE or "No active workspace selected")
		return
	end

	ui.close_all()
	require("lvim-space.ui.tabs").init()
end

-- Main initialization with enhanced performance
M.init = function(selected_line_num)
	-- Get projects from database (always fresh)
	log.debug("projects.M.init: Retrieving all projects")
	local projects_from_db = data.find_projects() or {}

	-- Reset cache
	cache.project_ids_map = {}

	local panel_title = state.lang.PROJECTS or "Projects"

	-- Custom formatter - returns project name and path without prefix
	local function project_formatter(project_entry)
		return string.format("%s [%s]", project_entry.name or "???", project_entry.path or "???")
	end

	-- Custom active detection function
	local function custom_active_fn(entity, active_id)
		return tostring(entity.id) == tostring(active_id)
	end

	-- Initialize UI using common.lua
	local ctx = common.init_entity_list(
		"project",
		projects_from_db,
		cache.project_ids_map,
		M.init,
		state.project_id,
		"id",
		selected_line_num,
		project_formatter,
		custom_active_fn
	)

	if not ctx then
		log.error("projects.M.init: common.init_entity_list returned no context")
		return
	end

	is_empty = ctx.is_empty

	-- Update window title
	if ctx.win and vim.api.nvim_win_is_valid(ctx.win) then
		local win_config = vim.api.nvim_win_get_config(ctx.win)
		win_config.title = " " .. panel_title .. " "
		pcall(vim.api.nvim_win_set_config, ctx.win, win_config)
	end

	-- Enhanced keymappings
	local keymap_opts = { buffer = ctx.buf, noremap = true, silent = true, nowait = true }

	vim.keymap.set("n", config.keymappings.action.add, add_project, keymap_opts)

	vim.keymap.set("n", config.keymappings.action.rename, function()
		if is_empty then
			return
		end

		local project_id_at_cursor = common.get_id_at_cursor(cache.project_ids_map)
		if not project_id_at_cursor then
			return
		end

		-- Find original project name
		local original_project_name = nil
		for _, project_entry in ipairs(projects_from_db) do
			if project_entry.id == project_id_at_cursor then
				original_project_name = project_entry.name
				break
			end
		end

		if not original_project_name then
			notify.error("Project not found for renaming")
			return
		end

		local current_line_num = vim.api.nvim_win_get_cursor(ctx.win)[1]
		common.rename_entity("project", project_id_at_cursor, original_project_name, nil, function(id, new_name, _, _)
			return rename_project_db(id, new_name, nil, current_line_num)
		end)
	end, keymap_opts)

	vim.keymap.set("n", config.keymappings.action.delete, function()
		if is_empty then
			return
		end

		local project_id_at_cursor = common.get_id_at_cursor(cache.project_ids_map)
		if not project_id_at_cursor then
			return
		end

		-- Find original project name
		local original_project_name = nil
		for _, project_entry in ipairs(projects_from_db) do
			if project_entry.id == project_id_at_cursor then
				original_project_name = project_entry.name
				break
			end
		end

		if not original_project_name then
			notify.error("Project not found for deletion")
			return
		end

		local current_line_num = vim.api.nvim_win_get_cursor(ctx.win)[1]
		common.delete_entity("project", project_id_at_cursor, original_project_name, nil, function(id, _, _)
			return delete_project_db(id, nil, current_line_num)
		end)
	end, keymap_opts)

	vim.keymap.set("n", config.keymappings.action.switch, function()
		if is_empty then
			return
		end
		switch_project()
	end, keymap_opts)

	-- Navigation keymaps
	vim.keymap.set("n", config.keymappings.global.workspaces, navigate_to_workspaces, keymap_opts)
	vim.keymap.set("n", config.keymappings.global.tabs, navigate_to_tabs, keymap_opts)

	vim.keymap.set("n", config.keymappings.global.files, function()
		if not state.project_id then
			notify.info(state.lang.PROJECT_NOT_ACTIVE or "No active project selected")
			return
		end
		if not state.workspace_id then
			notify.info(state.lang.WORKSPACE_NOT_ACTIVE or "No active workspace selected")
			return
		end
		if not state.tab_active then
			notify.info(state.lang.TAB_NOT_ACTIVE or "No active tab selected")
			return
		end

		ui.close_all()
		require("lvim-space.ui.files").init()
	end, keymap_opts)
end

-- Public API for external access
M.add_new_project = function(project_path, project_name)
	if not project_path or not project_name then
		notify.error("Project path and name are required")
		return false
	end

	local _, error_code = add_project_db(project_path, project_name)
	if error_code then
		notify.error("Failed to add project: " .. (error_code or "unknown error"))
		return false
	else
		notify.info("Project added successfully")
		return true
	end
end

M.get_current_project_info = function()
	if not state.project_id then
		return nil
	end

	return data.find_project_by_id(state.project_id)
end

M.switch_to_project_by_name = function(project_name)
	local projects = data.find_projects() or {}
	for _, project in ipairs(projects) do
		if project.name == project_name then
			-- Simulate clicking on the project
			cache.project_ids_map[1] = project.id
			switch_project()
			return true
		end
	end
	return false
end

return M
