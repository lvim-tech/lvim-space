local config = require("lvim-space.config")
local state = require("lvim-space.api.state")
local saved_main = nil
local saved_actions = nil
local saved_cursor_line = nil

local M = {}

state.disable_auto_close = false

vim.opt.guicursor = "n-v-c:block-Cursor/lCursor,i-ci-ve:ver25-Cursor/lCursor,r-cr:hor20,o:hor50"

local auto_close_setup_done = false

M.create_window = function(options)
	local buf = vim.api.nvim_create_buf(false, true)
	local ft = options.filetype or config.filetype or "lvim-space-panel"
	vim.bo[buf].filetype = ft
	if options.content then
		if type(options.content) == "table" then
			vim.api.nvim_buf_set_lines(buf, 0, -1, false, options.content)
		else
			vim.api.nvim_buf_set_lines(buf, 0, -1, false, { tostring(options.content) })
		end
	end
	local win_config = {
		relative = "editor",
		row = options.row or 0,
		col = options.col or 0,
		width = options.width or vim.o.columns,
		height = options.height or 1,
		style = "minimal",
		border = options.border or { "", "", "", "", "", "", "", "" },
		zindex = options.zindex,
		focusable = options.focusable,
	}
	if options.title then
		win_config.title = " " .. options.title .. " "
		win_config.title_pos = options.title_position or "center"
	end
	local win = vim.api.nvim_open_win(buf, options.focus or false, win_config)
	if options.winhighlight then
		vim.wo[win].winhighlight = options.winhighlight
	end
	if options.cursorline ~= nil then
		vim.wo[win].cursorline = options.cursorline
	end
	if options.store_in then
		state.ui = state.ui or {}
		state.ui[options.store_in] = {
			win = win,
			buf = buf,
		}
	end
	if options.on_create then
		options.on_create(win, buf)
	end
	return buf, win
end

M.close_window = function(window_type)
	if not state.ui or not state.ui[window_type] then
		return
	end
	local win = state.ui[window_type].win
	local buf = state.ui[window_type].buf
	if win and vim.api.nvim_win_is_valid(win) then
		vim.api.nvim_win_close(win, true)
	end
	if buf and vim.api.nvim_buf_is_valid(buf) then
		vim.api.nvim_buf_delete(buf, { force = true })
	end
	state.ui[window_type] = {}
end

M.is_plugin_window = function(win)
	if not state.ui then
		return false
	end
	local window_types = { "content", "status_line", "prompt_window", "input_window" }
	for _, win_type in ipairs(window_types) do
		if state.ui[win_type] and state.ui[win_type].win == win then
			return true
		end
	end
	return false
end

M.setup_auto_close = function()
	if auto_close_setup_done then
		return
	end
	auto_close_setup_done = true
	local group = vim.api.nvim_create_augroup("LvimSpaceAutoClose", { clear = true })
	vim.api.nvim_create_autocmd("WinEnter", {
		group = group,
		callback = function()
			if state.disable_auto_close then
				return
			end
			local current_win = vim.api.nvim_get_current_win()
			if not M.is_plugin_window(current_win) then
				M.close_all()
			end
		end,
	})
end

M.open_main = function(lines, name, selected_line)
	M.save_main()
	M.close_window("content")
	local status_space = 2
	local content_height = #lines
	local win_height = math.min(math.max(content_height, 1), config.max_height or 10)
	local main_border = { " ", " ", " ", "", "", "", "", "" }
	local border_sign = config.ui.border.sign or ""
	local main_config = config.ui.border.maint or {}
	if main_config.left then
		main_border[8] = border_sign
	end
	if main_config.right then
		main_border[4] = border_sign
	end

	if not selected_line and state and state.project_id and M.project_ids then
		for i, pid in ipairs(M.project_ids) do
			if tostring(pid) == tostring(state.project_id) then
				selected_line = i
				break
			end
		end
	end
	selected_line = selected_line or 1

	local orig_cursor = vim.api.nvim_get_hl(0, { name = "Cursor" })
	local orig_cursor_fg = orig_cursor.fg
	local orig_cursor_bg = orig_cursor.bg
	local buf, win = M.create_window({
		content = lines,
		title = name or config.title or "LVIM SPACE",
		title_position = config.title_position or "center",
		row = vim.o.lines - win_height - status_space,
		col = 0,
		width = vim.o.columns,
		height = win_height,
		focus = true,
		store_in = "content",
		cursorline = true,
		winhighlight = table.concat({
			"Normal:LvimSpaceNormal",
			"NormalNC:LvimSpaceNormal",
			"CursorLine:LvimSpaceCursorLine",
			"FloatTitle:LvimSpaceTitle",
			"FloatBorder:LvimSpaceNormal",
		}, ","),
		border = main_border,
		on_create = function(win, buf)
			local cursor_group = vim.api.nvim_create_augroup("LvimSpaceCursor", { clear = true })
			local win_cursor = vim.api.nvim_get_hl(0, { name = "LvimSpaceCursorLine" })
			local win_cursor_fg = win_cursor.fg
			local win_cursor_bg = win_cursor.bg
			vim.api.nvim_set_hl(0, "Cursor", { fg = win_cursor_fg, bg = win_cursor_bg })
			vim.api.nvim_create_autocmd("WinLeave", {
				pattern = "*",
				group = cursor_group,
				callback = function()
					local current_win = vim.api.nvim_get_current_win()
					if current_win == win then
						vim.api.nvim_set_hl(0, "Cursor", {
							fg = orig_cursor_fg,
							bg = orig_cursor_bg,
						})
					end
				end,
			})
			vim.api.nvim_create_autocmd("WinEnter", {
				pattern = "*",
				group = cursor_group,
				callback = function()
					local current_win = vim.api.nvim_get_current_win()
					if current_win == win then
						vim.api.nvim_set_hl(0, "Cursor", { fg = win_cursor_fg, bg = win_cursor_bg })
					end
				end,
			})
			vim.api.nvim_create_autocmd("BufWipeout", {
				buffer = buf,
				group = cursor_group,
				callback = function()
					vim.api.nvim_set_hl(0, "Cursor", {
						fg = orig_cursor_fg,
						bg = orig_cursor_bg,
					})
					vim.api.nvim_del_augroup_by_name("LvimSpaceCursor")
					if not state.disable_auto_close then
						M.close_actions()
					end
				end,
				once = true,
			})
			local keymaps = require("lvim-space.core.keymaps")
			keymaps.disable_all_maps(buf)
			keymaps.enable_base_maps(buf)
			vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "VimResized" }, {
				buffer = buf,
				callback = function()
					local new_content = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
					local new_content_height = #new_content
					local new_height = math.min(math.max(new_content_height, 1), config.max_height or 10)
					local current_config = vim.api.nvim_win_get_config(win)
					local current_border = current_config.border
					vim.api.nvim_win_set_config(win, {
						relative = "editor",
						row = vim.o.lines - new_height - status_space,
						col = 0,
						height = new_height,
						width = vim.o.columns,
						border = current_border,
					})
					local line = selected_line or 1
					local line_count = vim.api.nvim_buf_line_count(buf)
					line = math.max(1, math.min(line, line_count))
					vim.api.nvim_win_set_cursor(win, { line, 0 })
				end,
			})
			local line = selected_line or 1
			local line_count = vim.api.nvim_buf_line_count(buf)
			line = math.max(1, math.min(line, line_count))
			vim.defer_fn(function()
				if vim.api.nvim_win_is_valid(win) then
					vim.api.nvim_win_set_cursor(win, { line, 0 })
				end
			end, 10)
		end,
	})
	return buf, win
end

M.open_actions = function(line)
	M.save_actions()
	M.close_window("status_line")
	local info_border = { "", "", "", "", "", "", "", "" }
	local border_sign = config.ui.border.sign
	if config.ui.border.info.left then
		info_border[8] = border_sign
	end
	if config.ui.border.info.right then
		info_border[4] = border_sign
	end
	local buf, win = M.create_window({
		content = line,
		row = vim.o.lines - 1,
		col = 0,
		width = vim.o.columns,
		height = 1,
		zindex = 50,
		focusable = false,
		store_in = "status_line",
		winhighlight = "Normal:LvimSpaceInfo,NormalNC:LvimSpaceInfo,FloatBorder:LvimSpaceInfo",
		border = info_border,
	})
	return buf, win
end

M.close_content = function()
	M.close_window("content")
	M.close_actions()
end

M.close_actions = function()
	M.close_window("status_line")
end

M.close_all = function()
	M.close_window("prompt_window")
	M.close_window("input_window")
	M.close_window("status_line")
	M.close_window("content")
end

M.save_content = function()
	M.save_main()
	M.save_actions()
end

M.save_main = function()
	if state.ui and state.ui.content and state.ui.content.buf and vim.api.nvim_buf_is_valid(state.ui.content.buf) then
		saved_main = vim.api.nvim_buf_get_lines(state.ui.content.buf, 0, -1, false)
	end
end

M.save_actions = function()
	if
		state.ui
		and state.ui.status_line
		and state.ui.status_line.buf
		and vim.api.nvim_buf_is_valid(state.ui.status_line.buf)
	then
		saved_actions = vim.api.nvim_buf_get_lines(state.ui.status_line.buf, 0, -1, false)
	end
end

M.restore_content = function()
	M.restore_main()
	M.restore_actions()
end

M.restore_main = function()
	if saved_main and #saved_main > 0 then
		M.close_window("content")
		M.open_main(saved_main)
	end
end

M.restore_actions = function()
	if saved_actions and #saved_actions > 0 then
		M.close_window("status_line")
		M.open_actions(saved_actions[1])
	end
end

M.calculate_input_dimensions = function(prompt)
	local total_width = vim.o.columns
	local prompt_separator = config.ui.border.prompt.separate or ": "
	local prompt_text = prompt .. prompt_separator
	local prompt_width = vim.fn.strdisplaywidth(prompt_text)
	local prompt_border_width = 0
	if config.ui.border.prompt.left then
		prompt_border_width = prompt_border_width + 1
	end
	if config.ui.border.prompt.right then
		prompt_border_width = prompt_border_width + 1
	end
	local input_border_width = 0
	if config.ui.border.input.left then
		input_border_width = input_border_width + 1
	end
	if config.ui.border.input.right then
		input_border_width = input_border_width + 1
	end
	local prompt_content_width = prompt_width
	local prompt_total_width = prompt_content_width + prompt_border_width
	local input_col = prompt_total_width
	local min_input_width = 20
	local input_content_width = math.max(min_input_width, total_width - input_col - input_border_width)
	return {
		prompt_text = prompt_text,
		prompt_width = prompt_content_width,
		prompt_total_width = prompt_total_width,
		input_col = input_col,
		input_width = input_content_width,
		prompt_border_left = config.ui.border.prompt.left,
		prompt_border_right = config.ui.border.prompt.right,
		input_border_left = config.ui.border.input.left,
		input_border_right = config.ui.border.input.right,
	}
end

function M.create_input_field(prompt, default_value, callback)
	state.disable_auto_close = true
	if state.ui and state.ui.content and state.ui.content.win and vim.api.nvim_win_is_valid(state.ui.content.win) then
		local cursor_pos = vim.api.nvim_win_get_cursor(state.ui.content.win)
		saved_cursor_line = cursor_pos[1]
	end
	M.save_actions()
	M.close_window("status_line")
	local dims = M.calculate_input_dimensions(prompt)
	local prompt_text = dims.prompt_text
	local prompt_border = { "", "", "", "", "", "", "", "" }
	if dims.prompt_border_left then
		prompt_border[8] = config.ui.border.sign
	end
	if dims.prompt_border_right then
		prompt_border[4] = config.ui.border.sign
	end
	local input_border = { "", "", "", "", "", "", "", "" }
	if dims.input_border_left then
		input_border[8] = config.ui.border.sign
	end
	if dims.input_border_right then
		input_border[4] = config.ui.border.sign
	end
	local prompt_buf, prompt_win = M.create_window({
		content = prompt_text,
		row = vim.o.lines - 1,
		col = 0,
		width = dims.prompt_width,
		height = 1,
		zindex = 50,
		focusable = false,
		winhighlight = "Normal:LvimSpacePrompt,NormalNC:LvimSpacePrompt,FloatBorder:LvimSpacePrompt",
		border = prompt_border,
	})
	local input_buf, input_win = M.create_window({
		content = default_value or "",
		row = vim.o.lines - 1,
		col = dims.input_col,
		width = dims.input_width,
		height = 1,
		zindex = 50,
		focusable = true,
		focus = true,
		store_in = "input_window",
		winhighlight = "Normal:LvimSpaceInput,NormalNC:LvimSpaceInput,FloatBorder:LvimSpaceInput",
		border = input_border,
		on_create = function(win, buf)
			vim.api.nvim_buf_set_var(buf, "input_callback", callback)
			vim.api.nvim_buf_set_var(buf, "input_default", default_value or "")
			vim.api.nvim_buf_set_var(buf, "prompt_win", prompt_win)
			vim.api.nvim_buf_set_var(buf, "prompt_buf", prompt_buf)
			vim.keymap.set("i", "<Esc>", function()
				M.cancel_input()
			end, {
				buffer = buf,
				noremap = true,
				silent = true,
				nowait = true,
			})
			vim.keymap.set("i", "<CR>", function()
				M.submit_input()
			end, {
				buffer = buf,
				noremap = true,
				silent = true,
				nowait = true,
			})
			local group = vim.api.nvim_create_augroup("LvimSpaceInputHandling", { clear = true })
			vim.api.nvim_create_autocmd("FocusLost", {
				buffer = buf,
				group = group,
				callback = function()
					vim.schedule(function()
						if not vim.api.nvim_buf_is_valid(buf) then
							return
						end
						local current_win = vim.api.nvim_get_current_win()
						if current_win == prompt_win then
							vim.api.nvim_set_current_win(win)
							vim.cmd("startinsert!")
						elseif current_win ~= win then
							M.cancel_input()
						end
					end)
				end,
			})
			vim.api.nvim_create_autocmd("WinEnter", {
				group = group,
				callback = function()
					local current_win = vim.api.nvim_get_current_win()
					if current_win == prompt_win and vim.api.nvim_win_is_valid(win) then
						vim.api.nvim_set_current_win(win)
						vim.cmd("startinsert!")
					end
				end,
			})
			local line_length = #(default_value or "")
			vim.api.nvim_win_set_cursor(win, { 1, line_length })
			vim.schedule(function()
				if vim.api.nvim_win_is_valid(win) then
					vim.api.nvim_set_current_win(win)
					vim.cmd("startinsert!")
				end
				vim.defer_fn(function()
					if vim.api.nvim_win_is_valid(win) then
						vim.api.nvim_set_current_win(win)
						vim.cmd("startinsert!")
					end
				end, 10)
			end)
		end,
	})
	state.ui.prompt_window = {
		win = prompt_win,
		buf = prompt_buf,
	}
	state.ui.input_window = {
		win = input_win,
		buf = input_buf,
	}
	return input_buf, input_win
end

function M.cancel_input()
	local mode = vim.api.nvim_get_mode().mode
	if mode == "i" or mode == "ic" or mode == "ix" then
		vim.cmd("stopinsert")
	end
	M.close_window("prompt_window")
	M.close_window("input_window")
	state.disable_auto_close = false
	M.close_window("status_line")
	M.restore_actions()
	if state.ui and state.ui.content and state.ui.content.win and vim.api.nvim_win_is_valid(state.ui.content.win) then
		vim.api.nvim_set_current_win(state.ui.content.win)
		if saved_cursor_line then
			pcall(vim.api.nvim_win_set_cursor, state.ui.content.win, { saved_cursor_line, 0 })
		end
	end
end

function M.submit_input()
	local buf = vim.api.nvim_get_current_buf()
	vim.cmd("stopinsert")
	local input_value = nil
	local callback = nil
	if vim.api.nvim_buf_is_valid(buf) then
		input_value = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]
		callback = vim.api.nvim_buf_get_var(buf, "input_callback")
	end
	M.close_window("prompt_window")
	M.close_window("input_window")
	state.disable_auto_close = false
	M.close_window("status_line")
	M.restore_actions()
	if state.ui and state.ui.content and state.ui.content.win and vim.api.nvim_win_is_valid(state.ui.content.win) then
		vim.api.nvim_set_current_win(state.ui.content.win)
		if saved_cursor_line then
			pcall(vim.api.nvim_win_set_cursor, state.ui.content.win, { saved_cursor_line, 0 })
		end
	end
	if type(callback) == "function" then
		vim.schedule(function()
			callback(input_value)
		end)
	end
end

M.setup_auto_close()

return M
