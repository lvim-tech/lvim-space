local M = {}

local state = require("lvim-space.api.state")

-- Обновява информацията за буфер в state.data
function M.update_buffer(tab_id, buf_info)
	if not state.data then
		state.data = {}
	end
	if not state.data[tab_id] then
		state.data[tab_id] = { buffers = {}, windows = {} }
	end

	local found = false
	for i, buf in ipairs(state.data[tab_id].buffers) do
		if buf.path == buf_info.path then
			state.data[tab_id].buffers[i] = buf_info
			found = true
			break
		end
	end
	if not found then
		table.insert(state.data[tab_id].buffers, buf_info)
	end
end

-- Обновява информацията за прозорец в state.data
function M.update_window(tab_id, win_info)
	if not state.data then
		state.data = {}
	end
	if not state.data[tab_id] then
		state.data[tab_id] = { buffers = {}, windows = {} }
	end

	local found = false
	for i, win in ipairs(state.data[tab_id].windows) do
		if win.winid == win_info.winid then
			state.data[tab_id].windows[i] = win_info
			found = true
			break
		end
	end
	if not found then
		table.insert(state.data[tab_id].windows, win_info)
	end
end

-- Главна функция за следене на всички събития
M.track_events = function()
	-- === BUFFERS ===
	vim.api.nvim_create_autocmd({ "BufEnter", "BufWritePost", "BufLeave" }, {
		callback = function(args)
			local tab_id = state.tab_active or 1
			local bufnr = args.buf
			local path = vim.api.nvim_buf_get_name(bufnr)
			if path == "" then
				return
			end

			local cursor = vim.api.nvim_win_get_cursor(0)
			local modified = vim.api.nvim_buf_get_option(bufnr, "modified")

			-- Folds: събира всички затворени fold-ове
			local folds = {}
			for lnum = 1, vim.api.nvim_buf_line_count(bufnr) do
				local start = vim.fn.foldclosed(lnum)
				if start ~= -1 then
					local end_ = vim.fn.foldclosedend(lnum)
					table.insert(folds, { start = start, ["end"] = end_ })
					lnum = end_
				end
			end

			-- Marks: взима всички marks за буфера
			local marks = {}
			for _, mark in ipairs(vim.fn.getmarklist(bufnr)) do
				if mark.mark:match("^[a-zA-Z]$") then
					table.insert(marks, {
						name = mark.mark,
						pos = { mark.pos[2], mark.pos[3] },
					})
				end
			end

			local buf_info = {
				path = path,
				cursor = cursor,
				modified = modified,
				folds = folds,
				marks = marks,
			}

			M.update_buffer(tab_id, buf_info)
		end,
		desc = "Track buffer state for lvim-space session",
	})

	-- === WINDOWS ===
	vim.api.nvim_create_autocmd({ "WinEnter", "WinLeave", "WinClosed", "WinNew", "VimResized" }, {
		callback = function(args)
			local tab_id = state.tab_active or 1
			local winid = vim.api.nvim_get_current_win()
			local bufnr = vim.api.nvim_win_get_buf(winid)
			local path = vim.api.nvim_buf_get_name(bufnr)
			if path == "" then
				return
			end

			local cursor = vim.api.nvim_win_get_cursor(winid)
			local width = vim.api.nvim_win_get_width(winid)
			local height = vim.api.nvim_win_get_height(winid)
			local win_config = vim.api.nvim_win_get_config(winid)

			-- Логика за split type
			local split_type = "unspecified"
			local wins = vim.api.nvim_tabpage_list_wins(0)
			if #wins > 1 then
				-- Вземаме първия прозорец за база
				local main_win = wins[1]
				if main_win ~= winid then
					local main_width = vim.api.nvim_win_get_width(main_win)
					local main_height = vim.api.nvim_win_get_height(main_win)
					if width ~= main_width and height == main_height then
						split_type = "vertical"
					elseif height ~= main_height and width == main_width then
						split_type = "horizontal"
					elseif width ~= main_width and height ~= main_height then
						split_type = "complex"
					end
				end
			end

			local win_info = {
				winid = winid,
				bufnr = bufnr,
				path = path,
				cursor = cursor,
				width = width,
				height = height,
				config = win_config,
				split_type = split_type,
			}

			M.update_window(tab_id, win_info)
		end,
		desc = "Track window state for lvim-space session",
	})

	-- === TABPAGES ===
	vim.api.nvim_create_autocmd({ "TabEnter", "TabLeave", "TabClosed", "TabNew" }, {
		callback = function(args)
			local tabnr = vim.api.nvim_get_current_tabpage()
			state.tab_active = tabnr
			if not vim.tbl_contains(state.tab_ids, tabnr) then
				table.insert(state.tab_ids, tabnr)
			end
			-- Тук може да добавиш логика за serialize/save/restore на табове ако желаеш
		end,
		desc = "Track tabpage state for lvim-space session",
	})
end

return M
