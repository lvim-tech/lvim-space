local config = require("lvim-space.config")
local notify = require("lvim-space.api.notify")
local state = require("lvim-space.api.state")
local data = require("lvim-space.api.data")
local ui = require("lvim-space.ui")
local common = require("lvim-space.ui.common")

local M = {}

local cache = {
    search_results = {},
    file_ids_map = {},
    ctx = nil,
    current_query = "",
    all_files = {},
}

local last_real_win = nil
local is_plugin_panel_win = ui.is_plugin_window

local function get_last_normal_win()
    if last_real_win and vim.api.nvim_win_is_valid(last_real_win) and not is_plugin_panel_win(last_real_win) then
        return last_real_win
    end
    local current_win = vim.api.nvim_get_current_win()
    local wins = vim.api.nvim_tabpage_list_wins(0)
    for _, win_id in ipairs(wins) do
        local cfg = vim.api.nvim_win_get_config(win_id)
        if cfg.relative == "" and not is_plugin_panel_win(win_id) then
            if win_id == current_win then
                return win_id
            end
        end
    end
    for _, win_id in ipairs(wins) do
        local cfg = vim.api.nvim_win_get_config(win_id)
        if cfg.relative == "" and not is_plugin_panel_win(win_id) then
            return win_id
        end
    end
    return current_win
end

local function find_fuzzy_character_matches(text, query)
    if not text or not query or #query == 0 then
        return {}
    end
    local text_lower = text:lower()
    local query_lower = query:lower()
    local current_matches = {}
    local text_idx = 1
    local query_idx = 1
    while text_idx <= #text_lower and query_idx <= #query_lower do
        local text_char = text_lower:sub(text_idx, text_idx)
        local query_char = query_lower:sub(query_idx, query_idx)
        if text_char == query_char then
            table.insert(current_matches, {
                start = text_idx - 1,
                length = 1,
                exact_match = text:sub(text_idx, text_idx) == query:sub(query_idx, query_idx),
                priority = 60,
            })

            query_idx = query_idx + 1
        end
        text_idx = text_idx + 1
    end
    if query_idx > #query_lower then
        return current_matches
    end
    return {}
end

local function find_sequential_matches(text, query)
    local text_lower = text:lower()
    local parts = {}
    local current_part = ""
    for i = 1, #query do
        local char = query:sub(i, i)
        if char == "." then
            if current_part ~= "" then
                table.insert(parts, current_part)
                current_part = ""
            end
            table.insert(parts, ".")
        else
            current_part = current_part .. char
        end
    end
    if current_part ~= "" then
        table.insert(parts, current_part)
    end
    local start_search_pos = 1
    local found_sequence = {}
    for _, part in ipairs(parts) do
        local part_lower = part:lower()
        local match_pos = text_lower:find(part_lower, start_search_pos, true)
        if match_pos then
            table.insert(found_sequence, {
                start = match_pos - 1,
                length = #part,
                exact_match = text:sub(match_pos, match_pos + #part - 1) == part,
                priority = 80,
            })
            start_search_pos = match_pos + #part
        else
            found_sequence = {}
            break
        end
    end
    return found_sequence
end

local function find_all_match_positions(text, query)
    if not text or not query or query == "" then
        return {}
    end
    local matches = {}
    local text_lower = text:lower()
    local query_lower = query:lower()
    local start_pos = 1
    local exact_matches = {}
    while start_pos <= #text do
        local match_pos = text_lower:find(query_lower, start_pos, true)
        if not match_pos then
            break
        end
        table.insert(exact_matches, {
            start = match_pos - 1,
            length = #query,
            exact_match = text:sub(match_pos, match_pos + #query - 1) == query,
            priority = 100,
            position = match_pos,
        })
        start_pos = match_pos + 1
    end
    if #query <= 4 and #exact_matches > 0 then
        local best_match = nil
        local filename_start = text:find("[^/\\]*$") or 1
        for _, match in ipairs(exact_matches) do
            local is_at_end = (match.position + #query - 1) == #text
            local is_in_filename = match.position >= filename_start
            if is_at_end then
                match.priority = 120
                best_match = match
                break
            elseif is_in_filename and (not best_match or match.position > best_match.position) then
                match.priority = 110
                best_match = match
            end
        end
        if best_match then
            return { best_match }
        end
        return { exact_matches[1] }
    end
    if #exact_matches > 0 then
        return exact_matches
    end
    if query:find("%.") then
        matches = find_sequential_matches(text, query)
        if #matches > 0 then
            return matches
        end
    end
    local fuzzy_positions = find_fuzzy_character_matches(text, query)
    if #fuzzy_positions > 0 then
        return fuzzy_positions
    end
    if query:find("%.") then
        local segments = {}
        for segment in query:gmatch("[^%.]+") do
            if segment ~= "" and #segment >= 3 then
                table.insert(segments, segment)
            end
        end
        for _, segment in ipairs(segments) do
            local seg_lower = segment:lower()
            start_pos = 1
            while start_pos <= #text do
                local match_pos = text_lower:find(seg_lower, start_pos, true)
                if not match_pos then
                    break
                end
                table.insert(matches, {
                    start = match_pos - 1,
                    length = #segment,
                    exact_match = text:sub(match_pos, match_pos + #segment - 1) == segment,
                    priority = 30,
                })
                start_pos = match_pos + 1
            end
        end
    end
    return matches
end

local function check_sequential_match(text_lower, pattern_lower)
    local parts = {}
    local current_part = ""
    for i = 1, #pattern_lower do
        local char = pattern_lower:sub(i, i)
        if char == "." then
            if current_part ~= "" then
                table.insert(parts, current_part)
                current_part = ""
            end
            table.insert(parts, ".")
        else
            current_part = current_part .. char
        end
    end
    if current_part ~= "" then
        table.insert(parts, current_part)
    end
    local search_pos = 1
    local total_score = 0
    for _, part in ipairs(parts) do
        local match_pos = text_lower:find(part, search_pos, true)
        if match_pos then
            total_score = total_score + 8000
            search_pos = match_pos + #part
        else
            return 0
        end
    end
    return total_score
end

local function calculate_fuzzy_char_score(text_lower, pattern_lower)
    local text_idx, pattern_idx, match_count = 1, 1, 0
    local consecutive_matches = 0
    local max_consecutive = 0
    local first_match_pos = nil
    while text_idx <= #text_lower and pattern_idx <= #pattern_lower do
        if text_lower:sub(text_idx, text_idx) == pattern_lower:sub(pattern_idx, pattern_idx) then
            if not first_match_pos then
                first_match_pos = text_idx
            end
            match_count = match_count + 1
            consecutive_matches = consecutive_matches + 1
            max_consecutive = math.max(max_consecutive, consecutive_matches)
            pattern_idx = pattern_idx + 1
        else
            consecutive_matches = 0
        end
        text_idx = text_idx + 1
    end
    if match_count == #pattern_lower then
        local score = 1000 + (max_consecutive * 200) + match_count
        if first_match_pos and first_match_pos <= 3 then
            score = score + 500
        end
        score = score + (100 - math.min(#text_lower, 100))
        return score
    end
    return 0
end

local function has_valid_matches(text, pattern)
    if not text or not pattern or pattern == "" then
        return false
    end
    local match_positions = find_all_match_positions(text, pattern)
    return #match_positions > 0
end

local function calculate_fuzzy_score(text, pattern)
    if not text or not pattern then
        return 0
    end
    if #pattern == 0 then
        return 1.0
    end
    if #text == 0 then
        return 0
    end
    local text_lower = text:lower()
    local pattern_lower = pattern:lower()
    if text_lower == pattern_lower then
        return 100000
    end
    local exact_pos = text_lower:find(pattern_lower, 1, true)
    if exact_pos then
        local score = 50000
        if exact_pos == 1 then
            score = score + 20000
        end
        score = score + (10000 - math.min(#text, 10000))
        return score
    end
    if pattern:find("%.") then
        local sequential_score = check_sequential_match(text_lower, pattern_lower)
        if sequential_score > 0 then
            return sequential_score
        end
    end
    local fuzzy_score = calculate_fuzzy_char_score(text_lower, pattern_lower)
    if fuzzy_score > 0 then
        return fuzzy_score
    end
    if pattern:find("%.") then
        local segment_score = 0
        local segments_found = 0
        local total_segments = 0
        for segment in pattern:gmatch("[^%.]+") do
            if segment ~= "" and #segment >= 3 then
                total_segments = total_segments + 1
                local seg_pos = text_lower:find(segment:lower(), 1, true)
                if seg_pos then
                    segments_found = segments_found + 1
                    segment_score = segment_score + 3000
                    if seg_pos == 1 then
                        segment_score = segment_score + 1000
                    end
                end
            end
        end
        if segments_found > 0 and segments_found == total_segments then
            return segment_score
        end
    end
    return 0
end

local function relpath_to_project(file_path, project_root_arg)
    if not file_path or file_path == "" then
        return ""
    end
    if not project_root_arg or project_root_arg == "" then
        return vim.fn.fnamemodify(file_path, ":t")
    end
    local abs_file = vim.fn.fnamemodify(file_path, ":p")
    local project_root_abs = vim.fn.fnamemodify(project_root_arg, ":p")
    local sep = vim.fn.has("win32") == 1 and "\\" or "/"
    if vim.fn.isdirectory(project_root_abs) == 1 and not project_root_abs:match("[" .. sep .. "]$") then
        project_root_abs = project_root_abs .. sep
    end
    if vim.startswith(abs_file, project_root_abs) then
        local rel = abs_file:sub(#project_root_abs + 1)
        if rel == "" then
            return vim.fn.fnamemodify(file_path, ":t")
        end
        return rel
    else
        return vim.fn.fnamemodify(file_path, ":t")
    end
end

local function call_fzf_search(project_path, query)
    if not project_path then
        return nil
    end
    local fd_cmd = config.search
    local fzf_bin = "fzf"
    local find_cmd_str = string.format("cd %s && %s", vim.fn.shellescape(project_path), fd_cmd)
    local fzf_full_cmd = (query and query ~= "")
            and string.format("%s | %s --filter %s", find_cmd_str, fzf_bin, vim.fn.shellescape(query))
        or string.format("%s | %s --filter ''", find_cmd_str, fzf_bin)
    local ok, result = pcall(function()
        local handle = io.popen(fzf_full_cmd)
        if not handle then
            return nil
        end
        local result_str = handle:read("*a")
        handle:close()
        if not result_str or result_str == "" then
            return { files = {}, count = 0 }
        end
        local files_tbl = {}
        for line_str in result_str:gmatch("[^\r\n]+") do
            line_str = vim.trim(line_str)
            if line_str ~= "" then
                local current_full_path = line_str
                if
                    not vim.startswith(current_full_path, "/")
                    and not vim.startswith(current_full_path, "~")
                    and (vim.fn.has("win32") ~= 1 or not current_full_path:match("^[a-zA-Z]:"))
                then
                    current_full_path = project_path
                        .. (project_path:match("[/\\]$") and "" or (vim.fn.has("win32") == 1 and "\\" or "/"))
                        .. current_full_path
                end
                current_full_path = vim.fn.fnamemodify(current_full_path, ":p")
                local name_str = vim.fn.fnamemodify(current_full_path, ":t")
                local rel_path_str = relpath_to_project(current_full_path, project_path)
                local score_val = calculate_fuzzy_score(rel_path_str, query)
                    + calculate_fuzzy_score(name_str, query) * 0.5

                table.insert(files_tbl, {
                    path = current_full_path,
                    relative_path = rel_path_str,
                    name = name_str,
                    score = score_val,
                })
            end
        end
        if query and query ~= "" then
            table.sort(files_tbl, function(a, b)
                return a.score > b.score
            end)
        end
        return { files = files_tbl, count = #files_tbl }
    end)
    if ok then
        return result
    else
        return nil
    end
end

local function get_project_path_abs()
    if not state.project_id then
        return nil
    end
    local proj_data = data.find_project_by_id(state.project_id)
    return proj_data and proj_data.path and vim.fn.fnamemodify(proj_data.path, ":p") or nil
end

local function load_all_files()
    if #cache.all_files > 0 and cache.current_query == "" then
        return
    end
    local current_project_path = get_project_path_abs()
    if not current_project_path then
        cache.all_files = {}
        return
    end
    cache.all_files = {}
    local search_results_data = call_fzf_search(current_project_path, "")
    if search_results_data and search_results_data.files then
        for _, file_item in ipairs(search_results_data.files) do
            local abs_p = vim.fn.fnamemodify(file_item.path, ":p")
            table.insert(cache.all_files, {
                id = abs_p,
                path = abs_p,
                relative_path = file_item.relative_path or relpath_to_project(abs_p, current_project_path),
                name = file_item.name or vim.fn.fnamemodify(abs_p, ":t"),
                score = file_item.score or 1.0,
            })
        end
    end
end

local function filter_files(query_str)
    query_str = query_str or ""
    cache.current_query = query_str
    cache.search_results = {}
    if query_str == "" then
        for _, file_data in ipairs(cache.all_files) do
            local result_item = vim.deepcopy(file_data)
            result_item.relative_path_display = result_item.relative_path
            table.insert(cache.search_results, result_item)
        end
        table.sort(cache.search_results, function(a, b)
            return (a.relative_path_display or "") < (b.relative_path_display or "")
        end)
    else
        for _, file_data in ipairs(cache.all_files) do
            local rel_path_disp_str = file_data.relative_path or ""
            local name_str = file_data.name or ""
            local has_path_match = has_valid_matches(rel_path_disp_str, query_str)
            local has_name_match = has_valid_matches(name_str, query_str)

            if has_path_match or has_name_match then
                local path_score = calculate_fuzzy_score(rel_path_disp_str, query_str)
                local name_score = calculate_fuzzy_score(name_str, query_str)
                local total_score = path_score + (name_score * 2)

                if total_score > 0 then
                    local result_item = vim.deepcopy(file_data)
                    result_item.score = total_score
                    result_item.relative_path_display = rel_path_disp_str
                    table.insert(cache.search_results, result_item)
                end
            end
        end
        table.sort(cache.search_results, function(a, b)
            return a.score > b.score
        end)
    end
end

local function live_fzf_search(query_term)
    if not query_term or query_term == "" then
        filter_files("")
        return
    end
    local proj_path_val = get_project_path_abs()
    if not proj_path_val then
        filter_files(query_term)
        return
    end
    local fzf_output = call_fzf_search(proj_path_val, query_term)
    if fzf_output and fzf_output.files and #fzf_output.files > 0 then
        cache.search_results = {}
        cache.current_query = query_term
        for _, item_info in ipairs(fzf_output.files) do
            local abs_p = vim.fn.fnamemodify(item_info.path, ":p")
            local rel_path = item_info.relative_path

            if has_valid_matches(rel_path, query_term) or has_valid_matches(item_info.name, query_term) then
                table.insert(cache.search_results, {
                    id = abs_p,
                    path = abs_p,
                    relative_path_display = rel_path,
                    name = item_info.name,
                    score = item_info.score,
                })
            end
        end
    else
        filter_files(query_term)
    end
end

local function set_cursor_to_first_line()
    if cache.ctx and cache.ctx.win and vim.api.nvim_win_is_valid(cache.ctx.win) then
        vim.schedule(function()
            if cache.ctx and cache.ctx.win and vim.api.nvim_win_is_valid(cache.ctx.win) then
                pcall(vim.api.nvim_win_set_cursor, cache.ctx.win, { 1, 0 })
            end
        end)
    end
end

local function update_search_display()
    if not cache.ctx or not cache.ctx.buf or not vim.api.nvim_buf_is_valid(cache.ctx.buf) then
        return
    end
    local lines_to_display = {}
    cache.file_ids_map = {}
    local function is_buffer_active(file_path_to_check)
        local current_b = vim.api.nvim_get_current_buf()
        if not vim.api.nvim_buf_is_valid(current_b) then
            return false
        end
        local buffer_name = vim.api.nvim_buf_get_name(current_b)
        return buffer_name ~= ""
            and vim.fn.fnamemodify(buffer_name, ":p") == vim.fn.fnamemodify(file_path_to_check, ":p")
    end
    local is_results_empty = (#cache.search_results == 0)
    if is_results_empty then
        table.insert(
            lines_to_display,
            (common.get_entity_icon("search", false, true))
                .. (state.lang.SEARCH_EMPTY or "No files found matching your search criteria.")
        )
    else
        for i, entity_item in ipairs(cache.search_results) do
            local is_item_active = is_buffer_active(entity_item.path)
            local item_icon = common.get_entity_icon("file", is_item_active, false)
            local display_path_text = entity_item.relative_path_display
                or relpath_to_project(entity_item.path, get_project_path_abs())
            table.insert(lines_to_display, item_icon .. display_path_text)
            cache.file_ids_map[i] = entity_item.id
        end
    end
    vim.bo[cache.ctx.buf].modifiable = true
    vim.api.nvim_buf_set_lines(cache.ctx.buf, 0, -1, false, lines_to_display)
    vim.bo[cache.ctx.buf].modifiable = false
    set_cursor_to_first_line()
    local ns_id = vim.api.nvim_create_namespace("lvim_search_highlights")
    vim.api.nvim_buf_clear_namespace(cache.ctx.buf, ns_id, 0, -1)
    if cache.current_query and cache.current_query ~= "" and not is_results_empty then
        for line_idx, entity_item in ipairs(cache.search_results) do
            local display_text = entity_item.relative_path_display or ""
            local icon_len = #common.get_entity_icon("file", is_buffer_active(entity_item.path), false)
            local match_positions = find_all_match_positions(display_text, cache.current_query)
            for _, pos in ipairs(match_positions) do
                local start_col = pos.start + icon_len
                local end_col = start_col + pos.length
                local hl_group
                if pos.priority and pos.priority >= 100 then
                    hl_group = "LvimSpaceFuzzyPrimary"
                elseif pos.priority and pos.priority >= 80 then
                    hl_group = "LvimSpaceFuzzySecondary"
                else
                    hl_group = "LvimSpaceFuzzySecondary"
                end
                pcall(vim.api.nvim_buf_set_extmark, cache.ctx.buf, ns_id, line_idx - 1, start_col, {
                    end_col = end_col,
                    hl_group = hl_group,
                })
            end
        end
    end
    if cache.ctx.win and vim.api.nvim_win_is_valid(cache.ctx.win) then
        local win_current_config = vim.api.nvim_win_get_config(cache.ctx.win)
        local config_changes = {}
        local num_display_lines = #lines_to_display == 0 and 1 or #lines_to_display
        local search_panel_config = (config.ui and config.ui.panels and config.ui.panels.search) or {}
        local panel_max_height = search_panel_config.max_height or config.max_height or 10
        local calculated_new_height = math.min(math.max(num_display_lines, 1), panel_max_height)
        if win_current_config.height ~= calculated_new_height then
            config_changes.height = calculated_new_height
            local bottom_elements_total_height = 2
            config_changes.row = vim.o.lines - calculated_new_height - bottom_elements_total_height
        end
        local query_display_str = cache.current_query == "" and (state.lang.SEARCH_ALL_FILES_LABEL or "all")
            or "'" .. cache.current_query .. "'"
        local new_title_str =
            string.format("%s (%d - %s)", state.lang.SEARCH or "Search", #cache.search_results, query_display_str)
        local formatted_win_title = " " .. new_title_str .. " "
        if win_current_config.title ~= formatted_win_title then
            config_changes.title = formatted_win_title
        end
        if not vim.tbl_isempty(config_changes) then
            local final_win_config = vim.tbl_extend("force", win_current_config, config_changes)
            pcall(vim.api.nvim_win_set_config, cache.ctx.win, final_win_config)
        end
    end
    local action_bar_info = string.format(
        (
            state.lang.INFO_LINE_SEARCH
            or "➤ [j] [k] | [/] or [s] search | 󱁐 file load 󰌑 file enter | [v]split [h]split | [p]rojects [w]orkspaces [t]abs [f]iles"
        ),
        cache.current_query == "" and (state.lang.SEARCH_ALL_FILES_LABEL or "all") or cache.current_query,
        #cache.search_results
    )
    ui.open_actions(action_bar_info)
end

local function show_search_input()
    local input_prompt = (state.lang.SEARCH_PROMPT or "Search files:") .. " "
    local search_input_buf, search_input_win = ui.create_input_field(
        input_prompt,
        cache.current_query,
        function(query_final_val)
            if query_final_val == nil then
                if cache.ctx and cache.ctx.win and vim.api.nvim_win_is_valid(cache.ctx.win) then
                    vim.api.nvim_set_current_win(cache.ctx.win)
                    vim.cmd("hi Cursor blend=100")
                else
                    local target_focus_win = get_last_normal_win()
                    if target_focus_win and vim.api.nvim_win_is_valid(target_focus_win) then
                        vim.api.nvim_set_current_win(target_focus_win)
                        vim.cmd("hi Cursor blend=100")
                    end
                end
            else
                cache.current_query = query_final_val or ""
                live_fzf_search(cache.current_query)
                update_search_display()
                if cache.ctx and cache.ctx.win and vim.api.nvim_win_is_valid(cache.ctx.win) then
                    vim.api.nvim_set_current_win(cache.ctx.win)
                    vim.cmd("hi Cursor blend=100")
                end
            end
        end,
        { input_filetype = "lvim-space-search-input" }
    )
    if not search_input_buf or not search_input_win then
        return
    end
    local live_update_timer, live_augroup =
        nil, vim.api.nvim_create_augroup("LvimSpaceSearchInputLiveUpdate", { clear = true })
    local function cleanup_live_timer()
        if live_update_timer then
            pcall(function()
                if live_update_timer.close then
                    live_update_timer:close()
                end
            end)
            live_update_timer = nil
        end
    end
    vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
        buffer = search_input_buf,
        group = live_augroup,
        callback = vim.schedule_wrap(function()
            if not vim.api.nvim_buf_is_valid(search_input_buf) then
                cleanup_live_timer()
                return
            end
            local current_input_text = vim.api.nvim_buf_get_lines(search_input_buf, 0, 1, false)[1] or ""
            cleanup_live_timer()
            live_update_timer = vim.defer_fn(function()
                if current_input_text ~= cache.current_query then
                    live_fzf_search(current_input_text)
                    update_search_display()
                end
            end, 80)
        end),
    })
    vim.api.nvim_create_autocmd("BufWipeout", {
        buffer = search_input_buf,
        group = live_augroup,
        callback = function()
            cleanup_live_timer()
            vim.api.nvim_del_augroup_by_id(live_augroup)
        end,
        once = true,
    })
end

local function _can_perform_file_operation()
    if not state.project_id then
        notify.error(state.lang.PROJECT_NOT_ACTIVE or "No active project")
        return false
    end
    if not state.workspace_id then
        notify.error(state.lang.WORKSPACE_NOT_ACTIVE or "No active workspace")
        return false
    end
    if not state.tab_active then
        notify.error(state.lang.TAB_NOT_ACTIVE or "No active tab")
        return false
    end
    return true
end

local function _open_file_in_editor_window(file_path_to_open)
    if not _can_perform_file_operation() then
        return false
    end
    if not file_path_to_open or vim.trim(file_path_to_open) == "" then
        notify.error(state.lang.FILE_PATH_NOT_FOUND or "Cannot find path for selected file")
        return false
    end
    if vim.fn.filereadable(file_path_to_open) ~= 1 then
        notify.error(state.lang.FILE_NOT_READABLE or "File is not readable")
        return false
    end
    local buffer_num = vim.fn.bufadd(file_path_to_open)
    vim.fn.bufload(buffer_num)
    local target_editor_window = last_real_win
    if
        not target_editor_window
        or not vim.api.nvim_win_is_valid(target_editor_window)
        or is_plugin_panel_win(target_editor_window)
    then
        target_editor_window = get_last_normal_win()
    end
    if target_editor_window and vim.api.nvim_win_is_valid(target_editor_window) then
        vim.api.nvim_win_set_buf(target_editor_window, buffer_num)
        last_real_win = target_editor_window
    else
        vim.cmd("edit " .. vim.fn.fnameescape(file_path_to_open))
        last_real_win = vim.api.nvim_get_current_win()
    end
    notify.info(state.lang.SEARCH_FILE_OPENED or "File opened successfully.")
    return true
end

function M.handle_file_switch(opts)
    opts = opts or {}
    if not _can_perform_file_operation() then
        return
    end
    local selected_file_id = common.get_id_at_cursor(cache.file_ids_map)
    if not selected_file_id then
        return
    end
    local file_opened_ok = _open_file_in_editor_window(selected_file_id)
    if not file_opened_ok then
        notify.error(state.lang.SEARCH_FILE_OPEN_FAILED or "Failed to open selected file.")
        return
    end
    if opts.close_panel then
        local editor_win_to_return_focus = last_real_win
        ui.close_all()
        if editor_win_to_return_focus and vim.api.nvim_win_is_valid(editor_win_to_return_focus) then
            pcall(vim.api.nvim_set_current_win, editor_win_to_return_focus)
            vim.cmd("hi Cursor blend=100")
        else
            vim.cmd("hi Cursor blend=100")
        end
    else
        update_search_display()
    end
end

local function _split_file_common(split_cmd)
    if not _can_perform_file_operation() then
        return
    end
    local file_id_to_split = common.get_id_at_cursor(cache.file_ids_map)
    if not file_id_to_split or vim.trim(file_id_to_split) == "" then
        notify.error(state.lang.FILE_PATH_NOT_FOUND or "Cannot find path for selected file")
        return
    end
    if vim.fn.filereadable(file_id_to_split) ~= 1 then
        notify.error(state.lang.FILE_NOT_READABLE or "File is not readable")
        return
    end
    local previous_editor_win = last_real_win
    ui.close_all()
    local success_split, _ = pcall(function()
        if previous_editor_win and vim.api.nvim_win_is_valid(previous_editor_win) then
            vim.api.nvim_set_current_win(previous_editor_win)
        end
        vim.cmd(split_cmd .. " " .. vim.fn.fnameescape(file_id_to_split))
        last_real_win = vim.api.nvim_get_current_win()
        vim.cmd("hi Cursor blend=100")
    end)
    local notify_success, notify_fail
    if split_cmd == "vsplit" then
        notify_success = state.lang.FILE_OPENED_VERTICAL or "File opened in vertical split"
        notify_fail = state.lang.FILE_OPEN_VERTICAL_FAILED or "Failed to open file in vertical split"
    else
        notify_success = state.lang.FILE_OPENED_HORIZONTAL or "File opened in horizontal split"
        notify_fail = state.lang.FILE_OPEN_HORIZONTAL_FAILED or "Failed to open file in horizontal split"
    end
    if success_split then
        notify.info(notify_success)
    else
        notify.error(notify_fail)
    end
end

function M.handle_split_vertical()
    _split_file_common("vsplit")
end

function M.handle_split_horizontal()
    _split_file_common("split")
end

function M.navigate_to_projects()
    ui.close_all()
    require("lvim-space.ui.projects").init()
end

function M.navigate_to_workspaces()
    if not state.project_id then
        notify.info(state.lang.PROJECT_NOT_ACTIVE or "No active project")
        return
    end
    ui.close_all()
    require("lvim-space.ui.workspaces").init()
end

function M.navigate_to_tabs()
    if not state.project_id then
        notify.info(state.lang.PROJECT_NOT_ACTIVE or "No active project")
        return
    end
    if not state.workspace_id then
        notify.info(state.lang.WORKSPACE_NOT_ACTIVE or "No active workspace")
        return
    end
    ui.close_all()
    require("lvim-space.ui.tabs").init()
end

function M.navigate_to_files()
    if not state.project_id then
        notify.info(state.lang.PROJECT_NOT_ACTIVE or "No active project")
        return
    end
    if not state.workspace_id then
        notify.info(state.lang.WORKSPACE_NOT_ACTIVE or "No active workspace")
        return
    end
    if not state.tab_active then
        notify.info(state.lang.TAB_NOT_ACTIVE or "No active tab")
        return
    end
    ui.close_all()
    require("lvim-space.ui.files").init()
end

local function setup_keymaps(context_arg)
    local keymap_options = { buffer = context_arg.buf, noremap = true, silent = true, nowait = true }
    vim.keymap.set("n", config.keymappings.action.switch, function()
        M.handle_file_switch({ close_panel = false })
    end, keymap_options)
    vim.keymap.set("n", config.keymappings.action.enter, function()
        M.handle_file_switch({ close_panel = true })
    end, keymap_options)
    vim.keymap.set("n", config.keymappings.action.split_v, function()
        M.handle_split_vertical()
    end, keymap_options)
    vim.keymap.set("n", config.keymappings.action.split_h, function()
        M.handle_split_horizontal()
    end, keymap_options)
    vim.keymap.set("n", config.keymappings.global.search, function()
        show_search_input()
    end, keymap_options)
    vim.keymap.set("n", config.keymappings.global.projects, function()
        M.navigate_to_projects()
    end, keymap_options)
    vim.keymap.set("n", config.keymappings.global.workspaces, function()
        M.navigate_to_workspaces()
    end, keymap_options)
    vim.keymap.set("n", config.keymappings.global.tabs, function()
        M.navigate_to_tabs()
    end, keymap_options)
    vim.keymap.set("n", config.keymappings.global.files, function()
        M.navigate_to_files()
    end, keymap_options)
end

M.init = function(initial_selected_line_num)
    if not state.project_id then
        notify.error(state.lang.PROJECT_NOT_ACTIVE or "No active project")
        common.open_entity_error("search", "PROJECT_NOT_ACTIVE")
        common.setup_error_navigation("PROJECT_NOT_ACTIVE", last_real_win)
        return
    end
    if not state.workspace_id then
        notify.error(state.lang.WORKSPACE_NOT_ACTIVE or "No active workspace")
        common.open_entity_error("search", "WORKSPACE_NOT_ACTIVE")
        common.setup_error_navigation("WORKSPACE_NOT_ACTIVE", last_real_win)
        return
    end
    if not state.tab_active then
        notify.error(state.lang.TAB_NOT_ACTIVE or "No active tab")
        common.open_entity_error("search", "TAB_NOT_ACTIVE")
        common.setup_error_navigation("TAB_NOT_ACTIVE", last_real_win)
        return
    end
    if not last_real_win or not vim.api.nvim_win_is_valid(last_real_win) or is_plugin_panel_win(last_real_win) then
        last_real_win = get_last_normal_win()
    end
    load_all_files()
    filter_files(cache.current_query)
    cache.file_ids_map = {}
    local function search_results_formatter(search_entry_item)
        if not search_entry_item or not search_entry_item.path then
            return "Error: Invalid search entry"
        end
        return search_entry_item.relative_path_display
            or relpath_to_project(search_entry_item.path, get_project_path_abs())
    end
    local function is_search_item_active_custom_fn(entity_item_to_check)
        if not entity_item_to_check or not entity_item_to_check.path then
            return false
        end
        local current_buf_handle = vim.api.nvim_get_current_buf()
        if not vim.api.nvim_buf_is_valid(current_buf_handle) then
            return false
        end
        local current_buf_name = vim.api.nvim_buf_get_name(current_buf_handle)
        return current_buf_name ~= ""
            and vim.fn.fnamemodify(current_buf_name, ":p") == vim.fn.fnamemodify(entity_item_to_check.path, ":p")
    end
    local panel_context = common.init_entity_list(
        "search",
        cache.search_results,
        cache.file_ids_map,
        M.init,
        nil,
        "id",
        initial_selected_line_num or 1,
        search_results_formatter,
        is_search_item_active_custom_fn
    )
    if not panel_context then
        return
    end
    cache.ctx = panel_context
    update_search_display()
    setup_keymaps(panel_context)
end

return M
