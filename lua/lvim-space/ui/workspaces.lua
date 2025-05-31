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

-- Optimized cache for workspace operations
local cache = {
	workspace_ids_map = {},
}

local is_empty = false

-- Enhanced workspace name validation
local function validate_workspace_name(workspace_name)
	if not workspace_name or vim.trim(workspace_name) == "" then
		return nil, "LEN_NAME"
	end

	local trimmed_name = vim.trim(workspace_name)
	if #trimmed_name < 3 then
		return nil, "LEN_NAME"
	end

	return trimmed_name, nil
end

-- Enhanced workspace data operations
local function create_empty_workspace_tabs()
	return {
		tab_ids = {},
		tab_active = nil,
		created_at = os.time(),
		updated_at = os.time(),
	}
end

-- Enhanced workspace operations
local function add_workspace_db(workspace_name, project_id)
	local validated_name, error_code = validate_workspace_name(workspace_name)
	if not validated_name then
		return error_code
	end

	local initial_tabs_structure = create_empty_workspace_tabs()
	local initial_tabs_json = vim.fn.json_encode(initial_tabs_structure)

	local result = data.add_workspace(validated_name, initial_tabs_json, project_id)

	if type(result) == "number" and result > 0 then
		log.info(string.format("add_workspace_db: Successfully added workspace '%s' (ID: %s)", validated_name, result))

		vim.schedule(function()
			-- Set as active workspace
			state.workspace_id = result
			state.tab_ids = initial_tabs_structure.tab_ids
			state.tab_active = initial_tabs_structure.tab_active
			M.init() -- Refresh UI
		end)

		return result
	elseif type(result) == "string" then
		log.warn(string.format("add_workspace_db: Error from data.add_workspace: %s", result))
		return result
	else
		log.error(
			string.format(
				"add_workspace_db: Failed to add workspace '%s' for project ID %s",
				validated_name,
				project_id
			)
		)
		return nil
	end
end

local function rename_workspace_db(workspace_id, new_workspace_name, project_id, selected_line_num)
	local validated_name, error_code = validate_workspace_name(new_workspace_name)
	if not validated_name then
		return error_code
	end

	local status = data.update_workspace_name(workspace_id, validated_name, project_id)

	if status == true then
		log.info(string.format("rename_workspace_db: Workspace ID %s renamed to '%s'", workspace_id, validated_name))

		vim.schedule(function()
			M.init(selected_line_num)
		end)

		return true
	elseif type(status) == "string" then
		log.warn(string.format("rename_workspace_db: Error from data.update_workspace_name: %s", status))
		return status
	else
		log.error(string.format("rename_workspace_db: Failed to rename workspace ID %s", workspace_id))
		return false
	end
end

-- Enhanced delete with proper session cleanup
local function delete_workspace_db(workspace_id, project_id, selected_line_num)
	local status = data.delete_workspace(workspace_id, project_id)

	if not status then
		log.error(string.format("delete_workspace_db: Failed to delete workspace ID %s", workspace_id))
		return nil
	end

	log.info(string.format("delete_workspace_db: Workspace ID %s deleted successfully", workspace_id))

	vim.schedule(function()
		-- Handle active workspace deletion
		local was_active_workspace = tostring(state.workspace_id) == tostring(workspace_id)
		if was_active_workspace then
			log.info("delete_workspace_db: Deleted active workspace, clearing session")

			-- Reset state
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

-- Enhanced workspace switching with proper session management
local function switch_workspace()
	local workspace_id_selected = common.get_id_at_cursor(cache.workspace_ids_map)

	if not workspace_id_selected then
		log.warn("switch_workspace: No workspace selected from list")
		return
	end

	if tostring(state.workspace_id) == tostring(workspace_id_selected) then
		log.info("switch_workspace: Already in workspace ID: " .. tostring(workspace_id_selected))
		ui.close_all() -- Close UI even if same workspace
		return
	end

	log.info(
		string.format(
			"switch_workspace: Switching from workspace %s to workspace %s",
			tostring(state.workspace_id),
			tostring(workspace_id_selected)
		)
	)

	-- Save current session if active tab exists
	if state.tab_active then
		log.debug("switch_workspace: Saving current session for tab: " .. state.tab_active)
		session.save_current_state(state.tab_active, true)
	end

	-- Activate the new workspace
	local success = data.set_workspace_active(workspace_id_selected, state.project_id)
	if not success then
		log.error("switch_workspace: Failed to activate workspace " .. tostring(workspace_id_selected))
		notify.error("Failed to switch workspace")
		return
	end

	-- Load new workspace data
	local new_workspace_data = data.find_current_workspace(state.project_id)
	if not new_workspace_data or tostring(new_workspace_data.id) ~= tostring(workspace_id_selected) then
		log.error("switch_workspace: Failed to load data for workspace " .. tostring(workspace_id_selected))
		notify.error("Error loading workspace data")
		return
	end

	-- Update state
	state.workspace_id = new_workspace_data.id

	-- Parse workspace tabs
	local success_decode, decoded_tabs = pcall(vim.fn.json_decode, new_workspace_data.tabs)
	if success_decode and decoded_tabs then
		state.tab_ids = decoded_tabs.tab_ids or {}
		state.tab_active = decoded_tabs.tab_active
	else
		log.error("switch_workspace: Failed to parse tabs JSON for workspace " .. tostring(workspace_id_selected))
		state.tab_ids = {}
		state.tab_active = nil
	end

	log.info(
		string.format(
			"switch_workspace: State updated - workspace_id=%s, active_tab_id=%s",
			tostring(state.workspace_id),
			tostring(state.tab_active)
		)
	)

	-- Restore session or clear if no active tab
	if state.tab_active then
		log.debug("switch_workspace: Restoring session for active tab: " .. state.tab_active)
		session.restore_state(state.tab_active, true)
	else
		log.info("switch_workspace: No active tab in new workspace, clearing session")
		session.clear_current_state()
	end

	ui.close_all()
	notify.info("Workspace switched successfully")
end

-- Enhanced add workspace with better UX
local function add_workspace()
	if not state.project_id then
		notify.error(state.lang.PROJECT_NOT_ACTIVE or "No active project selected")
		log.warn("add_workspace: Attempted to add workspace without active project")
		return
	end

	local default_name = "Workspace " .. tostring(#(data.find_workspaces() or {}) + 1)

	ui.create_input_field(state.lang.WORKSPACE_NAME or "Workspace Name:", default_name, function(input_workspace_name)
		if not input_workspace_name or vim.trim(input_workspace_name) == "" then
			notify.info("Operation cancelled")
			return
		end

		local result = add_workspace_db(vim.trim(input_workspace_name), state.project_id)

		if result == "LEN_NAME" then
			notify.error(state.lang.WORKSPACE_NAME_LEN or "Workspace name is too short")
		elseif result == "EXIST_NAME" then
			notify.error(state.lang.WORKSPACE_NAME_EXIST or "Workspace name already exists")
		elseif not result then
			notify.error(state.lang.WORKSPACE_ADD_FAILED or "Failed to add workspace")
		else
			notify.info("Workspace added successfully")
		end
	end)
end

-- Enhanced navigation helpers
local function navigate_to_projects()
	ui.close_all()
	require("lvim-space.ui.projects").init()
end

local function navigate_to_tabs()
	if not state.workspace_id then
		notify.info(state.lang.WORKSPACE_NOT_ACTIVE or "No active workspace selected")
		return
	end

	ui.close_all()
	require("lvim-space.ui.tabs").init()
end

-- Tab count helper with error handling
local function get_tab_count(workspace_entry)
	if not workspace_entry.tabs then
		return 0
	end

	local success, decoded_tabs = pcall(vim.fn.json_decode, workspace_entry.tabs)
	if success and decoded_tabs and decoded_tabs.tab_ids then
		return #decoded_tabs.tab_ids
	else
		log.warn(
			string.format(
				"get_tab_count: Failed to parse tabs for workspace '%s' (ID: %s)",
				workspace_entry.name,
				tostring(workspace_entry.id)
			)
		)
		return 0
	end
end

-- Main initialization with enhanced performance
M.init = function(selected_line_num)
	if not state.project_id then
		notify.error(state.lang.PROJECT_NOT_ACTIVE or "No active project selected")
		local buf, _ =
			ui.open_main({ " " .. (state.lang.PROJECT_NOT_ACTIVE or "No active project selected") }, "Workspaces", 1)
		if buf then
			vim.bo[buf].buftype = "nofile"
		end
		ui.open_actions(state.lang.INFO_LINE_GENERIC_QUIT or "Press 'q' to quit")
		return
	end

	-- Get workspaces from database (always fresh)
	log.debug("workspaces.M.init: Retrieving workspaces for project: " .. state.project_id)
	local workspaces_from_db = data.find_workspaces() or {}

	-- Reset cache
	cache.workspace_ids_map = {}

	-- Get project name for title
	local project_display_name = "Current Project"
	local current_project_obj = data.find_project_by_id(state.project_id)
	if current_project_obj and current_project_obj.name then
		project_display_name = current_project_obj.name
	end

	local panel_title =
		string.format(state.lang.WORKSPACES_PANEL_TITLE_FORMAT or "Workspaces for: %s", project_display_name)

	-- Custom formatter - returns workspace name with tab count and NO prefix
	local function workspace_formatter(workspace_entry)
		local tab_count = get_tab_count(workspace_entry)
		local tab_count_display = utils.to_superscript(tab_count)
		return workspace_entry.name .. tab_count_display
	end

	-- Custom active detection function
	local function custom_active_fn(entity, active_id)
		return tostring(entity.id) == tostring(active_id)
	end

	-- Initialize UI using common.lua
	local ctx = common.init_entity_list(
		"workspace",
		workspaces_from_db,
		cache.workspace_ids_map,
		M.init,
		state.workspace_id,
		"id",
		selected_line_num,
		workspace_formatter,
		custom_active_fn
	)

	if not ctx then
		log.error("workspaces.M.init: common.init_entity_list returned no context")
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

	vim.keymap.set("n", config.keymappings.action.add, add_workspace, keymap_opts)

	vim.keymap.set("n", config.keymappings.action.rename, function()
		if is_empty then
			return
		end

		local workspace_id_at_cursor = common.get_id_at_cursor(cache.workspace_ids_map)
		if not workspace_id_at_cursor then
			return
		end

		-- Find original workspace name
		local original_workspace_name = nil
		for _, workspace_entry in ipairs(workspaces_from_db) do
			if workspace_entry.id == workspace_id_at_cursor then
				original_workspace_name = workspace_entry.name
				break
			end
		end

		if not original_workspace_name then
			notify.error("Workspace not found for renaming")
			return
		end

		local current_line_num = vim.api.nvim_win_get_cursor(ctx.win)[1]
		common.rename_entity(
			"workspace",
			workspace_id_at_cursor,
			original_workspace_name,
			state.project_id,
			function(id, new_name, proj_id, _)
				return rename_workspace_db(id, new_name, proj_id, current_line_num)
			end
		)
	end, keymap_opts)

	vim.keymap.set("n", config.keymappings.action.delete, function()
		if is_empty then
			return
		end

		local workspace_id_at_cursor = common.get_id_at_cursor(cache.workspace_ids_map)
		if not workspace_id_at_cursor then
			return
		end

		-- Find original workspace name
		local original_workspace_name = nil
		for _, workspace_entry in ipairs(workspaces_from_db) do
			if workspace_entry.id == workspace_id_at_cursor then
				original_workspace_name = workspace_entry.name
				break
			end
		end

		if not original_workspace_name then
			notify.error("Workspace not found for deletion")
			return
		end

		local current_line_num = vim.api.nvim_win_get_cursor(ctx.win)[1]
		common.delete_entity(
			"workspace",
			workspace_id_at_cursor,
			original_workspace_name,
			state.project_id,
			function(id, proj_id, _)
				return delete_workspace_db(id, proj_id, current_line_num)
			end
		)
	end, keymap_opts)

	vim.keymap.set("n", config.keymappings.action.switch, function()
		if is_empty then
			return
		end
		switch_workspace()
	end, keymap_opts)

	-- Navigation keymaps
	vim.keymap.set("n", config.keymappings.global.projects, navigate_to_projects, keymap_opts)
	vim.keymap.set("n", config.keymappings.global.tabs, navigate_to_tabs, keymap_opts)

	vim.keymap.set("n", config.keymappings.global.files, function()
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
M.add_new_workspace = function(workspace_name, project_id)
	local target_project_id = project_id or state.project_id
	if not target_project_id then
		notify.error("No project specified or active")
		return false
	end

	local result = add_workspace_db(workspace_name or "New Workspace", target_project_id)
	if result and type(result) == "number" then
		notify.info("Workspace created successfully")
		return true
	else
		notify.error("Failed to create workspace")
		return false
	end
end

M.get_current_workspace_info = function()
	if not state.workspace_id or not state.project_id then
		return nil
	end

	return data.find_workspace_by_id(state.workspace_id, state.project_id)
end

M.switch_to_workspace_by_name = function(workspace_name, project_id)
	local target_project_id = project_id or state.project_id
	if not target_project_id then
		return false
	end

	local workspaces = data.find_workspaces() or {}
	for _, workspace in ipairs(workspaces) do
		if workspace.name == workspace_name then
			local success = data.set_workspace_active(workspace.id, target_project_id)
			if success then
				-- Update state and restore session
				local workspace_data = data.find_current_workspace(target_project_id)
				if workspace_data then
					state.workspace_id = workspace_data.id
					local success_decode, decoded_tabs = pcall(vim.fn.json_decode, workspace_data.tabs)
					if success_decode and decoded_tabs then
						state.tab_ids = decoded_tabs.tab_ids or {}
						state.tab_active = decoded_tabs.tab_active
						if state.tab_active then
							session.restore_state(state.tab_active, true)
						end
					end
				end
			end
			return success
		end
	end
	return false
end

return M
