local api = vim.api
local db = require("lvim-space.persistence.db")
local session = require("lvim-space.core.session")
local state = require("lvim-space.api.state")
local data = require("lvim-space.api.data")
local log = require("lvim-space.api.log")
local notify = require("lvim-space.api.notify")

local M = {}

-- Configuration constants
local AUTOCOMMAND_GROUP = "NvimCtrlSpaceAutocommands"

-- Enhanced context loading with better error handling
local function load_initial_context_state()
	log.info("load_initial_context_state: Starting initial context loading (project/workspace)")

	-- Reset state to clean slate
	state.project_id = nil
	state.workspace_id = nil
	state.tab_active = nil
	state.tab_ids = {}

	-- Find project by current working directory
	local current_project = data.find_project_by_cwd()
	if not current_project then
		log.info("load_initial_context_state: No project found for current directory, context remains empty")
		return false
	end

	-- Set project context
	state.project_id = current_project.id
	log.info(
		string.format(
			"load_initial_context_state: Found project - ID: %s, Name: %s",
			state.project_id,
			current_project.name
		)
	)

	-- Find active workspace for project
	local current_workspace = data.find_current_workspace(state.project_id)
	if not current_workspace then
		log.info("load_initial_context_state: No active workspace found for project ID " .. state.project_id)
		return true -- Project loaded, but no workspace
	end

	-- Set workspace context
	state.workspace_id = current_workspace.id
	log.info(
		string.format(
			"load_initial_context_state: Found active workspace - ID: %s, Name: %s",
			state.workspace_id,
			current_workspace.name
		)
	)

	-- Parse workspace tabs data
	if not current_workspace.tabs or current_workspace.tabs == "" then
		log.info("load_initial_context_state: Workspace has no tabs data")
		return true -- Workspace loaded, but no tabs
	end

	local success, workspace_tabs_data = pcall(vim.fn.json_decode, current_workspace.tabs)
	if not success or not workspace_tabs_data then
		log.error("load_initial_context_state: Failed to parse workspace tabs JSON: " .. tostring(workspace_tabs_data))
		return true -- Workspace loaded, but tabs parsing failed
	end

	-- Set tabs context
	state.tab_ids = workspace_tabs_data.tab_ids or {}
	state.tab_active = workspace_tabs_data.tab_active

	if state.tab_active then
		log.info(
			string.format(
				"load_initial_context_state: Context loaded successfully - "
					.. "ProjectID: %s, WorkspaceID: %s, ActiveTabID: %s, TabCount: %d",
				tostring(state.project_id),
				tostring(state.workspace_id),
				tostring(state.tab_active),
				#state.tab_ids
			)
		)
	else
		log.info(
			string.format(
				"load_initial_context_state: Context loaded - "
					.. "ProjectID: %s, WorkspaceID: %s, No active tab, TabCount: %d",
				tostring(state.project_id),
				tostring(state.workspace_id),
				#state.tab_ids
			)
		)
	end

	return true
end

-- Enhanced database initialization with proper error handling
local function initialize_database()
	log.info("initialize_database: Starting database initialization")

	local success = db.init()
	if not success then
		log.error("initialize_database: CRITICAL - Database initialization failed")

		if notify and notify.error then
			notify.error("Critical error: Failed to initialize lvim-space database")
		end

		return false
	end

	log.info("initialize_database: Database initialized successfully")
	return true
end

-- Enhanced session initialization with error handling
local function initialize_session()
	log.info("initialize_session: Starting session manager initialization")

	if not session or not session.init then
		log.error("initialize_session: Session module not available")
		return false
	end

	-- Initialize session manager with its own autocommands
	-- Note: session.init sets up its own autocmds for BufWinEnter, TabLeave, etc.
	-- but should NOT set up VimLeavePre as that's handled here
	local success, error_msg = pcall(session.init)
	if not success then
		log.error("initialize_session: Failed to initialize session: " .. tostring(error_msg))
		return false
	end

	log.info("initialize_session: Session manager initialized successfully")
	return true
end

-- Enhanced session saving with comprehensive checks
local function save_current_session()
	log.info("save_current_session: Starting session save procedure")

	-- Validate session module availability
	if not session or not session.save_current_state then
		log.warn("save_current_session: Session module or save function not available")
		return false
	end

	-- Check if there's an active tab to save
	if not state.tab_active then
		log.info("save_current_session: No active tab to save")
		return false
	end

	-- Perform session save
	log.info("save_current_session: Saving session for active tab ID: " .. tostring(state.tab_active))

	local success, error_msg = pcall(function()
		session.save_current_state(state.tab_active, true) -- Force save
	end)

	if not success then
		log.error("save_current_session: Failed to save session: " .. tostring(error_msg))
		return false
	end

	log.info("save_current_session: Session saved successfully")
	return true
end

-- Enhanced database cleanup with proper error handling
local function cleanup_database()
	log.info("cleanup_database: Starting database cleanup")

	if not db or not db.close_db_connection then
		log.warn("cleanup_database: Database module or close function not available")
		return false
	end

	local success, error_msg = pcall(db.close_db_connection)
	if not success then
		log.error("cleanup_database: Failed to close database connection: " .. tostring(error_msg))
		return false
	end

	log.info("cleanup_database: Database connection closed successfully")
	return true
end

-- VimEnter callback with comprehensive initialization
local function on_vim_enter()
	log.info("on_vim_enter: Starting lvim-space initialization")

	-- Step 1: Initialize database
	local db_success = initialize_database()
	if not db_success then
		log.error("on_vim_enter: Database initialization failed, aborting")
		return
	end

	-- Step 2: Load initial context
	local context_success = load_initial_context_state()
	if not context_success then
		log.warn("on_vim_enter: Context loading failed, continuing with empty context")
	end

	-- Step 3: Initialize session manager (scheduled to avoid conflicts)
	vim.schedule(function()
		local session_success = initialize_session()
		if not session_success then
			log.warn("on_vim_enter: Session initialization failed")
		end

		log.info("on_vim_enter: lvim-space initialization completed")
	end)
end

-- VimLeavePre callback with proper cleanup sequence
local function on_vim_leave()
	log.info("on_vim_leave: Starting lvim-space cleanup procedures")

	-- Step 1: Save current session (if available)
	local session_saved = save_current_session()
	if not session_saved then
		log.info("on_vim_leave: Session save skipped or failed")
	end

	-- Step 2: Cleanup database connection
	local db_cleanup = cleanup_database()
	if not db_cleanup then
		log.warn("on_vim_leave: Database cleanup failed")
	end

	log.info("on_vim_leave: lvim-space cleanup procedures completed")
end

-- Main initialization function
M.init = function()
	log.info("autocommands.init: Setting up lvim-space autocommands")

	-- Create autocommand group with clear flag
	api.nvim_create_augroup(AUTOCOMMAND_GROUP, { clear = true })

	-- VimEnter: Main initialization
	api.nvim_create_autocmd("VimEnter", {
		group = AUTOCOMMAND_GROUP,
		pattern = "*",
		callback = on_vim_enter,
		desc = "lvim-space: Main initialization on VimEnter",
	})

	-- VimLeavePre: Cleanup and session saving
	api.nvim_create_autocmd("VimLeavePre", {
		group = AUTOCOMMAND_GROUP,
		pattern = "*",
		callback = on_vim_leave,
		desc = "lvim-space: Save session and cleanup on VimLeavePre",
	})

	log.info("autocommands.init: lvim-space autocommands configured successfully")
end

-- Public API for external access
M.reload_context = function()
	log.info("autocommands.reload_context: Manually reloading context")
	return load_initial_context_state()
end

M.force_save_session = function()
	log.info("autocommands.force_save_session: Manually saving current session")
	return save_current_session()
end

M.get_autocommand_group = function()
	return AUTOCOMMAND_GROUP
end

return M
