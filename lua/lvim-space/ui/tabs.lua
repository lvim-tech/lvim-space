local config = require("lvim-space.config")
local notify = require("lvim-space.api.notify")
local state = require("lvim-space.api.state")
local data = require("lvim-space.api.data")
local ui = require("lvim-space.ui")
local common = require("lvim-space.ui.common")
local session = require("lvim-space.core.session")
local log = require("lvim-space.api.log")

local M = {}

-- Optimized cache for tab operations
local cache = {
	tab_ids_map = {},
}

local is_empty = false

-- Enhanced tab name validation
local function validate_tab_name(tab_name)
	if not tab_name or vim.trim(tab_name) == "" then
		return nil, "LEN_NAME"
	end

	local trimmed_name = vim.trim(tab_name)
	if #trimmed_name < 1 then
		return nil, "LEN_NAME"
	end

	return trimmed_name, nil
end

-- Get current workspace info efficiently
local function get_current_workspace_info()
	return {
		id = state.workspace_id,
		tab_ids = state.tab_ids or {},
		tab_active = state.tab_active,
	}
end

-- Enhanced tab data operations
local function create_empty_tab_data()
	return {
		buffers = {},
		created_at = os.time(),
		modified_at = os.time(),
	}
end

local function update_workspace_tabs(workspace_id, tab_ids, active_tab_id)
	local workspace_tabs_raw = {
		tab_ids = tab_ids or {},
		tab_active = active_tab_id,
		updated_at = os.time(),
	}
	local workspace_tabs_json = vim.fn.json_encode(workspace_tabs_raw)

	local success = data.update_workspace_tabs(workspace_tabs_json, workspace_id)
	if not success then
		log.error("update_workspace_tabs: Failed to update workspace tabs")
		return false
	end

	-- Update state
	state.tab_ids = tab_ids
	state.tab_active = active_tab_id

	return true
end

-- Enhanced tab operations
local function add_tab_db(tab_name, workspace_id)
	local validated_name, error_code = validate_tab_name(tab_name)
	if not validated_name then
		return error_code
	end

	local tab_data = create_empty_tab_data()
	local tab_data_json = vim.fn.json_encode(tab_data)

	local row_id = data.add_tab(validated_name, tab_data_json, workspace_id)
	if not row_id then
		log.error("add_tab_db: Failed to add tab to database")
		return nil
	end

	-- Update workspace state
	local workspace_info = get_current_workspace_info()
	table.insert(workspace_info.tab_ids, row_id)

	if update_workspace_tabs(workspace_id, workspace_info.tab_ids, workspace_info.tab_active) then
		log.info("add_tab_db: Successfully added tab: " .. validated_name)
		return row_id
	else
		-- Rollback on workspace update failure
		data.delete_tab(row_id, workspace_id)
		return nil
	end
end

local function rename_tab_db(tab_id, new_tab_name, workspace_id, selected_line_num)
	local validated_name, error_code = validate_tab_name(new_tab_name)
	if not validated_name then
		return error_code
	end

	local success = data.update_tab_name(tab_id, validated_name, workspace_id)
	if not success then
		log.warn("rename_tab_db: Failed to rename tab ID " .. tab_id)
		return nil
	end

	log.info(string.format("rename_tab_db: Tab ID %s renamed to '%s'", tab_id, validated_name))

	vim.schedule(function()
		M.init(selected_line_num)
	end)

	return true
end

-- Enhanced delete with proper cleanup
local function delete_tab_db(tab_id, workspace_id, selected_line_num)
	local success = data.delete_tab(tab_id, workspace_id)
	if not success then
		log.warn("delete_tab_db: Failed to delete tab ID " .. tab_id)
		return nil
	end

	log.info("delete_tab_db: Tab ID " .. tab_id .. " deleted from database")

	vim.schedule(function()
		-- Update workspace state
		local workspace_info = get_current_workspace_info()

		-- Remove tab from tab_ids list
		local index_to_remove = nil
		for i, id in ipairs(workspace_info.tab_ids) do
			if tostring(id) == tostring(tab_id) then
				index_to_remove = i
				break
			end
		end

		if index_to_remove then
			table.remove(workspace_info.tab_ids, index_to_remove)
		end

		-- Handle active tab deletion
		local was_active_tab = tostring(workspace_info.tab_active) == tostring(tab_id)
		if was_active_tab then
			workspace_info.tab_active = nil
			state.file_active = nil

			log.info("delete_tab_db: Deleted active tab, clearing session")

			-- Clear session and buffers
			session.clear_current_state()
			session.close_all_file_windows_and_buffers()

			-- Reset main window to empty buffer
			local main_win = state.ui and state.ui.content and state.ui.content.win
			if main_win and vim.api.nvim_win_is_valid(main_win) then
				vim.api.nvim_set_current_win(main_win)
				vim.cmd("enew")
			end
		end

		-- Update workspace
		update_workspace_tabs(workspace_id, workspace_info.tab_ids, workspace_info.tab_active)

		M.init(selected_line_num)
	end)

	return true
end

-- Enhanced tab switching with proper session management
local function switch_tab()
	local tab_id_selected = common.get_id_at_cursor(cache.tab_ids_map)

	if not tab_id_selected then
		log.warn("switch_tab: No tab selected from list")
		return
	end

	if tostring(state.tab_active) == tostring(tab_id_selected) then
		log.info("switch_tab: Already in tab ID: " .. tostring(tab_id_selected))
		ui.close_all() -- Close UI even if same tab
		return
	end

	log.info(
		string.format(
			"switch_tab: Switching from tab %s to tab %s",
			tostring(state.tab_active),
			tostring(tab_id_selected)
		)
	)

	-- Use session.switch_tab for proper session management
	local success = session.switch_tab(tab_id_selected)
	if success then
		log.info("switch_tab: Successfully switched to tab " .. tostring(tab_id_selected))
		ui.close_all() -- Close UI after successful switch
	else
		log.error("switch_tab: Failed to switch to tab " .. tostring(tab_id_selected))
		notify.error("Failed to switch tab")
	end
end

-- Enhanced add tab with better UX
local function add_tab()
	local default_name = "Tab " .. tostring(#(state.tab_ids or {}) + 1)

	ui.create_input_field(state.lang.TAB_NAME or "Tab Name:", default_name, function(input_tab_name)
		if not state.workspace_id then
			notify.error(state.lang.WORKSPACE_NOT_ACTIVE or "No active workspace selected")
			return
		end

		if not input_tab_name or vim.trim(input_tab_name) == "" then
			notify.info("Operation cancelled")
			return
		end

		local result = add_tab_db(vim.trim(input_tab_name), state.workspace_id)

		if result == "LEN_NAME" then
			notify.error(state.lang.TAB_NAME_LEN or "Tab name is too short")
		elseif result == "EXIST_NAME" then
			notify.error(state.lang.TAB_NAME_EXIST or "Tab name already exists")
		elseif not result then
			notify.error(state.lang.TAB_ADD_FAILED or "Failed to add tab")
		else
			notify.info("Tab added successfully")
			M.init() -- Refresh UI
		end
	end)
end

-- Enhanced navigation helpers
local function navigate_to_projects()
	-- Clear session and buffers before navigation
	session.close_all_file_windows_and_buffers()

	local main_win = state.ui and state.ui.content and state.ui.content.win
	if main_win and vim.api.nvim_win_is_valid(main_win) then
		vim.api.nvim_set_current_win(main_win)
		vim.cmd("enew")
	end

	ui.close_all()
	require("lvim-space.ui.projects").init()
end

local function navigate_to_workspaces()
	-- Clear session and buffers before navigation
	session.close_all_file_windows_and_buffers()

	local main_win = state.ui and state.ui.content and state.ui.content.win
	if main_win and vim.api.nvim_win_is_valid(main_win) then
		vim.api.nvim_set_current_win(main_win)
		vim.cmd("enew")
	end

	ui.close_all()
	require("lvim-space.ui.workspaces").init()
end

local function navigate_to_files()
	ui.close_all()
	require("lvim-space.ui.files").init()
end

-- Main initialization with enhanced performance
M.init = function(selected_line_num)
	if not state.workspace_id then
		notify.error(state.lang.WORKSPACE_NOT_ACTIVE or "No active workspace selected")
		local buf, _ =
			ui.open_main({ " " .. (state.lang.WORKSPACE_NOT_ACTIVE or "No active workspace selected") }, "Tabs", 1)
		if buf then
			vim.bo[buf].buftype = "nofile"
		end
		ui.open_actions(state.lang.INFO_LINE_GENERIC_QUIT or "Press 'q' to quit")
		return
	end

	-- Get tabs from database (always fresh)
	log.debug("tabs.M.init: Retrieving tabs for workspace: " .. state.workspace_id)
	local tabs_from_db = data.find_tabs() or {}

	-- Reset cache
	cache.tab_ids_map = {}

	-- Get workspace name for title
	local workspace_display_name = "Current Workspace"
	local current_workspace_obj = data.find_workspace_by_id(state.workspace_id)
	if current_workspace_obj and current_workspace_obj.name then
		workspace_display_name = current_workspace_obj.name
	end

	local panel_title = string.format(state.lang.TABS_PANEL_TITLE_FORMAT or "Tabs for: %s", workspace_display_name)

	-- Custom formatter - returns only the tab name without prefix
	local function tab_formatter(tab_entry)
		return tab_entry.name or "???"
	end

	-- Custom active detection function
	local function custom_active_fn(entity, active_id)
		return tostring(entity.id) == tostring(active_id)
	end

	-- Initialize UI using common.lua
	local ctx = common.init_entity_list(
		"tab",
		tabs_from_db,
		cache.tab_ids_map,
		M.init,
		state.tab_active,
		"id",
		selected_line_num,
		tab_formatter,
		custom_active_fn
	)

	if not ctx then
		log.error("tabs.M.init: common.init_entity_list returned no context")
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

	vim.keymap.set("n", config.keymappings.action.add, add_tab, keymap_opts)

	vim.keymap.set("n", config.keymappings.action.rename, function()
		if is_empty then
			return
		end

		local tab_id_at_cursor = common.get_id_at_cursor(cache.tab_ids_map)
		if not tab_id_at_cursor then
			return
		end

		-- Find original tab name
		local original_tab_name = nil
		for _, tab_entry in ipairs(tabs_from_db) do
			if tab_entry.id == tab_id_at_cursor then
				original_tab_name = tab_entry.name
				break
			end
		end

		if not original_tab_name then
			notify.error("Tab not found for renaming")
			return
		end

		local current_line_num = vim.api.nvim_win_get_cursor(ctx.win)[1]
		common.rename_entity(
			"tab",
			tab_id_at_cursor,
			original_tab_name,
			state.workspace_id,
			function(id, new_name, ws_id, _)
				return rename_tab_db(id, new_name, ws_id, current_line_num)
			end
		)
	end, keymap_opts)

	vim.keymap.set("n", config.keymappings.action.delete, function()
		if is_empty then
			return
		end

		local tab_id_at_cursor = common.get_id_at_cursor(cache.tab_ids_map)
		if not tab_id_at_cursor then
			return
		end

		-- Find original tab name
		local original_tab_name = nil
		for _, tab_entry in ipairs(tabs_from_db) do
			if tab_entry.id == tab_id_at_cursor then
				original_tab_name = tab_entry.name
				break
			end
		end

		if not original_tab_name then
			notify.error("Tab not found for deletion")
			return
		end

		local current_line_num = vim.api.nvim_win_get_cursor(ctx.win)[1]
		common.delete_entity("tab", tab_id_at_cursor, original_tab_name, state.workspace_id, function(id, ws_id, _)
			return delete_tab_db(id, ws_id, current_line_num)
		end)
	end, keymap_opts)

	vim.keymap.set("n", config.keymappings.action.switch, function()
		if is_empty then
			return
		end
		switch_tab()
	end, keymap_opts)

	-- Navigation keymaps
	vim.keymap.set("n", config.keymappings.global.projects, navigate_to_projects, keymap_opts)
	vim.keymap.set("n", config.keymappings.global.workspaces, navigate_to_workspaces, keymap_opts)
	vim.keymap.set("n", config.keymappings.global.files, navigate_to_files, keymap_opts)
end

-- Public API for external access
M.add_new_tab = function(tab_name)
	if not state.workspace_id then
		notify.error("No active workspace")
		return false
	end

	local result = add_tab_db(tab_name or "New Tab", state.workspace_id)
	if result and type(result) == "number" then
		notify.info("Tab created successfully")
		return true
	else
		notify.error("Failed to create tab")
		return false
	end
end

M.get_current_tab_info = function()
	if not state.tab_active then
		return nil
	end

	return data.find_tab_by_id(state.tab_active, state.workspace_id)
end

M.switch_to_tab_by_name = function(tab_name)
	local tabs = data.find_tabs() or {}
	for _, tab in ipairs(tabs) do
		if tab.name == tab_name then
			return session.switch_tab(tab.id)
		end
	end
	return false
end

return M
