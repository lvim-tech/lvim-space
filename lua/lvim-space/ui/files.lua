local config = require("lvim-space.config")
local notify = require("lvim-space.api.notify")
local state = require("lvim-space.api.state")
local data = require("lvim-space.api.data")
local ui = require("lvim-space.ui")
local common = require("lvim-space.ui.common")
local session = require("lvim-space.core.session")

local M = {}

local cache = {
    file_ids_map = {},
    files_from_db = {},
    ctx = nil,
    tab_display_name = "",
    validation_cache = {},
    last_cursor_position = 1,
}

local is_empty = false
local last_normal_win = nil
local last_real_win = nil

local is_plugin_panel_win = ui.is_plugin_window

local function save_window_context()
    local current_win = vim.api.nvim_get_current_win()
    if current_win and vim.api.nvim_win_is_valid(current_win) and not is_plugin_panel_win(current_win) then
        last_real_win = current_win
    end
end

local function get_last_normal_win()
    if last_real_win and vim.api.nvim_win_is_valid(last_real_win) and not is_plugin_panel_win(last_real_win) then
        return last_real_win
    end
    local current_win = vim.api.nvim_get_current_win()
    local wins = vim.api.nvim_tabpage_list_wins(0)
    for _, win in ipairs(wins) do
        local cfg = vim.api.nvim_win_get_config(win)
        if cfg.relative == "" and not is_plugin_panel_win(win) then
            if win == current_win then
                return win
            end
        end
    end
    for _, win in ipairs(wins) do
        local cfg = vim.api.nvim_win_get_config(win)
        if cfg.relative == "" and not is_plugin_panel_win(win) then
            return win
        end
    end
    return current_win
end

local function get_current_buffer_info()
    local current_buf = vim.api.nvim_get_current_buf()
    local current_buf_name = vim.api.nvim_buf_get_name(current_buf)
    return {
        bufnr = current_buf,
        name = current_buf_name ~= "" and vim.fn.fnamemodify(current_buf_name, ":p") or nil,
        is_valid = vim.api.nvim_buf_is_valid(current_buf),
    }
end

local function get_file_by_id(file_id, files_list)
    for _, file_entry in ipairs(files_list) do
        local candidate_id = file_entry.id or file_entry.bufnr
        if tostring(candidate_id) == tostring(file_id) then
            return file_entry
        end
    end
    return nil
end

local function relpath_to_project(file_path)
    local project = data.find_project_by_id(state.project_id)
    if not project or not project.path then
        return vim.fn.fnamemodify(file_path, ":~:.")
    end
    local abs_proj = vim.fn.fnamemodify(project.path, ":p")
    local abs_file = vim.fn.fnamemodify(file_path, ":p")
    if vim.startswith(abs_file, abs_proj) then
        local rel = abs_file:sub(#abs_proj + 1)
        if rel == "" then
            rel = "."
        elseif vim.startswith(rel, "/") then
            rel = rel:sub(2)
        end
        return rel
    end
    return vim.fn.fnamemodify(file_path, ":~:.")
end

local function validate_file_path(file_path)
    if not file_path or vim.trim(file_path) == "" then
        return nil, "LEN_NAME"
    end
    local cache_key = file_path
    if cache.validation_cache[cache_key] then
        return cache.validation_cache[cache_key].path, cache.validation_cache[cache_key].error
    end
    local normalized_path = vim.fn.expand(vim.trim(file_path))
    normalized_path = vim.fn.fnamemodify(normalized_path, ":p")
    local dir = vim.fn.fnamemodify(normalized_path, ":h")
    local error_code = nil
    if vim.fn.isdirectory(normalized_path) == 1 then
        error_code = "DIR_ADD_NOT_ALLOWED"
    elseif vim.fn.isdirectory(dir) ~= 1 and vim.fn.filereadable(normalized_path) ~= 1 then
        error_code = "INVALID_DIR"
    end
    cache.validation_cache[cache_key] = {
        path = error_code and nil or normalized_path,
        error = error_code,
    }
    return cache.validation_cache[cache_key].path, cache.validation_cache[cache_key].error
end

local function get_tab_data(tab_id, workspace_id)
    local tab = data.find_tab_by_id(tab_id, workspace_id)
    if not tab or not tab.data then
        return nil
    end
    local success, tab_data_decoded = pcall(vim.fn.json_decode, tab.data)
    if not success or not tab_data_decoded then
        return nil
    end
    tab_data_decoded.buffers = tab_data_decoded.buffers or {}
    return tab_data_decoded
end

local function update_tab_data_in_db(tab_id, workspace_id, tab_data_obj)
    local updated_data_json = vim.fn.json_encode(tab_data_obj)
    local success = data.update_tab_data(tab_id, updated_data_json, workspace_id)
    if not success then
        return false
    end
    return true
end

local function update_files_state_in_db()
    if not config.autosave or not state.tab_active or not state.workspace_id then
        return
    end
    local tab_data_obj = get_tab_data(state.tab_active, state.workspace_id)
    if tab_data_obj then
        update_tab_data_in_db(state.tab_active, state.workspace_id, tab_data_obj)
    end
end

local function add_file_db(file_path, workspace_id, tab_id)
    local validated_path, error_code = validate_file_path(file_path)
    if not validated_path then
        return error_code
    end
    local tab_data_obj = get_tab_data(tab_id, workspace_id)
    if not tab_data_obj then
        return "ADD_FAILED"
    end
    for _, buf_entry in ipairs(tab_data_obj.buffers) do
        local candidate_path = buf_entry.path or buf_entry.filePath
        if candidate_path and vim.fn.fnamemodify(candidate_path, ":p") == vim.fn.fnamemodify(validated_path, ":p") then
            return "EXIST_NAME"
        end
    end
    local new_bufnr = vim.fn.bufadd(validated_path)
    vim.bo[new_bufnr].buflisted = true
    local new_buffer_entry = {
        filePath = validated_path,
        bufnr = new_bufnr,
        filetype = vim.bo[new_bufnr].filetype or vim.fn.getbufvar(new_bufnr, "&filetype") or "",
        added_at = os.time(),
    }
    table.insert(tab_data_obj.buffers, new_buffer_entry)
    if update_tab_data_in_db(tab_id, workspace_id, tab_data_obj) then
        cache.validation_cache = {}
        return new_bufnr
    else
        return "ADD_FAILED"
    end
end

local function delete_file_db(file_id_to_delete, workspace_id, tab_id)
    local tab_data_obj = get_tab_data(tab_id, workspace_id)
    if not tab_data_obj then
        return nil
    end
    local index_to_remove, file_to_remove_entry = nil, nil
    for i, buf_entry in ipairs(tab_data_obj.buffers) do
        local candidate_path = buf_entry.filePath or buf_entry.path
        if candidate_path and tostring(candidate_path) == tostring(file_id_to_delete) then
            index_to_remove = i
            file_to_remove_entry = buf_entry
            break
        end
    end
    if not index_to_remove or not file_to_remove_entry then
        return nil
    end
    local bufnr_of_deleted_file = file_to_remove_entry.bufnr
    table.remove(tab_data_obj.buffers, index_to_remove)
    if update_tab_data_in_db(tab_id, workspace_id, tab_data_obj) then
        vim.schedule(function()
            local windows_with_buffer = {}
            if bufnr_of_deleted_file and vim.api.nvim_buf_is_valid(bufnr_of_deleted_file) then
                for _, win in ipairs(vim.api.nvim_list_wins()) do
                    if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == bufnr_of_deleted_file then
                        table.insert(windows_with_buffer, win)
                    end
                end
            end
            if #windows_with_buffer > 0 then
                local new_empty_buf = vim.api.nvim_create_buf(false, true)
                for _, win in ipairs(windows_with_buffer) do
                    if vim.api.nvim_win_is_valid(win) then
                        vim.api.nvim_win_set_buf(win, new_empty_buf)
                    end
                end
                notify.info(state.lang.FILE_REMOVE_REPLACE or "File closed and removed from tab.")
            end
            if bufnr_of_deleted_file and vim.api.nvim_buf_is_valid(bufnr_of_deleted_file) then
                if vim.bo[bufnr_of_deleted_file].modified then
                    vim.ui.input({ prompt = "Buffer has unsaved changes. Save? (y/n): " }, function(input)
                        if input and input:lower() == "y" then
                            pcall(vim.api.nvim_buf_call, bufnr_of_deleted_file, function()
                                vim.cmd("write")
                            end)
                        end
                        pcall(vim.api.nvim_buf_delete, bufnr_of_deleted_file, { force = true })
                    end)
                else
                    pcall(vim.api.nvim_buf_delete, bufnr_of_deleted_file, { force = false })
                end
            end
            if tostring(state.file_active) == tostring(file_id_to_delete) then
                state.file_active = nil
            end
            M.refresh()
        end)
        return true
    else
        return false
    end
end

local function update_tab_display_name()
    cache.tab_display_name = ""
    local current_tab_obj = data.find_tab_by_id(state.tab_active, state.workspace_id)
    if current_tab_obj and current_tab_obj.name then
        cache.tab_display_name = current_tab_obj.name
    end
end

local function save_cursor_position()
    if cache.ctx and cache.ctx.win and vim.api.nvim_win_is_valid(cache.ctx.win) then
        local cursor_pos = vim.api.nvim_win_get_cursor(cache.ctx.win)
        cache.last_cursor_position = cursor_pos[1]
    end
end

local function setup_cursor_tracking(ctx)
    if not ctx.win or not vim.api.nvim_win_is_valid(ctx.win) then
        return
    end

    vim.api.nvim_create_autocmd("CursorMoved", {
        buffer = ctx.buf,
        callback = function()
            if cache.ctx and cache.ctx.win and vim.api.nvim_win_is_valid(cache.ctx.win) then
                local cursor_pos = vim.api.nvim_win_get_cursor(cache.ctx.win)
                cache.last_cursor_position = cursor_pos[1]
            end
        end,
        group = vim.api.nvim_create_augroup("LvimSpaceFilesCursor", { clear = true }),
    })
end

M.refresh = function()
    if not cache.ctx or not cache.ctx.win or not vim.api.nvim_win_is_valid(cache.ctx.win) then
        return M.init()
    end

    if not cache.ctx.buf or not vim.api.nvim_buf_is_valid(cache.ctx.buf) then
        return M.init()
    end

    save_cursor_position()

    cache.files_from_db = data.find_files(state.tab_active, state.workspace_id) or {}
    cache.file_ids_map = {}

    if cache.ctx.is_empty and #cache.files_from_db > 0 then
        return M.init()
    end

    update_tab_display_name()

    local current_buf_info = get_current_buffer_info()

    local new_lines = {}

    for i, file_entry in ipairs(cache.files_from_db) do
        local file_path = file_entry.path or file_entry.filePath or "???"
        local display_text = relpath_to_project(file_path)
        cache.file_ids_map[i] = file_entry.id

        local candidate_path = file_entry.id
        local is_current_buffer_match = current_buf_info.name
            and candidate_path
            and vim.fn.fnamemodify(candidate_path, ":p") == current_buf_info.name
        local is_state_active_match = state.file_active
            and candidate_path
            and vim.fn.fnamemodify(candidate_path, ":p") == vim.fn.fnamemodify(state.file_active, ":p")

        if is_current_buffer_match or (not current_buf_info.name and is_state_active_match) then
            local file_active_icon = (config.ui and config.ui.icons and config.ui.icons.file_active) or " "
            display_text = file_active_icon .. display_text
        else
            local file_icon = (config.ui and config.ui.icons and config.ui.icons.file) or " "
            display_text = file_icon .. display_text
        end

        table.insert(new_lines, display_text)
    end

    local success = pcall(function()
        local was_modifiable = vim.bo[cache.ctx.buf].modifiable
        if not was_modifiable then
            vim.bo[cache.ctx.buf].modifiable = true
        end

        vim.api.nvim_buf_set_lines(cache.ctx.buf, 0, -1, false, new_lines)

        if not was_modifiable then
            vim.bo[cache.ctx.buf].modifiable = false
        end
    end)

    if not success then
        return M.init()
    end

    cache.ctx.is_empty = #new_lines == 0
    cache.ctx.entities = cache.files_from_db

    if #new_lines > 0 and cache.ctx.win and vim.api.nvim_win_is_valid(cache.ctx.win) then
        local max_line = #new_lines
        local target_line = math.min(cache.last_cursor_position, max_line)
        target_line = math.max(target_line, 1)
        pcall(vim.api.nvim_win_set_cursor, cache.ctx.win, { target_line, 0 })
    end

    common.apply_cursor_blending(cache.ctx.win)
end

function M.handle_file_delete()
    if is_empty then
        return
    end
    local file_id_at_cursor = common.get_id_at_cursor(cache.file_ids_map)
    if not file_id_at_cursor then
        return
    end
    local result_delete = delete_file_db(file_id_at_cursor, state.workspace_id, state.tab_active)
    if not result_delete then
        notify.error(state.lang.FILE_DELETE_FAILED or "Failed to delete file from tab.")
    end
end

function M.handle_file_switch(opts)
    opts = opts or {}
    M._switch_file()
    if opts.close_panel then
        if last_real_win and vim.api.nvim_win_is_valid(last_real_win) then
            local stored_win = last_real_win
            ui.close_all()
            if vim.api.nvim_win_is_valid(stored_win) then
                pcall(vim.api.nvim_set_current_win, stored_win)
            end
        else
            ui.close_all()
        end
    end
end

function M.handle_split_vertical()
    if is_empty then
        return
    end
    M._split_file_vertical()
end

function M.handle_split_horizontal()
    if is_empty then
        return
    end
    M._split_file_horizontal()
end

function M.navigate_to_projects()
    ui.close_all()
    require("lvim-space.ui.projects").init()
end

function M.navigate_to_workspaces()
    if not state.project_id then
        notify.info(state.lang.PROJECT_NOT_ACTIVE or "No active project. Please select or add a project first.")
        return
    end
    ui.close_all()
    require("lvim-space.ui.workspaces").init()
end

function M.navigate_to_tabs()
    if not state.project_id then
        notify.info(state.lang.PROJECT_NOT_ACTIVE or "No active project. Please select or add a project first.")
        return
    end
    if not state.workspace_id then
        notify.info(state.lang.WORKSPACE_NOT_ACTIVE or "No active workspace. Please select or add a workspace first.")
        return
    end
    ui.close_all()
    require("lvim-space.ui.tabs").init()
end

function M.navigate_to_search()
    if not state.project_id then
        notify.info(state.lang.PROJECT_NOT_ACTIVE or "No active project. Please select or add a project first.")
        return
    end
    ui.close_all()
    require("lvim-space.ui.search").init()
end

function M._switch_file()
    local file_id_selected = common.get_id_at_cursor(cache.file_ids_map)
    if not file_id_selected then
        return
    end
    local file_path_to_open = file_id_selected
    if not file_path_to_open then
        notify.error(state.lang.FILE_PATH_NOT_FOUND or "File path not found or is invalid.")
        return
    end
    if vim.fn.filereadable(file_path_to_open) ~= 1 then
        notify.error(state.lang.FILE_NOT_READABLE or "File is not readable or does not exist.")
        return
    end

    local bufnr = vim.fn.bufadd(file_path_to_open)
    vim.fn.bufload(bufnr)

    local target_win = last_real_win

    if not target_win or not vim.api.nvim_win_is_valid(target_win) or is_plugin_panel_win(target_win) then
        target_win = get_last_normal_win()
        last_real_win = target_win
    end

    if target_win and vim.api.nvim_win_is_valid(target_win) then
        vim.api.nvim_win_set_buf(target_win, bufnr)
        if session.save_window_context then
            session.save_window_context(state.tab_active)
        end
    else
        vim.cmd("edit " .. vim.fn.fnameescape(file_path_to_open))
    end

    state.file_active = file_path_to_open
    update_files_state_in_db()

    M.refresh()
end

function M._split_file_vertical()
    local file_id_selected = common.get_id_at_cursor(cache.file_ids_map)
    if not file_id_selected then
        return
    end
    local file_path_to_open = file_id_selected
    if not file_path_to_open then
        notify.error(state.lang.FILE_PATH_NOT_FOUND or "File path not found or is invalid.")
        return
    end
    if vim.fn.filereadable(file_path_to_open) ~= 1 then
        notify.error(state.lang.FILE_NOT_READABLE or "File is not readable or does not exist.")
        return
    end
    ui.close_all()
    local success, _ = pcall(function()
        vim.cmd("vsplit " .. vim.fn.fnameescape(file_path_to_open))
        last_real_win = vim.api.nvim_get_current_win()
    end)
    if success then
        notify.info(state.lang.FILE_OPENED_VERTICAL or "File opened in a new vertical split.")
    else
        notify.error(state.lang.FILE_OPEN_VERTICAL_FAILED or "Failed to open file in a vertical split.")
    end
end

function M._split_file_horizontal()
    local file_id_selected = common.get_id_at_cursor(cache.file_ids_map)
    if not file_id_selected then
        return
    end
    local file_path_to_open = file_id_selected
    if not file_path_to_open then
        notify.error(state.lang.FILE_PATH_NOT_FOUND or "File path not found or is invalid.")
        return
    end
    if vim.fn.filereadable(file_path_to_open) ~= 1 then
        notify.error(state.lang.FILE_NOT_READABLE or "File is not readable or does not exist.")
        return
    end
    ui.close_all()
    local success, _ = pcall(function()
        vim.cmd("split " .. vim.fn.fnameescape(file_path_to_open))
        last_real_win = vim.api.nvim_get_current_win()
    end)
    if success then
        notify.info(state.lang.FILE_OPENED_HORIZONTAL or "File opened in a new horizontal split.")
    else
        notify.error(state.lang.FILE_OPEN_HORIZONTAL_FAILED or "Failed to open file in a horizontal split.")
    end
end

local function setup_keymaps(ctx)
    local keymap_opts = { buffer = ctx.buf, noremap = true, silent = true, nowait = true }
    vim.keymap.set("n", config.keymappings.action.add, function()
        M.add_file()
    end, keymap_opts)
    vim.keymap.set("n", config.keymappings.action.delete, function()
        if next(ctx.entities) ~= nil then
            M.handle_file_delete()
        end
    end, keymap_opts)
    vim.keymap.set("n", config.keymappings.action.switch, function()
        if next(ctx.entities) ~= nil then
            M.handle_file_switch({ close_panel = false })
        end
    end, keymap_opts)
    vim.keymap.set("n", config.keymappings.action.enter, function()
        if next(ctx.entities) ~= nil then
            M.handle_file_switch({ close_panel = true })
        end
    end, keymap_opts)
    vim.keymap.set("n", config.keymappings.action.split_v, function()
        if next(ctx.entities) ~= nil then
            M.handle_split_vertical()
        end
    end, keymap_opts)
    vim.keymap.set("n", config.keymappings.action.split_h, function()
        if next(ctx.entities) ~= nil then
            M.handle_split_horizontal()
        end
    end, keymap_opts)
    vim.keymap.set("n", config.keymappings.global.projects, function()
        M.navigate_to_projects()
    end, keymap_opts)
    vim.keymap.set("n", config.keymappings.global.workspaces, function()
        M.navigate_to_workspaces()
    end, keymap_opts)
    vim.keymap.set("n", config.keymappings.global.tabs, function()
        M.navigate_to_tabs()
    end, keymap_opts)
    vim.keymap.set("n", config.keymappings.global.search, function()
        M.navigate_to_search()
    end, keymap_opts)
end

M.init = function(selected_line_num)
    save_window_context()

    if not state.project_id then
        notify.error(state.lang.PROJECT_NOT_ACTIVE or "No active project. Please select or add a project first.")
        common.open_entity_error("file", "PROJECT_NOT_ACTIVE")
        common.setup_error_navigation("PROJECT_NOT_ACTIVE", last_real_win)
        return
    end
    if not state.workspace_id then
        notify.error(state.lang.WORKSPACE_NOT_ACTIVE or "No active workspace. Please select or add a workspace first.")
        common.open_entity_error("file", "WORKSPACE_NOT_ACTIVE")
        common.setup_error_navigation("WORKSPACE_NOT_ACTIVE", last_real_win)
        return
    end
    if not state.tab_active then
        notify.error(state.lang.TAB_NOT_ACTIVE or "No active tab. Please select or create a tab first.")
        common.open_entity_error("file", "TAB_NOT_ACTIVE")
        common.setup_error_navigation("TAB_NOT_ACTIVE", last_real_win)
        return
    end

    local restored_win = session.restore_window_context and session.restore_window_context(state.tab_active)
    if restored_win then
        last_real_win = restored_win
    end

    if
        not last_normal_win
        or not vim.api.nvim_win_is_valid(last_normal_win)
        or is_plugin_panel_win(last_normal_win)
    then
        last_normal_win = get_last_normal_win()
    end

    if session.save_window_context then
        session.save_window_context(state.tab_active)
    end

    session.save_current_state(state.tab_active, true)
    cache.files_from_db = data.find_files(state.tab_active, state.workspace_id) or {}
    cache.file_ids_map = {}
    local current_buf_info_init = get_current_buffer_info()
    update_tab_display_name()
    local panel_title = cache.tab_display_name ~= ""
            and string.format("%s (%s)", state.lang.FILES or "Files", cache.tab_display_name)
        or (state.lang.FILES or "Files")
    local function file_formatter(file_entry)
        local file_path = file_entry.path or file_entry.filePath or "???"
        return relpath_to_project(file_path)
    end
    local function custom_active_fn(entity, active_id_from_state)
        local candidate_path = entity.id
        local is_current_buffer_match = current_buf_info_init.name
            and candidate_path
            and vim.fn.fnamemodify(candidate_path, ":p") == current_buf_info_init.name
        local is_state_active_match = active_id_from_state
            and candidate_path
            and vim.fn.fnamemodify(candidate_path, ":p") == vim.fn.fnamemodify(active_id_from_state, ":p")
        return is_current_buffer_match or (not current_buf_info_init.name and is_state_active_match)
    end

    local initial_line = nil

    if current_buf_info_init.name then
        for i, file_entry in ipairs(cache.files_from_db) do
            local candidate_path = file_entry.id or file_entry.path or file_entry.filePath
            if candidate_path and vim.fn.fnamemodify(candidate_path, ":p") == current_buf_info_init.name then
                initial_line = i
                break
            end
        end
    end

    if not initial_line and selected_line_num then
        initial_line = selected_line_num
    end

    if not initial_line and state.file_active then
        for i, file_entry in ipairs(cache.files_from_db) do
            local candidate_path = file_entry.id or file_entry.path or file_entry.filePath
            if
                candidate_path
                and vim.fn.fnamemodify(candidate_path, ":p") == vim.fn.fnamemodify(state.file_active, ":p")
            then
                initial_line = i
                break
            end
        end
    end

    if not initial_line and cache.last_cursor_position > 1 then
        initial_line = cache.last_cursor_position
    end

    if not initial_line or initial_line > #cache.files_from_db then
        initial_line = #cache.files_from_db > 0 and 1 or nil
    end

    local ctx = common.init_entity_list(
        "file",
        cache.files_from_db,
        cache.file_ids_map,
        M.init,
        state.file_active,
        "id",
        initial_line,
        file_formatter,
        custom_active_fn
    )
    if not ctx then
        return
    end
    cache.ctx = ctx
    is_empty = ctx.is_empty

    if ctx.win and vim.api.nvim_win_is_valid(ctx.win) then
        local cursor_pos = vim.api.nvim_win_get_cursor(ctx.win)
        cache.last_cursor_position = cursor_pos[1]

        local win_config = vim.api.nvim_win_get_config(ctx.win)
        win_config.title = " " .. panel_title .. " "
        pcall(vim.api.nvim_win_set_config, ctx.win, win_config)
    end
    setup_keymaps(ctx)

    setup_cursor_tracking(ctx)
end

M.add_file = function()
    if not state.workspace_id or not state.tab_active then
        notify.error(state.lang.TAB_NOT_ACTIVE or "No active tab. Please select or create a tab first.")
        return
    end
    local current_dir = vim.fn.getcwd()
    local default_path = current_dir .. (current_dir:sub(-1) == "/" and "" or "/")
    ui.create_input_field(state.lang.FILES_NAME or "File path:", default_path, function(input_file_path)
        if not input_file_path or vim.trim(input_file_path) == "" then
            notify.info(state.lang.OPERATION_CANCELLED or "Operation cancelled.")
            return
        end
        local result_add = add_file_db(vim.trim(input_file_path), state.workspace_id, state.tab_active)
        if type(result_add) == "string" then
            local error_message
            if result_add == "LEN_NAME" then
                error_message = state.lang.FILE_PATH_LEN or "File path is invalid (e.g. too short)."
            elseif result_add == "EXIST_NAME" then
                error_message = state.lang.FILE_PATH_EXIST or "File already exists in this tab."
            elseif result_add == "INVALID_DIR" then
                error_message = state.lang.FILE_PATH_INVALID_DIR
                    or "The directory for the file path does not exist or is invalid."
            elseif result_add == "DIR_ADD_NOT_ALLOWED" then
                error_message = state.lang.FILE_DIR_ADD_NOT_ALLOWED
                    or "Cannot add a directory. Please specify a file path."
            elseif result_add == "ADD_FAILED" then
                error_message = state.lang.FILE_ADD_FAILED or "Failed to add file to tab."
            else
                error_message = (state.lang.FILE_ADD_FAILED or "Failed to add file to tab.")
                    .. " (Code: "
                    .. result_add
                    .. ")"
            end
            notify.error(error_message)
        else
            notify.info(state.lang.FILE_ADDED_SUCCESS or "File added successfully to tab.")
        end
        M.refresh()
    end)
end

M.add_current_buffer_to_tab = function(from_external)
    local current_buf_info_add = get_current_buffer_info()
    if not current_buf_info_add.name then
        notify.error(state.lang.CURRENT_BUFFER_NO_PATH or "Current buffer has no associated file path.")
        return false
    end
    if not state.workspace_id or not state.tab_active then
        notify.error(state.lang.TAB_NOT_ACTIVE or "No active tab. Please select or create a tab first.")
        return false
    end
    local result_add_current = add_file_db(current_buf_info_add.name, state.workspace_id, state.tab_active)
    if result_add_current and type(result_add_current) == "number" then
        notify.info(state.lang.CURRENT_FILE_ADDED or "Current file added to tab.")
        if not from_external then
            M.refresh()
        end
        return true
    elseif result_add_current == "EXIST_NAME" then
        if not from_external then
            notify.info(state.lang.FILE_PATH_EXIST or "File already exists in this tab.")
            M.refresh()
        end
        return true
    else
        local error_message = state.lang.FILE_ADD_FAILED or "Failed to add file to tab."
        if type(result_add_current) == "string" then
            error_message = error_message .. " (Code: " .. result_add_current .. ")"
        end
        notify.error(error_message)
        if not from_external then
            M.refresh()
        end
        return false
    end
end

M.remove_current_buffer_from_tab = function()
    local current_buf_info_remove = get_current_buffer_info()
    if not current_buf_info_remove.name then
        notify.error(state.lang.CURRENT_BUFFER_NO_PATH or "Current buffer has no associated file path.")
        return false
    end
    if not state.workspace_id or not state.tab_active then
        notify.error(state.lang.TAB_NOT_ACTIVE or "No active tab defined.")
        return false
    end

    local result_remove = delete_file_db(current_buf_info_remove.name, state.workspace_id, state.tab_active)
    if result_remove then
        return true
    else
        notify.error(state.lang.FILE_CURRENT_NOT_FOUND or "Current file is not part of this tab, or deletion failed.")
        return false
    end
end

M.get_current_file_info = function()
    if not state.file_active or not state.workspace_id or not state.tab_active then
        return nil
    end
    return get_file_by_id(state.file_active, cache.files_from_db)
end

M.switch_to_file_by_path = function(file_path)
    if not state.workspace_id or not state.tab_active then
        return false
    end
    local normalized_path_to_switch = vim.fn.fnamemodify(file_path, ":p")
    for _, file_entry in ipairs(cache.files_from_db) do
        local candidate_path = file_entry.id
        if candidate_path and vim.fn.fnamemodify(candidate_path, ":p") == normalized_path_to_switch then
            if cache.file_ids_map then
                cache.file_ids_map[1] = candidate_path
            end
            state.file_active = candidate_path
            M._switch_file()
            return true
        end
    end
    local add_result_switch = add_file_db(normalized_path_to_switch, state.workspace_id, state.tab_active)
    if type(add_result_switch) == "number" then
        M.refresh()
        for _, file_entry_after_add in ipairs(cache.files_from_db) do
            local candidate_path_after_add = file_entry_after_add.id
            if
                candidate_path_after_add
                and vim.fn.fnamemodify(candidate_path_after_add, ":p") == normalized_path_to_switch
            then
                if cache.file_ids_map then
                    cache.file_ids_map[1] = candidate_path_after_add
                end
                state.file_active = candidate_path_after_add
                M._switch_file()
                return true
            end
        end
        return false
    else
        local error_message = state.lang.FILE_ADD_FAILED or "Failed to add file for switching."
        if type(add_result_switch) == "string" then
            if add_result_switch == "DIR_ADD_NOT_ALLOWED" then
                error_message = state.lang.FILE_DIR_ADD_NOT_ALLOWED or "Cannot add a directory."
            end
        end
        notify.error(error_message)
        return false
    end
end

M.clear_validation_cache = function()
    cache.validation_cache = {}
end

return M
