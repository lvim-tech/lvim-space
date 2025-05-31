local data = require("lvim-space.api.data")
local state = require("lvim-space.api.state")
local ui = require("lvim-space.ui")
local log = require("lvim-space.api.log")

local M = {}

-- Configuration constants
local SESSION_CONFIG = {
	save_interval = 2000, -- milliseconds
	restore_delay = 200, -- milliseconds
	debounce_delay = 200, -- milliseconds
	cache_cleanup_interval = 30, -- seconds
	autocommand_group = "LvimSpaceSessionAutocmds",
}

-- Optimized cache with weak references
local cache = {
	last_save = 0,
	current_tab_id = nil,
	is_restoring = false,
	pending_save = nil,
	buffer_cache = setmetatable({}, { __mode = "v" }),
	buffer_type_cache = {},
}

-- Enhanced buffer classification with comprehensive caching
local function classify_buffer(bufnr)
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return { is_special = true, is_valid = false }
	end

	-- Return cached result if available
	if cache.buffer_type_cache[bufnr] then
		return cache.buffer_type_cache[bufnr]
	end

	local buf_options = vim.bo[bufnr]
	local buf_name = vim.api.nvim_buf_get_name(bufnr)
	local filetype = buf_options.filetype
	local buftype = buf_options.buftype

	local is_special = false

	-- Priority checks in order of importance
	if filetype == "lvim-space" then
		is_special = true
	elseif buftype ~= "" and buftype ~= "normal" then
		is_special = true
	elseif not buf_options.buflisted then
		is_special = not (buf_name ~= "" and vim.fn.filereadable(buf_name) == 1 and buftype == "")
	elseif not buf_options.modifiable then
		is_special = not (
			(buf_name ~= "" and vim.fn.filereadable(buf_name) == 1 and buftype == "") or filetype == "oil"
		)
	else
		-- Check for known special patterns and filetypes
		local special_patterns = {
			"^term://",
			"NvimTree_",
			"%[Git%]",
			" fugitive:",
			"Overseer:",
			" तेलिस्कोप",
		}

		local special_filetypes = {
			"alpha",
			"dashboard",
			"startify",
			"Snacks_dashboard",
			"neo-tree",
			"Outline",
			"TelescopePrompt",
			"mason",
			"lazy",
			"help",
			"qf",
			"man",
		}

		-- Check patterns
		for _, pattern in ipairs(special_patterns) do
			if buf_name:match(pattern) then
				is_special = true
				break
			end
		end

		-- Check filetypes
		if not is_special then
			for _, special_ft in ipairs(special_filetypes) do
				if filetype == special_ft then
					is_special = true
					break
				end
			end
		end

		-- Final check for empty name with special flags
		if
			not is_special
			and buf_name == ""
			and (not buf_options.buflisted or not buf_options.modifiable or (buftype ~= "" and buftype ~= "normal"))
		then
			is_special = true
		end
	end

	local classification = {
		is_special = is_special,
		is_valid = true,
		is_listed = buf_options.buflisted,
		name = buf_name,
		filetype = filetype,
	}

	cache.buffer_type_cache[bufnr] = classification

	log.debug(
		string.format(
			"classify_buffer: Buffer %d (%s, ft:%s) -> %s",
			bufnr,
			buf_name,
			filetype,
			is_special and "SPECIAL" or "NORMAL"
		)
	)

	return classification
end

-- Enhanced cache management with automatic cleanup
local function cleanup_buffer_caches()
	local removed_count = 0

	for bufnr, _ in pairs(cache.buffer_type_cache) do
		if not vim.api.nvim_buf_is_valid(bufnr) then
			cache.buffer_type_cache[bufnr] = nil
			removed_count = removed_count + 1
		end
	end

	if removed_count > 0 then
		log.debug("cleanup_buffer_caches: Removed " .. removed_count .. " invalid buffer cache entries")
	end
end

-- Enhanced buffer management with caching
local function get_or_create_buffer(file_path)
	if cache.buffer_cache[file_path] then
		local bufnr = cache.buffer_cache[file_path]
		if vim.api.nvim_buf_is_valid(bufnr) then
			return bufnr
		else
			cache.buffer_cache[file_path] = nil
		end
	end

	local bufnr = vim.fn.bufadd(file_path)
	vim.bo[bufnr].buflisted = true
	cache.buffer_cache[file_path] = bufnr

	log.debug("get_or_create_buffer: Created/cached buffer " .. bufnr .. " for: " .. file_path)
	return bufnr
end

-- Enhanced window operations with batch processing
local function execute_window_operations(operations)
	local saved_hidden = vim.o.hidden
	vim.o.hidden = true

	local results = {}
	for i, operation in ipairs(operations) do
		local success, result = pcall(operation)
		results[i] = success and result or nil

		if not success then
			log.warn("execute_window_operations: Operation " .. i .. " failed: " .. tostring(result))
		end
	end

	vim.o.hidden = saved_hidden
	return results
end

-- Enhanced session data collection
local function collect_session_data()
	local valid_buffers = {}
	local path_to_idx = {}

	-- Collect valid buffers
	for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
		local classification = classify_buffer(bufnr)

		if
			classification.is_valid
			and classification.is_listed
			and not classification.is_special
			and classification.name ~= ""
		then
			if not path_to_idx[classification.name] then
				table.insert(valid_buffers, {
					filePath = classification.name,
					bufnr = bufnr,
					filetype = classification.filetype,
				})
				path_to_idx[classification.name] = #valid_buffers
			end
		end
	end

	if #valid_buffers == 0 then
		return nil, "No valid buffers found"
	end

	-- Collect window information
	local windows = {}
	local current_win = vim.api.nvim_get_current_win()
	local current_window_index = nil
	local valid_window_count = 0

	for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
		if vim.api.nvim_win_is_valid(win) then
			local bufnr = vim.api.nvim_win_get_buf(win)
			local classification = classify_buffer(bufnr)

			if not classification.is_special and path_to_idx[classification.name] then
				valid_window_count = valid_window_count + 1

				local win_position = vim.api.nvim_win_get_position(win)
				local win_cursor = vim.api.nvim_win_get_cursor(win)

				local win_info = {
					file_path = classification.name,
					buffer_index = path_to_idx[classification.name],
					width = vim.api.nvim_win_get_width(win),
					height = vim.api.nvim_win_get_height(win),
					row = win_position[1],
					col = win_position[2],
					cursor_line = win_cursor[1],
					cursor_col = win_cursor[2],
					topline = vim.api.nvim_win_call(win, function()
						return vim.fn.line("w0")
					end),
					leftcol = vim.api.nvim_win_call(win, function()
						return vim.fn.wincol()
					end),
				}

				table.insert(windows, win_info)

				if win == current_win then
					current_window_index = valid_window_count
				end
			end
		end
	end

	if #windows == 0 then
		return nil, "No valid windows found"
	end

	return {
		buffers = valid_buffers,
		windows = windows,
		current_window = current_window_index or 1,
		timestamp = os.time(),
	},
		nil
end

-- Enhanced session saving with improved debouncing
M.save_current_state = function(tab_id, force)
	local target_tab_id = tab_id or state.tab_active
	if not target_tab_id then
		log.debug("save_current_state: No tab_id provided for saving")
		return false
	end

	-- Handle debouncing
	if cache.pending_save then
		vim.fn.timer_stop(cache.pending_save)
		cache.pending_save = nil
	end

	local current_time = vim.uv.now()
	local should_save_now = force or (current_time - cache.last_save >= SESSION_CONFIG.save_interval)

	if not should_save_now and not cache.is_restoring then
		cache.pending_save = vim.fn.timer_start(SESSION_CONFIG.save_interval, function()
			cache.pending_save = nil
			M.save_current_state(target_tab_id, true)
		end)
		return false
	end

	if cache.is_restoring then
		log.debug("save_current_state: Skipping save during restoration")
		return false
	end

	cache.last_save = current_time
	log.info(
		string.format("save_current_state: Starting save for tab %s%s", target_tab_id, force and " (forced)" or "")
	)

	-- Collect session data
	local session_data, error_msg = collect_session_data()
	if not session_data then
		log.info("save_current_state: " .. error_msg .. " for tab " .. target_tab_id)
		return false
	end

	session_data.tab_id = target_tab_id

	-- Save to database
	local session_json = vim.fn.json_encode(session_data)
	local tab_entry = data.find_tab_by_id(target_tab_id, state.workspace_id)

	if not tab_entry then
		log.warn("save_current_state: No database entry found for tab " .. target_tab_id)
		return false
	end

	local success = data.update_tab_data(target_tab_id, session_json, state.workspace_id)
	if success then
		log.info("save_current_state: Successfully saved session for tab " .. target_tab_id)
		return true
	else
		log.error("save_current_state: Failed to update database for tab " .. target_tab_id)
		return false
	end
end

-- Enhanced workspace preparation
local function prepare_restoration_workspace()
	local normal_windows = {}

	-- Find existing normal windows
	for _, win in ipairs(vim.api.nvim_list_wins()) do
		if vim.api.nvim_win_is_valid(win) then
			local classification = classify_buffer(vim.api.nvim_win_get_buf(win))
			if not classification.is_special then
				table.insert(normal_windows, win)
			end
		end
	end

	local target_window = nil
	local window_operations = {}

	if #normal_windows > 0 then
		target_window = normal_windows[1]

		-- Close extra normal windows
		for i = 2, #normal_windows do
			if vim.api.nvim_win_is_valid(normal_windows[i]) then
				table.insert(window_operations, function()
					vim.api.nvim_win_close(normal_windows[i], true)
				end)
			end
		end
	else
		-- Create new window if none exist
		table.insert(window_operations, function()
			vim.cmd("new")
			target_window = vim.api.nvim_get_current_win()
		end)
	end

	-- Execute window operations
	execute_window_operations(window_operations)

	if not target_window or not vim.api.nvim_win_is_valid(target_window) then
		return nil
	end

	-- Ensure target window is current and has normal buffer
	vim.api.nvim_set_current_win(target_window)
	local target_buf = vim.api.nvim_win_get_buf(target_window)

	if classify_buffer(target_buf).is_special then
		vim.cmd("enew")
	end

	return target_window
end

-- Enhanced buffer cleanup during restoration
local function cleanup_old_session_buffers(keep_window)
	local keep_buffer = nil
	if keep_window and vim.api.nvim_win_is_valid(keep_window) then
		keep_buffer = vim.api.nvim_win_get_buf(keep_window)
	end

	local cleanup_count = 0
	for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
		local classification = classify_buffer(bufnr)

		if classification.is_valid and not classification.is_special and bufnr ~= keep_buffer then
			local success = pcall(vim.api.nvim_buf_delete, bufnr, { force = true, unload = true })
			if success then
				cleanup_count = cleanup_count + 1
			end
		end
	end

	log.debug("cleanup_old_session_buffers: Cleaned " .. cleanup_count .. " old buffers")
end

-- Enhanced window restoration with improved layout handling
local function restore_session_layout(session_data, file_to_buf_map, initial_window)
	local created_windows = { [1] = initial_window }

	if #session_data.windows == 0 then
		return created_windows
	end

	-- Configure first window
	local first_win_info = session_data.windows[1]
	local first_file_path = first_win_info.file_path

	if first_file_path and file_to_buf_map[first_file_path] then
		local success, error_msg = pcall(function()
			vim.api.nvim_win_set_buf(initial_window, file_to_buf_map[first_file_path])
			vim.cmd("doautocmd BufEnter")

			if first_win_info.cursor_line and first_win_info.cursor_col then
				vim.api.nvim_win_set_cursor(initial_window, {
					first_win_info.cursor_line,
					first_win_info.cursor_col,
				})
			end

			if first_win_info.topline then
				vim.api.nvim_win_call(initial_window, function()
					vim.cmd("normal! " .. first_win_info.topline .. "zt")
				end)
			end
		end)

		if not success then
			log.warn("restore_session_layout: Error configuring first window: " .. tostring(error_msg))
		end
	end

	-- Create additional windows
	if #session_data.windows > 1 then
		local parent_window = initial_window

		for i = 2, #session_data.windows do
			local win_info = session_data.windows[i]

			if not vim.api.nvim_win_is_valid(parent_window) then
				parent_window = initial_window
				if not vim.api.nvim_win_is_valid(parent_window) then
					log.warn("restore_session_layout: Parent window invalid, stopping layout restoration")
					break
				end
			end

			vim.api.nvim_set_current_win(parent_window)

			-- Determine split direction based on window positions
			local split_cmd = "split"
			local first_window_info = session_data.windows[1]
			if
				first_window_info
				and first_window_info.col
				and win_info.col
				and win_info.col > first_window_info.col
			then
				split_cmd = "vsplit"
			end

			local new_window = nil
			local success, error_msg = pcall(function()
				vim.cmd(split_cmd)
				new_window = vim.api.nvim_get_current_win()
			end)

			if not success or not new_window or not vim.api.nvim_win_is_valid(new_window) then
				log.warn("restore_session_layout: Failed to create window " .. i .. ": " .. tostring(error_msg))
				break
			end

			-- Configure new window
			local win_file_path = win_info.file_path
			if win_file_path and file_to_buf_map[win_file_path] then
				local config_success, config_error = pcall(function()
					vim.api.nvim_win_set_buf(new_window, file_to_buf_map[win_file_path])
					vim.cmd("doautocmd BufEnter")

					if win_info.cursor_line and win_info.cursor_col then
						vim.api.nvim_win_set_cursor(new_window, {
							win_info.cursor_line,
							win_info.cursor_col,
						})
					end

					if win_info.topline then
						vim.api.nvim_win_call(new_window, function()
							vim.cmd("normal! " .. win_info.topline .. "zt")
						end)
					end
				end)

				if not config_success then
					log.warn("restore_session_layout: Error configuring window " .. i .. ": " .. tostring(config_error))
				end
			end

			created_windows[i] = new_window
			parent_window = new_window
		end
	end

	return created_windows
end

-- Enhanced session restoration with improved error handling
M.restore_state = function(tab_id, force)
	if not tab_id then
		log.warn("restore_state: Missing tab_id for restoration")
		return false
	end

	if tab_id == cache.current_tab_id and not force then
		log.info("restore_state: Already in tab " .. tostring(tab_id))
		return true
	end

	-- Get and validate session data
	local tab_entry = data.find_tab_by_id(tab_id, state.workspace_id)
	if not tab_entry or not tab_entry.data or #tab_entry.data < 2 then
		log.info("restore_state: No valid session data for tab " .. tostring(tab_id))
		return false
	end

	local success, session_data = pcall(vim.fn.json_decode, tab_entry.data)
	if not success or not session_data or not session_data.buffers or #session_data.buffers == 0 then
		log.warn("restore_state: Invalid session data for tab " .. tostring(tab_id))
		return false
	end

	cache.current_tab_id = tab_id
	cache.is_restoring = true

	log.info("restore_state: Starting restoration for tab " .. tostring(tab_id))

	-- Schedule restoration to avoid UI conflicts
	vim.defer_fn(function()
		if cache.current_tab_id ~= tab_id then
			log.warn("restore_state: Tab changed during restoration, aborting")
			return
		end

		cache.is_restoring = true
		cleanup_buffer_caches()

		local saved_hidden = vim.o.hidden
		vim.o.hidden = true

		-- Prepare workspace
		local initial_window = prepare_restoration_workspace()
		if not initial_window then
			log.error("restore_state: Failed to prepare restoration workspace")
			vim.o.hidden = saved_hidden
			cache.is_restoring = false
			return
		end

		-- Clean old buffers
		cleanup_old_session_buffers(initial_window)

		-- Restore buffers with caching
		local file_to_buf_map = {}
		for _, buf_info in ipairs(session_data.buffers) do
			local file_path = buf_info.filePath
			if vim.fn.filereadable(file_path) == 1 then
				file_to_buf_map[file_path] = get_or_create_buffer(file_path)
			end
		end

		-- Restore window layout
		local created_windows = restore_session_layout(session_data, file_to_buf_map, initial_window)

		-- Set active window
		local target_window = nil
		if session_data.current_window and created_windows[session_data.current_window] then
			target_window = created_windows[session_data.current_window]
		end

		if not target_window or not vim.api.nvim_win_is_valid(target_window) then
			-- Find any valid window as fallback
			for i = #created_windows, 1, -1 do
				if created_windows[i] and vim.api.nvim_win_is_valid(created_windows[i]) then
					target_window = created_windows[i]
					break
				end
			end
		end

		if target_window then
			pcall(vim.api.nvim_set_current_win, target_window)
		end

		-- Cleanup and finish
		vim.o.hidden = saved_hidden
		vim.cmd("redraw!")

		-- Trigger completion event
		vim.api.nvim_exec_autocmds("User", {
			pattern = "LvimSpaceSessionRestored",
			modeline = false,
			data = { tab_id = tab_id, buffer_count = #session_data.buffers },
		})

		if cache.current_tab_id == tab_id then
			cache.is_restoring = false
		end

		log.info("restore_state: Successfully restored session for tab " .. tostring(tab_id))
	end, SESSION_CONFIG.restore_delay)

	return true
end

-- Enhanced state clearing with batch operations
M.clear_current_state = function()
	log.info("clear_current_state: Starting comprehensive state cleanup")
	cache.is_restoring = true

	local target_window = prepare_restoration_workspace()

	if target_window then
		cleanup_old_session_buffers(target_window)

		-- Ensure target window has empty buffer
		pcall(vim.api.nvim_set_current_win, target_window)
        pcall(function() vim.cmd("enew") end)
	end

	vim.cmd("redraw!")
	cleanup_buffer_caches()

	log.info("clear_current_state: State cleanup completed")
	cache.is_restoring = false
end

-- Enhanced tab switching with comprehensive session management
M.switch_tab = function(tab_id)
	if not tab_id then
		log.warn("switch_tab: Received nil tab_id")
		return false
	end

	if tostring(state.tab_active) == tostring(tab_id) then
		log.info("switch_tab: Already in tab " .. tostring(tab_id))
		return true
	end

	log.info(string.format("switch_tab: Switching from tab %s to tab %s", tostring(state.tab_active), tostring(tab_id)))

	-- Close special windows in batch
	local special_window_operations = {}
	for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
		if vim.api.nvim_win_is_valid(win) and classify_buffer(vim.api.nvim_win_get_buf(win)).is_special then
			table.insert(special_window_operations, function()
				vim.api.nvim_win_close(win, true)
			end)
		end
	end
	execute_window_operations(special_window_operations)

	-- Save current session
	if state.tab_active then
		log.info("switch_tab: Saving current session for tab " .. tostring(state.tab_active))
		M.save_current_state(state.tab_active, true)
	end

	-- Update state and workspace
	local old_tab_active = state.tab_active
	state.tab_active = tab_id

	local workspace_tabs = {
		tab_ids = state.tab_ids,
		tab_active = state.tab_active,
	}
	data.update_workspace_tabs(vim.fn.json_encode(workspace_tabs), state.workspace_id)

	-- Restore new session
	local restore_success = M.restore_state(tab_id, true)
	if not restore_success then
		log.error("switch_tab: Failed to restore session for tab " .. tostring(tab_id) .. ", reverting")

		-- Rollback on failure
		state.tab_active = old_tab_active
		workspace_tabs.tab_active = old_tab_active
		data.update_workspace_tabs(vim.fn.json_encode(workspace_tabs), state.workspace_id)

		if old_tab_active then
			M.restore_state(old_tab_active, true)
		end

		return false
	end

	return true
end

-- Enhanced bulk cleanup with improved performance
M.close_all_file_windows_and_buffers = function()
	log.info("close_all_file_windows_and_buffers: Starting bulk cleanup")

	local normal_windows = {}
	local window_operations = {}

	-- Collect normal windows and prepare operations
	for _, win in ipairs(vim.api.nvim_list_wins()) do
		local config = vim.api.nvim_win_get_config(win)
		if (not config.relative or config.relative == "") and not ui.is_plugin_window(win) then
			table.insert(normal_windows, win)
			table.insert(window_operations, function()
				vim.api.nvim_set_current_win(win)
				vim.cmd("enew")
			end)
		end
	end

	-- Execute window operations
	execute_window_operations(window_operations)

	-- Close extra windows (keep one)
	local close_operations = {}
	for i = 2, #normal_windows do
		table.insert(close_operations, function()
			vim.api.nvim_win_close(normal_windows[i], true)
		end)
	end
	execute_window_operations(close_operations)

	-- Bulk buffer cleanup
	local current_buf = vim.api.nvim_get_current_buf()
	local cleanup_count = 0

	for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_loaded(bufnr) then
			local classification = classify_buffer(bufnr)

			if not classification.is_special and classification.name ~= "" and bufnr ~= current_buf then
				local success = pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
				if success then
					cleanup_count = cleanup_count + 1
				end
			end
		end
	end

	cleanup_buffer_caches()
	log.info("close_all_file_windows_and_buffers: Cleanup completed, removed " .. cleanup_count .. " buffers")
end

-- Enhanced autocommand setup with intelligent debouncing
M.setup_autocmds = function()
	local augroup = vim.api.nvim_create_augroup(SESSION_CONFIG.autocommand_group, { clear = true })

	local function smart_debounced_save()
		if state.tab_active and not cache.is_restoring then
			log.debug("smart_debounced_save: Scheduling save for tab " .. state.tab_active)
			M.save_current_state(state.tab_active, false)
		end
	end

	-- High frequency events with debouncing
	vim.api.nvim_create_autocmd({ "BufEnter", "WinEnter", "FocusGained" }, {
		group = augroup,
		pattern = "*",
		callback = smart_debounced_save,
		desc = "lvim-space: Smart debounced session save",
	})

	-- Important file events with immediate save
	vim.api.nvim_create_autocmd("BufWritePost", {
		group = augroup,
		pattern = "*",
		callback = function()
			if state.tab_active and not cache.is_restoring then
				log.debug("BufWritePost: Immediate save for tab " .. state.tab_active)
				M.save_current_state(state.tab_active, true)
			end
		end,
		desc = "lvim-space: Immediate save on file write",
	})

	-- Idle events with standard save
	vim.api.nvim_create_autocmd("CursorHold", {
		group = augroup,
		pattern = "*",
		callback = function()
			if state.tab_active and not cache.is_restoring then
				log.debug("CursorHold: Standard save for tab " .. state.tab_active)
				M.save_current_state(state.tab_active, false)
			end
		end,
		desc = "lvim-space: Save on cursor hold",
	})

	-- Critical exit event
	vim.api.nvim_create_autocmd("VimLeavePre", {
		group = augroup,
		pattern = "*",
		callback = function()
			if state.tab_active and not cache.is_restoring then
				log.info("VimLeavePre: Force saving session on exit for tab " .. state.tab_active)
				M.save_current_state(state.tab_active, true)
			end
		end,
		desc = "lvim-space: Force save on exit",
	})

	-- Periodic cache cleanup
	vim.fn.timer_start(SESSION_CONFIG.cache_cleanup_interval * 1000, function()
		cleanup_buffer_caches()
	end, { ["repeat"] = -1 })

	log.info("setup_autocmds: Enhanced autocommands configured successfully")
end

-- Main initialization function
M.init = function()
	log.info("session.init: Starting enhanced session manager initialization")

	-- Setup enhanced autocommands
	M.setup_autocmds()

	-- Initial cache cleanup
	cleanup_buffer_caches()

	-- Log current state
	if state.tab_active then
		log.info("session.init: Found active tab " .. state.tab_active .. " (manual restoration only)")
	else
		log.info("session.init: No active tab loaded, restoration will be manual via UI")
	end

	log.info("session.init: Enhanced session manager initialized successfully")
	return true
end

-- Public API for external access
M.get_session_info = function(tab_id)
	local target_tab_id = tab_id or state.tab_active
	if not target_tab_id then
		return nil
	end

	local tab_entry = data.find_tab_by_id(target_tab_id, state.workspace_id)
	if not tab_entry or not tab_entry.data then
		return nil
	end

	local success, session_data = pcall(vim.fn.json_decode, tab_entry.data)
	if success and session_data then
		return {
			tab_id = target_tab_id,
			buffer_count = #(session_data.buffers or {}),
			window_count = #(session_data.windows or {}),
			timestamp = session_data.timestamp,
		}
	end

	return nil
end

M.force_save = function(tab_id)
	return M.save_current_state(tab_id, true)
end

M.force_restore = function(tab_id)
	return M.restore_state(tab_id, true)
end

M.get_cache_stats = function()
	local buffer_cache_count = 0
	for _ in pairs(cache.buffer_cache) do
		buffer_cache_count = buffer_cache_count + 1
	end

	local type_cache_count = 0
	for _ in pairs(cache.buffer_type_cache) do
		type_cache_count = type_cache_count + 1
	end

	return {
		buffer_cache_entries = buffer_cache_count,
		type_cache_entries = type_cache_count,
		is_restoring = cache.is_restoring,
		current_tab_id = cache.current_tab_id,
		last_save = cache.last_save,
	}
end

return M
