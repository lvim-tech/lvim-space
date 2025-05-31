local config = require("lvim-space.config")
local notify = require("lvim-space.api.notify")
local state = require("lvim-space.api.state")
local data = require("lvim-space.api.data")
local ui = require("lvim-space.ui")
local common = require("lvim-space.ui.common")
local log = require("lvim-space.api.log")
local session = require("lvim-space.core.session")

local M = {}

-- Simplified cache for UI operations only
local cache = {
	file_ids_map = {},
}

local is_empty = false

-- Enhanced file path validation and normalization
local function validate_and_normalize_path(file_path)
	if not file_path or file_path == "" then
		return nil, "LEN_NAME"
	end

	-- Expand and normalize path
	local normalized_path = vim.fn.expand(file_path)
	normalized_path = vim.fn.fnamemodify(normalized_path, ":p")

	-- Check if file exists or can be created
	local dir = vim.fn.fnamemodify(normalized_path, ":h")
	if vim.fn.isdirectory(dir) ~= 1 then
		return nil, "INVALID_DIR"
	end

	return normalized_path, nil
end

-- Get current buffer info efficiently
local function get_current_buffer_info()
	local current_buf = vim.api.nvim_get_current_buf()
	local current_buf_name = vim.api.nvim_buf_get_name(current_buf)
	return {
		bufnr = current_buf,
		name = current_buf_name ~= "" and vim.fn.fnamemodify(current_buf_name, ":p") or nil,
		is_valid = vim.api.nvim_buf_is_valid(current_buf),
	}
end

-- Optimized tab data operations
local function get_tab_data(tab_id, workspace_id)
	local tab = data.find_tab_by_id(tab_id, workspace_id)
	if not tab or not tab.data then
		log.error("get_tab_data: Tab or tab data not found for tab_id: " .. tostring(tab_id))
		return nil
	end

	local success, tab_data = pcall(vim.fn.json_decode, tab.data)
	if not success or not tab_data then
		log.error("get_tab_data: Failed to decode JSON data for tab_id: " .. tostring(tab_id))
		return nil
	end

	tab_data.buffers = tab_data.buffers or {}
	return tab_data
end

local function update_tab_data(tab_id, workspace_id, tab_data)
	local updated_data_json = vim.fn.json_encode(tab_data)
	local success = data.update_tab_data(tab_id, updated_data_json, workspace_id)

	if not success then
		log.error("update_tab_data: Failed to update database for tab_id: " .. tostring(tab_id))
		return false
	end

	return true
end

-- Enhanced file operations
local function add_file_db(file_path_to_add, workspace_id, tab_id)
	local normalized_path, error_code = validate_and_normalize_path(file_path_to_add)
	if not normalized_path then
		return error_code
	end

	local tab_data = get_tab_data(tab_id, workspace_id)
	if not tab_data then
		return nil
	end

	-- Check for existing file
	for _, buf_entry in ipairs(tab_data.buffers) do
		if buf_entry.path == normalized_path then
			log.info("add_file_db: File already exists in list: " .. normalized_path)
			return "EXIST_NAME"
		end
	end

	-- Create or get buffer
	local new_bufnr = vim.fn.bufadd(normalized_path)
	vim.bo[new_bufnr].buflisted = true

	-- Add to tab data
	local new_buffer_entry = {
		id = new_bufnr,
		path = normalized_path,
		added_at = os.time(), -- Track when file was added
	}
	table.insert(tab_data.buffers, new_buffer_entry)

	if update_tab_data(tab_id, workspace_id, tab_data) then
		log.info("add_file_db: Successfully added file: " .. normalized_path)
		return new_bufnr
	else
		return nil
	end
end

local function rename_file_db(file_id_to_rename, new_file_path, workspace_id, tab_id, selected_line_num)
	local normalized_path, error_code = validate_and_normalize_path(new_file_path)
	if not normalized_path then
		return error_code
	end

	local tab_data = get_tab_data(tab_id, workspace_id)
	if not tab_data then
		return nil
	end

	-- Check if new path conflicts with existing files
	for _, buf_entry in ipairs(tab_data.buffers) do
		if buf_entry.path == normalized_path and buf_entry.id ~= file_id_to_rename then
			return "EXIST_NAME"
		end
	end

	-- Find and update the file entry
	local found_and_renamed = false
	for _, buf_entry in ipairs(tab_data.buffers) do
		if buf_entry.id == file_id_to_rename then
			local old_path = buf_entry.path
			buf_entry.path = normalized_path
			buf_entry.modified_at = os.time()
			found_and_renamed = true
			log.info(
				string.format(
					"rename_file_db: File ID %s renamed from '%s' to '%s'",
					file_id_to_rename,
					old_path,
					normalized_path
				)
			)
			break
		end
	end

	if not found_and_renamed then
		log.warn("rename_file_db: File ID " .. file_id_to_rename .. " not found in tab data")
		return nil
	end

	if update_tab_data(tab_id, workspace_id, tab_data) then
		vim.schedule(function()
			M.init(selected_line_num)
		end)
		return true
	else
		return false
	end
end

-- Enhanced delete with buffer cleanup
local function delete_file_db(file_id_to_delete, workspace_id, tab_id, selected_line_num)
	local tab_data = get_tab_data(tab_id, workspace_id)
	if not tab_data then
		return nil
	end

	local index_to_remove = nil
	local file_to_remove = nil

	for i, buf_entry in ipairs(tab_data.buffers) do
		if buf_entry.id == file_id_to_delete then
			index_to_remove = i
			file_to_remove = buf_entry
			break
		end
	end

	if not index_to_remove or not file_to_remove then
		log.warn("delete_file_db: File ID " .. file_id_to_delete .. " not found in tab")
		return nil
	end

	-- Check if file is currently open in any buffer
	local current_buf_info = get_current_buffer_info()
	local is_current_file = current_buf_info.name
		and vim.fn.fnamemodify(file_to_remove.path, ":p") == current_buf_info.name

	-- Remove from tab data
	table.remove(tab_data.buffers, index_to_remove)
	log.info(string.format("delete_file_db: Removed file ID %s (%s) from tab", file_id_to_delete, file_to_remove.path))

	if update_tab_data(tab_id, workspace_id, tab_data) then
		vim.schedule(function()
			-- If the deleted file is currently open, replace with empty buffer
			if is_current_file then
				log.info("delete_file_db: Deleted file was active, creating empty buffer")

				-- Find all windows showing this buffer
				local windows_with_buffer = {}
				for _, win in ipairs(vim.api.nvim_list_wins()) do
					if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == current_buf_info.bufnr then
						table.insert(windows_with_buffer, win)
					end
				end

				-- Create new empty buffer
				local new_buf = vim.api.nvim_create_buf(true, false)
				vim.bo[new_buf].buftype = ""
				vim.bo[new_buf].filetype = ""

				-- Replace buffer in all windows
				for _, win in ipairs(windows_with_buffer) do
					if vim.api.nvim_win_is_valid(win) then
						vim.api.nvim_win_set_buf(win, new_buf)
					end
				end

				-- Delete the old buffer
				pcall(vim.api.nvim_buf_delete, current_buf_info.bufnr, { force = true })

				-- Update state
				if tostring(state.file_active) == tostring(file_id_to_delete) then
					state.file_active = nil
				end

				notify.info("File removed from tab and replaced with empty buffer")
			else
				-- Try to delete the buffer if it's not being used elsewhere
				pcall(vim.api.nvim_buf_delete, file_id_to_delete, { force = false })
			end

			M.init(selected_line_num)
		end)
		return true
	else
		return false
	end
end

-- Helper function to get file path by ID
local function get_file_path_by_id(file_id)
	local files_in_tab = data.find_files(state.workspace_id, state.tab_active) or {}
	for _, file_entry in ipairs(files_in_tab) do
		if tostring(file_entry.id) == tostring(file_id) then
			return file_entry.path
		end
	end
	return nil
end

-- Optimized file switching with better error handling
local function switch_file()
	local file_id_selected = common.get_id_at_cursor(cache.file_ids_map)

	if not file_id_selected then
		log.warn("switch_file: No file selected from list")
		return
	end

	if tostring(state.file_active) == tostring(file_id_selected) then
		log.info("switch_file: Already in file ID: " .. tostring(file_id_selected))
		ui.close_all() -- Close UI even if same file
		return
	end

	local file_path_to_open = get_file_path_by_id(file_id_selected)
	if not file_path_to_open then
		log.warn("switch_file: Path not found for file ID " .. tostring(file_id_selected))
		notify.error("Cannot find path for selected file")
		return
	end

	-- Validate file exists
	if vim.fn.filereadable(file_path_to_open) ~= 1 then
		log.warn("switch_file: File not readable: " .. file_path_to_open)
		notify.error("File is not readable: " .. vim.fn.fnamemodify(file_path_to_open, ":~"))
		return
	end

	log.info(string.format("switch_file: Opening file ID %s, path '%s'", file_id_selected, file_path_to_open))

	-- Close UI first to avoid focus issues
	ui.close_all()

	-- Open file with error handling
	local success, error_msg = pcall(function()
		vim.cmd("edit " .. vim.fn.fnameescape(file_path_to_open))
	end)

	if success then
		state.file_active = file_id_selected
		log.info("switch_file: Successfully opened file")
	else
		log.error("switch_file: Failed to open file: " .. tostring(error_msg))
		notify.error("Failed to open file: " .. tostring(error_msg))
	end
end

-- Split file functions
local function split_file_vertical()
	local file_id_selected = common.get_id_at_cursor(cache.file_ids_map)

	if not file_id_selected then
		log.warn("split_file_vertical: No file selected from list")
		return
	end

	local file_path_to_open = get_file_path_by_id(file_id_selected)
	if not file_path_to_open then
		log.warn("split_file_vertical: Path not found for file ID " .. tostring(file_id_selected))
		notify.error("Cannot find path for selected file")
		return
	end

	-- Validate file exists
	if vim.fn.filereadable(file_path_to_open) ~= 1 then
		log.warn("split_file_vertical: File not readable: " .. file_path_to_open)
		notify.error("File is not readable: " .. vim.fn.fnamemodify(file_path_to_open, ":~"))
		return
	end

	log.info(string.format("split_file_vertical: Opening file ID %s, path '%s'", file_id_selected, file_path_to_open))

	-- Close UI first to avoid focus issues
	ui.close_all()

	-- Open file in vertical split with error handling
	local success, error_msg = pcall(function()
		vim.cmd("vsplit " .. vim.fn.fnameescape(file_path_to_open))
	end)

	if success then
		log.info("split_file_vertical: Successfully opened file in vertical split")
		notify.info("File opened in vertical split")
	else
		log.error("split_file_vertical: Failed to open file: " .. tostring(error_msg))
		notify.error("Failed to open file in vertical split: " .. tostring(error_msg))
	end
end

local function split_file_horizontal()
	local file_id_selected = common.get_id_at_cursor(cache.file_ids_map)

	if not file_id_selected then
		log.warn("split_file_horizontal: No file selected from list")
		return
	end

	local file_path_to_open = get_file_path_by_id(file_id_selected)
	if not file_path_to_open then
		log.warn("split_file_horizontal: Path not found for file ID " .. tostring(file_id_selected))
		notify.error("Cannot find path for selected file")
		return
	end

	-- Validate file exists
	if vim.fn.filereadable(file_path_to_open) ~= 1 then
		log.warn("split_file_horizontal: File not readable: " .. file_path_to_open)
		notify.error("File is not readable: " .. vim.fn.fnamemodify(file_path_to_open, ":~"))
		return
	end

	log.info(string.format("split_file_horizontal: Opening file ID %s, path '%s'", file_id_selected, file_path_to_open))

	-- Close UI first to avoid focus issues
	ui.close_all()

	-- Open file in horizontal split with error handling
	local success, error_msg = pcall(function()
		vim.cmd("split " .. vim.fn.fnameescape(file_path_to_open))
	end)

	if success then
		log.info("split_file_horizontal: Successfully opened file in horizontal split")
		notify.info("File opened in horizontal split")
	else
		log.error("split_file_horizontal: Failed to open file: " .. tostring(error_msg))
		notify.error("Failed to open file in horizontal split: " .. tostring(error_msg))
	end
end

-- Enhanced add file with better UX
local function add_file()
	-- Get current directory as default
	local current_dir = vim.fn.getcwd()
	local default_path = current_dir .. "/"

	ui.create_input_field(state.lang.FILE_PATH or "File Path:", default_path, function(input_file_path)
		if not state.workspace_id or not state.tab_active then
			notify.error(state.lang.TAB_NOT_ACTIVE or "No active tab selected")
			return
		end

		if not input_file_path or vim.trim(input_file_path) == "" then
			notify.info("Operation cancelled")
			return
		end

		local result = add_file_db(vim.trim(input_file_path), state.workspace_id, state.tab_active)

		if result == "LEN_NAME" then
			notify.error(state.lang.FILE_PATH_LEN or "File path is too short")
		elseif result == "EXIST_NAME" then
			notify.error(state.lang.FILE_PATH_EXIST or "File already exists in tab")
		elseif result == "INVALID_DIR" then
			notify.error("Directory does not exist")
		elseif not result then
			notify.error(state.lang.FILE_ADD_FAILED or "Failed to add file")
		else
			notify.info("File added successfully")
			M.init() -- Refresh UI
		end
	end)
end

-- Main initialization with enhanced performance
M.init = function(selected_line_num)
	if not state.workspace_id or not state.tab_active then
		notify.error(state.lang.TAB_NOT_ACTIVE or "No active tab selected")
		local buf, _ = ui.open_main({ " " .. (state.lang.TAB_NOT_ACTIVE or "No active tab selected") }, "Files", 1)
		if buf then
			vim.bo[buf].buftype = "nofile"
		end
		ui.open_actions(state.lang.INFO_LINE_GENERIC_QUIT or "Press 'q' to quit")
		return
	end

	-- Force save current session to capture any manually opened files
	log.debug("files.M.init: Force saving session for tab: " .. state.tab_active)
	session.save_current_state(state.tab_active, true)

	-- Get current buffer info for highlighting
	local current_buf_info = get_current_buffer_info()

	-- Get files from database (always fresh)
	log.debug("files.M.init: Retrieving files for tab: " .. state.tab_active)
	local files_from_db = data.find_files(state.workspace_id, state.tab_active) or {}

	-- Reset cache
	cache.file_ids_map = {}

	-- Get tab name for title
	local tab_display_name = "Current Tab"
	local current_tab_obj = data.find_tab_by_id(state.tab_active, state.workspace_id)
	if current_tab_obj and current_tab_obj.name then
		tab_display_name = current_tab_obj.name
	end

	local panel_title = string.format(state.lang.FILES_PANEL_TITLE_FORMAT or "Files for: %s", tab_display_name)

	-- Custom formatter - returns only the display path without prefix
	local function file_formatter(file_entry)
		local file_path = file_entry.path or "???"
		local display_path = vim.fn.fnamemodify(file_path, ":~:.")
		if display_path == "" then
			display_path = file_path
		end
		return display_path -- No prefix! common.lua will add it
	end

	-- Custom active detection function - hybrid approach
	local function custom_active_fn(entity, active_id)
		-- Primary check: is file currently open in buffer?
		local is_current_buffer = current_buf_info.name
			and entity.path
			and vim.fn.fnamemodify(entity.path, ":p") == current_buf_info.name

		-- Fallback check: use state.file_active if no current buffer match
		local is_state_active = tostring(entity.id) == tostring(active_id)

		return is_current_buffer or (not current_buf_info.name and is_state_active)
	end

	-- Initialize UI using common.lua - ПРАВИЛНИЯТ НАЧИН!
	local ctx = common.init_entity_list(
		"file",
		files_from_db,
		cache.file_ids_map,
		nil, -- init_function (removed parameter)
		state.file_active,
		"id",
		selected_line_num,
		file_formatter,
		custom_active_fn -- Custom active detection based on current buffer
	)

	if not ctx then
		log.error("files.M.init: common.init_entity_list returned no context")
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

	vim.keymap.set("n", config.keymappings.action.add, add_file, keymap_opts)

	vim.keymap.set("n", config.keymappings.action.rename, function()
		if is_empty then
			return
		end

		local file_id_at_cursor = common.get_id_at_cursor(cache.file_ids_map)
		if not file_id_at_cursor then
			return
		end

		-- Find original file path
		local original_file_path = nil
		for _, fe in ipairs(files_from_db) do
			if fe.id == file_id_at_cursor then
				original_file_path = fe.path
				break
			end
		end

		if not original_file_path then
			notify.error("File not found for renaming")
			return
		end

		local current_line_num = vim.api.nvim_win_get_cursor(ctx.win)[1]
		common.rename_entity(
			"file",
			file_id_at_cursor,
			original_file_path,
			state.workspace_id,
			function(id, new_path, ws_id, _)
				return rename_file_db(id, new_path, ws_id, state.tab_active, current_line_num)
			end
		)
	end, keymap_opts)

	vim.keymap.set("n", config.keymappings.action.delete, function()
		if is_empty then
			return
		end

		local file_id_at_cursor = common.get_id_at_cursor(cache.file_ids_map)
		if not file_id_at_cursor then
			return
		end

		-- Find original file path
		local original_file_path = nil
		for _, fe in ipairs(files_from_db) do
			if fe.id == file_id_at_cursor then
				original_file_path = fe.path
				break
			end
		end

		if not original_file_path then
			notify.error("File not found for deletion")
			return
		end

		local current_line_num = vim.api.nvim_win_get_cursor(ctx.win)[1]
		common.delete_entity(
			"file",
			file_id_at_cursor,
			vim.fn.fnamemodify(original_file_path, ":~"),
			state.workspace_id,
			function(id, ws_id, _)
				return delete_file_db(id, ws_id, state.tab_active, current_line_num)
			end
		)
	end, keymap_opts)

	vim.keymap.set("n", config.keymappings.action.switch, function()
		if is_empty then
			return
		end
		switch_file()
	end, keymap_opts)

	-- Split keymappings - вертикален сплит
	vim.keymap.set("n", config.keymappings.action.split_v, function()
		if is_empty then
			return
		end
		split_file_vertical()
	end, keymap_opts)

	-- Split keymappings - хоризонтален сплит
	vim.keymap.set("n", config.keymappings.action.split_h, function()
		if is_empty then
			return
		end
		split_file_horizontal()
	end, keymap_opts)

	-- Navigation keymaps
	vim.keymap.set("n", config.keymappings.global.tabs, function()
		ui.close_all()
		require("lvim-space.ui.tabs").init()
	end, keymap_opts)

	vim.keymap.set("n", config.keymappings.global.workspaces, function()
		ui.close_all()
		require("lvim-space.ui.workspaces").init()
	end, keymap_opts)

	vim.keymap.set("n", config.keymappings.global.projects, function()
		ui.close_all()
		require("lvim-space.ui.projects").init()
	end, keymap_opts)
end

-- Public API for external access
M.add_current_buffer_to_tab = function()
	local current_buf_info = get_current_buffer_info()
	if not current_buf_info.name then
		notify.error("Current buffer has no file path")
		return false
	end

	if not state.workspace_id or not state.tab_active then
		notify.error("No active tab")
		return false
	end

	local result = add_file_db(current_buf_info.name, state.workspace_id, state.tab_active)
	if result and type(result) == "number" then
		notify.info("Current file added to tab")
		return true
	else
		notify.error("Failed to add current file to tab")
		return false
	end
end

M.remove_current_buffer_from_tab = function()
	local current_buf_info = get_current_buffer_info()
	if not current_buf_info.name then
		notify.error("Current buffer has no file path")
		return false
	end

	local files = data.find_files(state.workspace_id, state.tab_active) or {}
	local file_id_to_remove = nil

	for _, file_entry in ipairs(files) do
		if file_entry.path and vim.fn.fnamemodify(file_entry.path, ":p") == current_buf_info.name then
			file_id_to_remove = file_entry.id
			break
		end
	end

	if file_id_to_remove then
		return delete_file_db(file_id_to_remove, state.workspace_id, state.tab_active, nil)
	else
		notify.error("Current file not found in tab")
		return false
	end
end

return M
