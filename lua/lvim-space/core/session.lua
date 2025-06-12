local config = require("lvim-space.config")
local data = require("lvim-space.api.data")
local state = require("lvim-space.api.state")
local ui = require("lvim-space.ui")

local M = {}

local SESSION_CONFIG = {
    save_interval = 2000,
    restore_delay = 200,
    debounce_delay = 200,
    cache_cleanup_interval = 30,
    autocommand_group = "LvimSpaceSessionAutocmds",
    max_cache_size = 1000,
}

local cache = {
    last_save = 0,
    current_tab_id = nil,
    is_restoring = false,
    pending_save = nil,
    buffer_cache = setmetatable({}, { __mode = "v" }),
    buffer_type_cache = setmetatable({}, { __mode = "kv" }),
    path_validation_cache = setmetatable({}, { __mode = "k" }),
    cache_stats = { hits = 0, misses = 0, evictions = 0 },
}

local function classify_buffer(bufnr)
    if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
        return { is_special = false, is_valid = false }
    end
    local cached = cache.buffer_type_cache[bufnr]
    if cached then
        cache.cache_stats.hits = cache.cache_stats.hits + 1
        return cached
    end
    cache.cache_stats.misses = cache.cache_stats.misses + 1
    local buf_options = vim.bo[bufnr]
    local buf_name = vim.api.nvim_buf_get_name(bufnr)
    local filetype = buf_options.filetype
    local buftype = buf_options.buftype
    local is_special = false
    if buftype ~= "" and buftype ~= "normal" then
        is_special = true
    elseif buf_name == "" then
        is_special = true
    elseif not buf_options.buflisted then
        is_special = true
    end
    local classification = {
        is_special = is_special,
        is_valid = true,
        is_listed = buf_options.buflisted,
        name = buf_name,
        filetype = filetype,
    }
    cache.buffer_type_cache[bufnr] = classification
    return classification
end

local function cleanup_buffer_caches()
    local cleaned_count = 0
    for bufnr in pairs(cache.buffer_type_cache) do
        if not vim.api.nvim_buf_is_valid(bufnr) then
            cache.buffer_type_cache[bufnr] = nil
            cleaned_count = cleaned_count + 1
        end
    end
    for file_path, bufnr in pairs(cache.buffer_cache) do
        if not vim.api.nvim_buf_is_valid(bufnr) then
            cache.buffer_cache[file_path] = nil
            cleaned_count = cleaned_count + 1
        end
    end
    local path_cache_size = 0
    for _ in pairs(cache.path_validation_cache) do
        path_cache_size = path_cache_size + 1
    end
    if path_cache_size > SESSION_CONFIG.max_cache_size then
        cache.path_validation_cache = setmetatable({}, { __mode = "k" })
        cache.cache_stats.evictions = cache.cache_stats.evictions + 1
    end
    return cleaned_count
end

local function is_valid_file_path(file_path)
    if cache.path_validation_cache[file_path] ~= nil then
        return cache.path_validation_cache[file_path]
    end
    local is_valid = vim.fn.filereadable(file_path) == 1
    cache.path_validation_cache[file_path] = is_valid
    return is_valid
end

local function get_or_create_buffer(file_path)
    local cached_bufnr = cache.buffer_cache[file_path]
    if cached_bufnr and vim.api.nvim_buf_is_valid(cached_bufnr) then
        return cached_bufnr
    end
    if cached_bufnr then
        cache.buffer_cache[file_path] = nil
    end
    if not is_valid_file_path(file_path) then
        return nil
    end
    local bufnr = vim.fn.bufadd(file_path)
    vim.bo[bufnr].buflisted = true
    cache.buffer_cache[file_path] = bufnr
    return bufnr
end

local function collect_tab_session_data(tab_id)
    local valid_buffers = {}
    local path_to_idx = {}
    local files_in_tab = data.find_files(tab_id, state.workspace_id) or {}
    local valid_paths = {}
    for _, entry in ipairs(files_in_tab) do
        local path = entry.path or entry.filePath
        if path then
            valid_paths[vim.fn.fnamemodify(path, ":p")] = true
        end
    end
    local buffer_cursor_info = {}
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        if vim.api.nvim_win_is_valid(win) and not ui.is_plugin_window(win) then
            local bufnr = vim.api.nvim_win_get_buf(win)
            local c = classify_buffer(bufnr)
            if not c.is_special and c.name ~= "" then
                local abs_path = vim.fn.fnamemodify(c.name, ":p")
                if valid_paths[abs_path] then
                    local cursor_ok, cursor = pcall(vim.api.nvim_win_get_cursor, win)
                    if cursor_ok then
                        if not buffer_cursor_info[abs_path] or win == vim.api.nvim_get_current_win() then
                            local topline = vim.api.nvim_win_call(win, function()
                                return vim.fn.line("w0")
                            end)
                            local leftcol = vim.api.nvim_win_call(win, function()
                                return vim.fn.winsaveview().leftcol or 0
                            end)
                            buffer_cursor_info[abs_path] = {
                                cursor_line = cursor[1],
                                cursor_col = cursor[2],
                                topline = topline,
                                leftcol = leftcol,
                            }
                        end
                    end
                end
            end
        end
    end
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
        local c = classify_buffer(bufnr)
        if c.is_valid and not c.is_special and c.name ~= "" then
            local abs = vim.fn.fnamemodify(c.name, ":p")
            if valid_paths[abs] and c.is_listed and not path_to_idx[abs] then
                local buffer_entry = {
                    filePath = abs,
                    bufnr = bufnr,
                    filetype = c.filetype,
                }
                if buffer_cursor_info[abs] then
                    buffer_entry.cursor_line = buffer_cursor_info[abs].cursor_line
                    buffer_entry.cursor_col = buffer_cursor_info[abs].cursor_col
                    buffer_entry.topline = buffer_cursor_info[abs].topline
                    buffer_entry.leftcol = buffer_cursor_info[abs].leftcol
                end
                table.insert(valid_buffers, buffer_entry)
                path_to_idx[abs] = #valid_buffers
            end
        end
    end
    if #valid_buffers == 0 then
        return nil, "No valid buffers found"
    end
    local windows = {}
    local current_win = vim.api.nvim_get_current_win()
    local current_window_index, valid_window_count = nil, 0
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        if vim.api.nvim_win_is_valid(win) and not ui.is_plugin_window(win) then
            local bufnr = vim.api.nvim_win_get_buf(win)
            if not classify_buffer(bufnr).is_special then
                local abs = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":p")
                if path_to_idx[abs] then
                    valid_window_count = valid_window_count + 1
                    local pos = vim.api.nvim_win_get_position(win)
                    local cursor = pcall(vim.api.nvim_win_get_cursor, win) and vim.api.nvim_win_get_cursor(win)
                        or { 1, 0 }
                    local topline = vim.api.nvim_win_call(win, function()
                        return vim.fn.line("w0")
                    end)
                    local leftcol = vim.api.nvim_win_call(win, function()
                        return vim.fn.winsaveview().leftcol or 0
                    end)
                    table.insert(windows, {
                        file_path = abs,
                        buffer_index = path_to_idx[abs],
                        width = vim.api.nvim_win_get_width(win),
                        height = vim.api.nvim_win_get_height(win),
                        row = pos[1],
                        col = pos[2],
                        cursor_line = cursor[1],
                        cursor_col = cursor[2],
                        topline = topline,
                        leftcol = leftcol,
                    })
                    if win == current_win then
                        current_window_index = valid_window_count
                    end
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

local function create_debounced_save(tab_id)
    return function()
        if cache.pending_save then
            vim.fn.timer_stop(cache.pending_save)
            cache.pending_save = nil
        end
        cache.pending_save = vim.fn.timer_start(SESSION_CONFIG.debounce_delay, function()
            cache.pending_save = nil
            M.save_current_state(tab_id, true)
        end)
    end
end

M.save_current_state = function(tab_id, force)
    local t = tab_id or state.tab_active
    if not t then
        return false
    end
    if cache.pending_save then
        vim.fn.timer_stop(cache.pending_save)
        cache.pending_save = nil
    end
    local now = vim.uv and vim.uv.now() or vim.loop.now()
    if not force and not cache.is_restoring and now - cache.last_save < SESSION_CONFIG.save_interval then
        create_debounced_save(t)()
        return false
    end
    if cache.is_restoring then
        return false
    end
    cache.last_save = now
    local sd, _ = collect_tab_session_data(t)
    if not sd then
        return false
    end
    sd.tab_id = t
    local ok, js = pcall(vim.fn.json_encode, sd)
    if not ok then
        return false
    end
    local tab_entry = data.find_tab_by_id(t, state.workspace_id)
    if not tab_entry then
        return false
    end
    if not data.update_tab_data(t, js, state.workspace_id) then
        return false
    end
    return true
end

local function force_single_window()
    local wins = {}
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        if
            vim.api.nvim_win_is_valid(w)
            and not ui.is_plugin_window(w)
            and not classify_buffer(vim.api.nvim_win_get_buf(w)).is_special
        then
            table.insert(wins, w)
        end
    end
    if #wins == 0 then
        local normal_wins = {}
        for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
            if vim.api.nvim_win_is_valid(w) and not ui.is_plugin_window(w) then
                table.insert(normal_wins, w)
            end
        end
        if #normal_wins > 0 then
            local curwin = normal_wins[1]
            vim.api.nvim_set_current_win(curwin)
            vim.cmd("enew")
            return curwin
        else
            vim.cmd("new")
            return vim.api.nvim_get_current_win()
        end
    end
    local t = wins[1]
    if #wins > 1 then
        for i = 2, #wins do
            pcall(vim.api.nvim_win_close, wins[i], true)
        end
    end
    return t
end

local function cleanup_old_session_buffers(keep)
    local kp = {}
    for _, b in ipairs(keep or {}) do
        kp[b] = true
    end
    local del = {}
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
        if
            not kp[b]
            and classify_buffer(b).is_valid
            and not classify_buffer(b).is_special
            and vim.api.nvim_buf_get_name(b) ~= ""
        then
            local skip = false
            for _, win in ipairs(vim.api.nvim_list_wins()) do
                if
                    vim.api.nvim_win_is_valid(win)
                    and ui.is_plugin_window(win)
                    and vim.api.nvim_win_get_buf(win) == b
                then
                    skip = true
                    break
                end
            end
            if not skip then
                table.insert(del, b)
            end
        end
    end
    if #del <= 1 then
        return
    end
    local normal_windows = 0
    for _, win in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_is_valid(win) and not ui.is_plugin_window(win) then
            normal_windows = normal_windows + 1
        end
    end
    local buffers_to_delete = normal_windows > 1 and del or {}
    if normal_windows == 1 and #del > 0 then
        for i = 1, #del - 1 do
            table.insert(buffers_to_delete, del[i])
        end
    else
        buffers_to_delete = del
    end
    for _, buf in ipairs(buffers_to_delete) do
        pcall(vim.api.nvim_buf_delete, buf, { force = true, unload = true })
    end
end

local function restore_session_layout(sd, fmap, init)
    if not sd.windows or type(sd.windows) ~= "table" or #sd.windows == 0 then
        return { [1] = init }
    end
    local created = { [1] = init }
    local posmap = { [1] = { row = 0, col = 0 } }

    local cursor_restore_queue = {}

    local w1 = sd.windows[1]
    if w1 and w1.file_path and fmap[w1.file_path] then
        pcall(function()
            vim.api.nvim_win_set_buf(init, fmap[w1.file_path])

            table.insert(cursor_restore_queue, {
                win = init,
                cursor_line = w1.cursor_line,
                cursor_col = w1.cursor_col,
                topline = w1.topline,
                leftcol = w1.leftcol,
            })
        end)
    end
    for i = 2, #sd.windows do
        local wi = sd.windows[i]
        if wi.file_path and fmap[wi.file_path] then
            local tr, tc = wi.row or 0, wi.col or 0
            local best, dist = 1, math.huge
            for j, p in pairs(posmap) do
                local d = math.abs((p.row or 0) - tr) + math.abs((p.col or 0) - tc)
                if d < dist then
                    best, dist = j, d
                end
            end
            local parent = created[best]
            if parent and vim.api.nvim_win_is_valid(parent) and not ui.is_plugin_window(parent) then
                vim.api.nvim_set_current_win(parent)
                local split_cmd = (tc ~= (posmap[best].col or 0)) and "vsplit" or "split"
                pcall(function()
                    vim.cmd(split_cmd)
                end)
                local nw = vim.api.nvim_get_current_win()
                pcall(function()
                    vim.api.nvim_win_set_buf(nw, fmap[wi.file_path])

                    table.insert(cursor_restore_queue, {
                        win = nw,
                        cursor_line = wi.cursor_line,
                        cursor_col = wi.cursor_col,
                        topline = wi.topline,
                        leftcol = wi.leftcol,
                    })
                end)
                created[i] = nw
                posmap[i] = {
                    row = tr,
                    col = tc,
                }
            end
        end
    end
    vim.schedule(function()
        for _, restore_info in ipairs(cursor_restore_queue) do
            if vim.api.nvim_win_is_valid(restore_info.win) then
                local bufnr = vim.api.nvim_win_get_buf(restore_info.win)
                if vim.api.nvim_buf_is_loaded(bufnr) then
                    pcall(function()
                        if restore_info.cursor_line and restore_info.cursor_col then
                            local line_count = vim.api.nvim_buf_line_count(bufnr)
                            local safe_line = math.min(restore_info.cursor_line, line_count)
                            local line_content = vim.api.nvim_buf_get_lines(bufnr, safe_line - 1, safe_line, false)[1]
                                or ""
                            local safe_col = math.min(restore_info.cursor_col, #line_content)
                            vim.api.nvim_win_set_cursor(restore_info.win, { safe_line, safe_col })
                        end

                        if restore_info.topline or restore_info.leftcol then
                            vim.api.nvim_win_call(restore_info.win, function()
                                local view = vim.fn.winsaveview()
                                if restore_info.topline then
                                    view.topline = restore_info.topline
                                end
                                if restore_info.leftcol then
                                    view.leftcol = restore_info.leftcol
                                end
                                vim.fn.winrestview(view)
                            end)
                        end
                    end)
                end
            end
        end
    end)
    return created
end

M.restore_state = function(tab_id, force)
    if not tab_id then
        return false
    end
    if tab_id == cache.current_tab_id and not force then
        return true
    end
    local te = data.find_tab_by_id(tab_id, state.workspace_id)
    if not te or not te.data then
        M.clear_current_state()
        return true
    end
    local ok, sd = pcall(vim.fn.json_decode, te.data)
    if not ok or not sd or not sd.buffers or #sd.buffers == 0 then
        M.clear_current_state()
        return true
    end
    cache.current_tab_id = tab_id
    cache.is_restoring = true
    vim.schedule(function()
        if cache.current_tab_id ~= tab_id then
            cache.is_restoring = false
            return
        end
        pcall(function()
            cleanup_buffer_caches()
            local saved_hidden = vim.o.hidden
            vim.o.hidden = true
            local init = force_single_window()
            local to_keep = {}
            for _, bi in ipairs(sd.buffers) do
                local b = cache.buffer_cache[bi.filePath]
                if b and vim.api.nvim_buf_is_valid(b) then
                    table.insert(to_keep, b)
                end
            end
            cleanup_old_session_buffers(to_keep)
            local fmap = {}
            for _, bi in ipairs(sd.buffers) do
                local b = get_or_create_buffer(bi.filePath)
                if b then
                    fmap[bi.filePath] = b
                end
            end
            local cw = restore_session_layout(sd, fmap, init)
            local validwins = {}
            for _, w in ipairs(cw) do
                if w and vim.api.nvim_win_is_valid(w) then
                    validwins[w] = true
                end
            end
            for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
                if vim.api.nvim_win_is_valid(w) and not validwins[w] and not ui.is_plugin_window(w) then
                    pcall(vim.api.nvim_win_close, w, true)
                end
            end
            local target
            if sd.current_window and cw[sd.current_window] then
                target = cw[sd.current_window]
            end
            if not target or not vim.api.nvim_win_is_valid(target) then
                for i = #cw, 1, -1 do
                    if cw[i] and vim.api.nvim_win_is_valid(cw[i]) then
                        target = cw[i]
                        break
                    end
                end
            end
            if target and not ui.is_plugin_window(target) then
                pcall(vim.api.nvim_set_current_win, target)
            end
            vim.o.hidden = saved_hidden
        end)
        vim.cmd("redraw!")
        cache.is_restoring = false
    end)
    return true
end

M.clear_current_state = function()
    cache.is_restoring = true
    local tw = force_single_window()
    if tw and vim.api.nvim_win_is_valid(tw) and not ui.is_plugin_window(tw) then
        vim.api.nvim_set_current_win(tw)
        vim.cmd("enew")
        cleanup_old_session_buffers({})
    end
    vim.cmd("redraw!")
    cleanup_buffer_caches()
    cache.is_restoring = false
end

M.switch_tab = function(tab_id)
    if not tab_id then
        return false
    end
    if tostring(state.tab_active) == tostring(tab_id) then
        return true
    end
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        if
            vim.api.nvim_win_is_valid(w)
            and classify_buffer(vim.api.nvim_win_get_buf(w)).is_special
            and not ui.is_plugin_window(w)
        then
            pcall(vim.api.nvim_win_close, w, true)
        end
    end
    if state.tab_active then
        M.save_current_state(state.tab_active, true)
    end
    local old = state.tab_active
    state.tab_active = tab_id
    local ws = { tab_ids = state.tab_ids, tab_active = state.tab_active }
    data.update_workspace_tabs(vim.fn.json_encode(ws), state.workspace_id)
    M.clear_current_state()
    if not M.restore_state(tab_id, true) then
        state.tab_active = old
        ws.tab_active = old
        data.update_workspace_tabs(vim.fn.json_encode(ws), state.workspace_id)
        if old then
            M.restore_state(old, true)
        end
        return false
    end
    return true
end

M.close_all_file_windows_and_buffers = function()
    local normal_windows = {}
    for _, win in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_is_valid(win) and not ui.is_plugin_window(win) then
            table.insert(normal_windows, win)
        end
    end
    local windows_to_close = {}
    if #normal_windows > 1 then
        for i = 2, #normal_windows do
            table.insert(windows_to_close, normal_windows[i])
        end
    end
    for _, win in ipairs(windows_to_close) do
        pcall(vim.api.nvim_win_close, win, true)
    end
    local current_buf = vim.api.nvim_get_current_buf()
    local buffers_to_delete = {}
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(b) and b ~= current_buf then
            local c = classify_buffer(b)
            if not c.is_special and vim.api.nvim_buf_get_name(b) ~= "" then
                local skip = false
                for _, win in ipairs(vim.api.nvim_list_wins()) do
                    if
                        vim.api.nvim_win_is_valid(win)
                        and ui.is_plugin_window(win)
                        and vim.api.nvim_win_get_buf(win) == b
                    then
                        skip = true
                        break
                    end
                end
                if not skip then
                    table.insert(buffers_to_delete, b)
                end
            end
        end
    end
    if #normal_windows == 0 then
        vim.cmd("new")
    elseif #buffers_to_delete > 0 then
        local remaining_normal_windows = 0
        for _, win in ipairs(vim.api.nvim_list_wins()) do
            if vim.api.nvim_win_is_valid(win) and not ui.is_plugin_window(win) then
                remaining_normal_windows = remaining_normal_windows + 1
            end
        end
        if remaining_normal_windows == 1 and #buffers_to_delete >= 1 then
            for i = 1, math.max(0, #buffers_to_delete - 1) do
                pcall(vim.api.nvim_buf_delete, buffers_to_delete[i], { force = true })
            end
        else
            for _, buf in ipairs(buffers_to_delete) do
                pcall(vim.api.nvim_buf_delete, buf, { force = true })
            end
        end
    end
    cleanup_buffer_caches()
end

M.setup_autocmds = function()
    local aug = vim.api.nvim_create_augroup(SESSION_CONFIG.autocommand_group, { clear = true })
    local function smart_debounced_save()
        if state.tab_active and not cache.is_restoring then
            M.save_current_state(state.tab_active, false)
        end
    end
    vim.api.nvim_create_autocmd({ "BufEnter", "WinEnter", "FocusGained", "CursorHold" }, {
        group = aug,
        pattern = "*",
        callback = smart_debounced_save,
    })
    vim.api.nvim_create_autocmd("BufWritePost", {
        group = aug,
        pattern = "*",
        callback = function()
            if state.tab_active and not cache.is_restoring then
                M.save_current_state(state.tab_active, true)
            end
        end,
    })
    vim.api.nvim_create_autocmd("BufWinEnter", {
        group = aug,
        pattern = "*",
        callback = function(args)
            vim.schedule(function()
                local b = args.buf
                if not vim.api.nvim_buf_is_valid(b) or vim.bo[b].buftype ~= "" then
                    return
                end
                for _, win in ipairs(vim.api.nvim_list_wins()) do
                    if
                        vim.api.nvim_win_is_valid(win)
                        and ui.is_plugin_window(win)
                        and vim.api.nvim_win_get_buf(win) == b
                    then
                        return
                    end
                end
                local name = vim.api.nvim_buf_get_name(b)
                if name == "" or not is_valid_file_path(name) then
                    return
                end
                if not state.workspace_id or not state.tab_active then
                    return
                end
                local files = data.find_files(state.tab_active, state.workspace_id) or {}
                local abs = vim.fn.fnamemodify(name, ":p")
                for _, e in ipairs(files) do
                    local p = e.path or e.filePath
                    if p and vim.fn.fnamemodify(p, ":p") == abs then
                        return
                    end
                end
                require("lvim-space.ui.files").add_current_buffer_to_tab(not config.open_panel_on_add_file)
            end)
        end,
    })
    vim.api.nvim_create_autocmd("VimLeavePre", {
        group = aug,
        pattern = "*",
        callback = function()
            if state.tab_active and not cache.is_restoring then
                M.save_current_state(state.tab_active, true)
            end
        end,
    })
    local cleanup_timer = vim.fn.timer_start(SESSION_CONFIG.cache_cleanup_interval * 1000, function()
        cleanup_buffer_caches()
    end, { ["repeat"] = -1 })
    cache.cleanup_timer = cleanup_timer
end

M.init = function()
    M.setup_autocmds()
    cleanup_buffer_caches()
    return true
end

M.get_session_info = function(tab_id)
    local t = tab_id or state.tab_active
    if not t then
        return nil
    end
    local te = data.find_tab_by_id(t, state.workspace_id)
    if not te or not te.data then
        return nil
    end
    local ok, sd = pcall(vim.fn.json_decode, te.data)
    if ok and sd then
        return {
            tab_id = t,
            buffer_count = #(sd.buffers or {}),
            window_count = #(sd.windows or {}),
            timestamp = sd.timestamp,
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
    local bc, tc, pc = 0, 0, 0
    for _ in pairs(cache.buffer_cache) do
        bc = bc + 1
    end
    for _ in pairs(cache.buffer_type_cache) do
        tc = tc + 1
    end
    for _ in pairs(cache.path_validation_cache) do
        pc = pc + 1
    end
    return {
        buffer_cache_entries = bc,
        type_cache_entries = tc,
        path_cache_entries = pc,
        is_restoring = cache.is_restoring,
        current_tab_id = cache.current_tab_id,
        last_save = cache.last_save,
        cache_hits = cache.cache_stats.hits,
        cache_misses = cache.cache_stats.misses,
        cache_evictions = cache.cache_stats.evictions,
        hit_ratio = cache.cache_stats.hits / math.max(1, cache.cache_stats.hits + cache.cache_stats.misses),
    }
end

M.save_all = function()
    if not state.project_id then
        return false, "No active project"
    end

    if state.workspace_id then
        if state.tab_active then
            M.save_current_state(state.tab_active, true)
        end

        local ws_tabs = {
            tab_ids = state.tab_ids or {},
            tab_active = state.tab_active,
            updated_at = os.time(),
        }
        data.update_workspace_tabs(vim.fn.json_encode(ws_tabs), state.workspace_id)
    end
    if state.project_id and state.workspace_id then
        data.set_workspace_active(state.workspace_id, state.project_id)
    end
    if state.workspace_id and state.tab_ids then
        for _, tab_id in ipairs(state.tab_ids) do
            M.save_current_state(tab_id, true)
        end
    end
    return true
end

return M
