local config = require("lvim-space.config")
local notify = require("lvim-space.api.notify")
local state = require("lvim-space.api.state")
local data = require("lvim-space.api.data")
local ui = require("lvim-space.ui")
local common = require("lvim-space.ui.common")
local log = require("lvim-space.api.log")
local session = require("lvim-space.core.session")

local M = {}
local cache = { file_ids_map = {}, files_from_db = {}, ctx = nil, tab_display_name = "" }
local is_empty = false
local last_normal_win = nil
local last_real_win = nil
local validation_cache = {}

local is_plugin_panel_win = ui.is_plugin_window

local function capture_current_window()
    local current_win = vim.api.nvim_get_current_win()
    if not is_plugin_panel_win(current_win) and vim.api.nvim_win_is_valid(current_win) then
        last_real_win = current_win
        log.debug("Remembered active window: " .. tostring(last_real_win))
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

local function validate_file_path(file_path)
    if not file_path or vim.trim(file_path) == "" then
        return nil, "LEN_NAME"
    end
    local cache_key = file_path
    if validation_cache[cache_key] then
        return validation_cache[cache_key].path, validation_cache[cache_key].error
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
    validation_cache[cache_key] = {
        path = error_code and nil or normalized_path,
        error = error_code,
    }
    return validation_cache[cache_key].path, validation_cache[cache_key].error
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

local function get_file_path_by_id(file_id)
    local file_entry = get_file_by_id(file_id, cache.files_from_db)
    if file_entry then
        return file_entry.path or file_entry.filePath
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
        end
        return rel
    end
    return vim.fn.fnamemodify(file_path, ":~:.")
end

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

local function update_files_state_in_db()
    if not config.autosave or not state.tab_active or not state.workspace_id then
        return
    end
    local tab = data.find_tab_by_id(state.tab_active, state.workspace_id)
    if tab then
        local tab_data = tab.data and vim.fn.json_decode(tab.data) or {}
        data.update_tab_data(state.tab_active, vim.fn.json_encode(tab_data), state.workspace_id)
    end
end

local function add_file_db(file_path, workspace_id, tab_id)
    local validated_path, error_code = validate_file_path(file_path)
    if not validated_path then
        return error_code
    end
    if error_code == "DIR_ADD_NOT_ALLOWED" then
        return error_code
    end
    local tab_data = get_tab_data(tab_id, workspace_id)
    if not tab_data then
        return "ADD_FAILED"
    end
    for _, buf_entry in ipairs(tab_data.buffers) do
        local candidate_path = buf_entry.path or buf_entry.filePath
        if candidate_path and vim.fn.fnamemodify(candidate_path, ":p") == vim.fn.fnamemodify(validated_path, ":p") then
            log.info("add_file_db: File already exists in this tab: " .. validated_path)
            return "EXIST_NAME"
        end
    end
    local new_bufnr = vim.fn.bufadd(validated_path)
    vim.bo[new_bufnr].buflisted = true
    local new_buffer_entry = {
        bufnr = new_bufnr,
        filePath = validated_path,
        filetype = vim.bo[new_bufnr].filetype or "",
        added_at = os.time(),
    }
    table.insert(tab_data.buffers, new_buffer_entry)
    if update_tab_data(tab_id, workspace_id, tab_data) then
        log.info(string.format("add_file_db: Successfully added file '%s' (bufnr: %s)", validated_path, new_bufnr))
        validation_cache = {}
        update_files_state_in_db()
        return new_bufnr
    else
        return "ADD_FAILED"
    end
end

local function delete_file_db(file_id, workspace_id, tab_id, selected_line_num)
    local tab_data = get_tab_data(tab_id, workspace_id)
    if not tab_data then
        return nil
    end
    local index_to_remove, file_to_remove = nil, nil
    for i, buf_entry in ipairs(tab_data.buffers) do
        local candidate_id = buf_entry.id or buf_entry.bufnr
        if tostring(candidate_id) == tostring(file_id) then
            index_to_remove = i
            file_to_remove = buf_entry
            break
        end
    end
    if not index_to_remove or not file_to_remove then
        log.warn("delete_file_db: File ID " .. tostring(file_id) .. " not found in tab")
        return nil
    end
    local current_buf_info = get_current_buffer_info()
    local candidate_path = file_to_remove.path or file_to_remove.filePath
    local is_current_file = current_buf_info.name
        and candidate_path
        and vim.fn.fnamemodify(candidate_path, ":p") == current_buf_info.name
    table.remove(tab_data.buffers, index_to_remove)
    log.info(
        string.format(
            "delete_file_db: File ID %s (%s) deleted successfully",
            tostring(file_id),
            tostring(candidate_path)
        )
    )
    if update_tab_data(tab_id, workspace_id, tab_data) then
        update_files_state_in_db()
        vim.schedule(function()
            if is_current_file then
                log.info("delete_file_db: Deleted file was active, creating empty buffer")
                local windows_with_buffer = {}
                for _, win in ipairs(vim.api.nvim_list_wins()) do
                    if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == current_buf_info.bufnr then
                        table.insert(windows_with_buffer, win)
                    end
                end
                local new_buf = vim.api.nvim_create_buf(true, false)
                vim.bo[new_buf].buftype = ""
                vim.bo[new_buf].filetype = ""
                for _, win in ipairs(windows_with_buffer) do
                    if vim.api.nvim_win_is_valid(win) then
                        vim.api.nvim_win_set_buf(win, new_buf)
                    end
                end
                pcall(vim.api.nvim_buf_delete, current_buf_info.bufnr, { force = true })
                if tostring(state.file_active) == tostring(file_id) then
                    state.file_active = nil
                end
                notify.info(state.lang.FILE_REMOVE_REPLACE)
            else
                pcall(vim.api.nvim_buf_delete, file_id, { force = false })
            end
            M.init(selected_line_num)
        end)
        return true
    else
        return false
    end
end

function M.handle_file_delete()
    if is_empty then
        return
    end
    local file_id_at_cursor = common.get_id_at_cursor(cache.file_ids_map)
    if not file_id_at_cursor then
        return
    end
    local file_entry = get_file_by_id(file_id_at_cursor, cache.files_from_db)
    if not file_entry then
        notify.error(state.lang.FILE_NOT_FOUND)
        return
    end
    local current_line_num = cache.ctx
            and cache.ctx.win
            and vim.api.nvim_win_is_valid(cache.ctx.win)
            and vim.api.nvim_win_get_cursor(cache.ctx.win)[1]
        or 1
    local result = delete_file_db(file_id_at_cursor, state.workspace_id, state.tab_active, current_line_num)
    if not result then
        notify.error(state.lang.FILE_DELETE_FAILED)
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
                vim.api.nvim_set_current_win(stored_win)
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

function M.add_file()
    if not state.workspace_id or not state.tab_active then
        notify.error(state.lang.TAB_NOT_ACTIVE)
        log.warn("add_file: Tried to add file without active tab")
        return
    end
    local current_dir = vim.fn.getcwd()
    local default_path = current_dir .. "/"
    ui.create_input_field(state.lang.FILES_NAME, default_path, function(input_file_path)
        if not input_file_path or vim.trim(input_file_path) == "" then
            notify.info(state.lang.OPERATION_CANCELLED)
            return
        end
        local result = add_file_db(vim.trim(input_file_path), state.workspace_id, state.tab_active)
        if result == "LEN_NAME" then
            notify.error(state.lang.FILE_PATH_LEN)
            M.init()
        elseif result == "EXIST_NAME" then
            notify.error(state.lang.FILE_PATH_EXIST)
            M.init()
        elseif result == "INVALID_DIR" then
            notify.error(state.lang.FILE_PATH_INVALID_DIR)
            M.init()
        elseif result == "DIR_ADD_NOT_ALLOWED" then
            notify.error(state.lang.FILE_DIR_ADD_NOT_ALLOWED)
            M.init()
        elseif result == "ADD_FAILED" then
            notify.error(state.lang.FILE_ADD_FAILED)
            M.init()
        else
            notify.info(state.lang.FILE_ADDED_SUCCESS)
            M.init()
        end
    end)
end

function M.navigate_to_projects()
    capture_current_window()
    ui.close_all()
    require("lvim-space.ui.projects").init()
end

function M.navigate_to_workspaces()
    if not state.project_id then
        notify.info(state.lang.PROJECT_NOT_ACTIVE)
        return
    end
    capture_current_window()
    ui.close_all()
    require("lvim-space.ui.workspaces").init()
end

function M.navigate_to_tabs()
    if not state.project_id then
        notify.info(state.lang.PROJECT_NOT_ACTIVE)
        return
    end
    if not state.workspace_id then
        notify.info(state.lang.WORKSPACE_NOT_ACTIVE)
        return
    end
    capture_current_window()
    ui.close_all()
    require("lvim-space.ui.tabs").init()
end

function M._switch_file()
    local file_id_selected = common.get_id_at_cursor(cache.file_ids_map)
    if not file_id_selected then
        log.warn("switch_file: No file selected from list")
        return
    end
    if tostring(state.file_active) == tostring(file_id_selected) then
        log.info("switch_file: Already in file ID: " .. tostring(file_id_selected))
        return
    end
    local file_path_to_open = get_file_path_by_id(file_id_selected)
    if not file_path_to_open then
        notify.error(state.lang.FILE_PATH_NOT_FOUND)
        log.error("switch_file: File ID " .. file_id_selected .. " not found")
        return
    end
    if vim.fn.filereadable(file_path_to_open) ~= 1 then
        notify.error(state.lang.FILE_NOT_READABLE)
        log.error("switch_file: File cannot be read: " .. file_path_to_open)
        return
    end
    log.info(
        string.format(
            "switch_file: Switching from file %s to file %s (%s)",
            tostring(state.file_active),
            tostring(file_id_selected),
            file_path_to_open
        )
    )
    local bufnr = vim.fn.bufadd(file_path_to_open)
    vim.fn.bufload(bufnr)
    local target_win = last_real_win
    if not target_win or not vim.api.nvim_win_is_valid(target_win) or is_plugin_panel_win(target_win) then
        target_win = get_last_normal_win()
    end
    if target_win and vim.api.nvim_win_is_valid(target_win) then
        vim.api.nvim_win_set_buf(target_win, bufnr)
    end
    state.file_active = file_id_selected
    local cur_line = cache.ctx
            and cache.ctx.win
            and vim.api.nvim_win_is_valid(cache.ctx.win)
            and vim.api.nvim_win_get_cursor(cache.ctx.win)[1]
        or 1
    M.init(cur_line)
end

function M._split_file_vertical()
    local file_id_selected = common.get_id_at_cursor(cache.file_ids_map)
    if not file_id_selected then
        log.warn("split_file_vertical: No file selected from list")
        return
    end
    local file_path_to_open = get_file_path_by_id(file_id_selected)
    if not file_path_to_open then
        notify.error(state.lang.FILE_PATH_NOT_FOUND)
        log.error("split_file_vertical: File ID " .. file_id_selected .. " not found")
        return
    end
    if vim.fn.filereadable(file_path_to_open) ~= 1 then
        notify.error(state.lang.FILE_NOT_READABLE)
        log.error("split_file_vertical: File cannot be read: " .. file_path_to_open)
        return
    end
    log.info(string.format("split_file_vertical: Opening file ID %s, path '%s'", file_id_selected, file_path_to_open))
    capture_current_window()
    ui.close_all()
    local success, error_msg = pcall(function()
        vim.cmd("vsplit " .. vim.fn.fnameescape(file_path_to_open))
        last_real_win = vim.api.nvim_get_current_win()
    end)
    if success then
        log.info("split_file_vertical: File opened in vertical split")
        notify.info(state.lang.FILE_OPENED_VERTICAL)
    else
        log.error("split_file_vertical: Failed to open file: " .. tostring(error_msg))
        notify.error(state.lang.FILE_OPEN_VERTICAL_FAILED)
    end
end

function M._split_file_horizontal()
    local file_id_selected = common.get_id_at_cursor(cache.file_ids_map)
    if not file_id_selected then
        log.warn("split_file_horizontal: No file selected from list")
        return
    end
    local file_path_to_open = get_file_path_by_id(file_id_selected)
    if not file_path_to_open then
        notify.error(state.lang.FILE_PATH_NOT_FOUND)
        log.error("split_file_horizontal: File ID " .. file_id_selected .. " not found")
        return
    end
    if vim.fn.filereadable(file_path_to_open) ~= 1 then
        notify.error(state.lang.FILE_NOT_READABLE)
        log.error("split_file_horizontal: File cannot be read: " .. file_path_to_open)
        return
    end
    log.info(string.format("split_file_horizontal: Opening file ID %s, path '%s'", file_id_selected, file_path_to_open))
    capture_current_window()
    ui.close_all()
    local success, error_msg = pcall(function()
        vim.cmd("split " .. vim.fn.fnameescape(file_path_to_open))
        last_real_win = vim.api.nvim_get_current_win()
    end)
    if success then
        log.info("split_file_horizontal: File opened in horizontal split")
        notify.info(state.lang.FILE_OPENED_HORIZONTAL)
    else
        log.error("split_file_horizontal: Failed to open file: " .. tostring(error_msg))
        notify.error(state.lang.FILE_OPEN_HORIZONTAL_FAILED)
    end
end

local function setup_keymaps(ctx)
    local keymap_opts = { buffer = ctx.buf, noremap = true, silent = true, nowait = true }
    vim.keymap.set("n", config.keymappings.action.add, M.add_file, keymap_opts)

    vim.keymap.set("n", config.keymappings.action.delete, M.handle_file_delete, keymap_opts)
    vim.keymap.set("n", config.keymappings.action.switch, function()
        M.handle_file_switch({ close_panel = false })
    end, keymap_opts)
    vim.keymap.set("n", config.keymappings.action.enter, function()
        M.handle_file_switch({ close_panel = true })
    end, keymap_opts)
    vim.keymap.set("n", config.keymappings.action.split_v, M.handle_split_vertical, keymap_opts)
    vim.keymap.set("n", config.keymappings.action.split_h, M.handle_split_horizontal, keymap_opts)
    vim.keymap.set("n", config.keymappings.global.projects, M.navigate_to_projects, keymap_opts)
    vim.keymap.set("n", config.keymappings.global.workspaces, M.navigate_to_workspaces, keymap_opts)
    vim.keymap.set("n", config.keymappings.global.tabs, M.navigate_to_tabs, keymap_opts)
end

local function update_tab_display_name()
    cache.tab_display_name = ""
    local current_tab_obj = data.find_tab_by_id(state.tab_active, state.workspace_id)
    if current_tab_obj and current_tab_obj.name then
        cache.tab_display_name = current_tab_obj.name
    end
end

M.init = function(selected_line_num)
    capture_current_window()
    if
        not last_normal_win
        or not vim.api.nvim_win_is_valid(last_normal_win)
        or is_plugin_panel_win(last_normal_win)
    then
        last_normal_win = get_last_normal_win()
    end
    if not state.workspace_id or not state.tab_active then
        notify.error(state.lang.TAB_NOT_ACTIVE)
        local buf, _ = ui.open_main({ " " .. state.lang.TAB_NOT_ACTIVE }, state.lang.FILES, 1)
        if buf then
            vim.bo[buf].buftype = "nofile"
        end
        ui.open_actions(state.lang.INFO_LINE_GENERIC_QUIT)
        return
    end
    log.debug("files.M.init: Forcibly saved session for tab: " .. state.tab_active)
    session.save_current_state(state.tab_active, true)
    cache.files_from_db = data.find_files(state.workspace_id, state.tab_active) or {}
    cache.file_ids_map = {}

    local current_buf_info = get_current_buffer_info()
    update_tab_display_name()

    local panel_title = cache.tab_display_name ~= ""
            and string.format("%s (%s)", state.lang.FILES, cache.tab_display_name)
        or state.lang.FILES

    local function file_formatter(file_entry)
        local file_path = file_entry.path or file_entry.filePath or "???"
        return relpath_to_project(file_path)
    end

    local function custom_active_fn(entity, active_id)
        local candidate_path = entity.path or entity.filePath
        local candidate_id = entity.id or entity.bufnr
        local is_current_buffer = current_buf_info.name
            and candidate_path
            and vim.fn.fnamemodify(candidate_path, ":p") == current_buf_info.name
        local is_state_active = tostring(candidate_id) == tostring(active_id)
        return is_current_buffer or (not current_buf_info.name and is_state_active)
    end

    local ctx = common.init_entity_list(
        "file",
        cache.files_from_db,
        cache.file_ids_map,
        M.init,
        state.file_active,
        "id",
        selected_line_num,
        file_formatter,
        custom_active_fn
    )
    if not ctx then
        log.error("files.M.init: common.init_entity_list returned no context")
        return
    end
    cache.ctx = ctx
    is_empty = ctx.is_empty
    if ctx.win and vim.api.nvim_win_is_valid(ctx.win) then
        local win_config = vim.api.nvim_win_get_config(ctx.win)
        win_config.title = " " .. panel_title .. " "
        pcall(vim.api.nvim_win_set_config, ctx.win, win_config)
    end
    setup_keymaps(ctx)
end

M.add_current_buffer_to_tab = function()
    local current_buf_info = get_current_buffer_info()
    if not current_buf_info.name then
        notify.error(state.lang.CURRENT_BUFFER_NO_PATH)
        return false
    end
    if not state.workspace_id or not state.tab_active then
        notify.error(state.lang.TAB_NOT_ACTIVE)
        return false
    end
    local result = add_file_db(current_buf_info.name, state.workspace_id, state.tab_active)
    if result and type(result) == "number" then
        notify.info(state.lang.CURRENT_FILE_ADDED)
        return true
    else
        notify.error(state.lang.FILE_ADD_FAILED)
        return false
    end
end

M.remove_current_buffer_from_tab = function()
    local current_buf_info = get_current_buffer_info()
    if not current_buf_info.name then
        notify.error(state.lang.CURRENT_BUFFER_NO_PATH)
        return false
    end
    local files = data.find_files(state.workspace_id, state.tab_active) or {}
    local file_id_to_remove = nil
    for _, file_entry in ipairs(files) do
        local candidate_path = file_entry.path or file_entry.filePath
        if candidate_path and vim.fn.fnamemodify(candidate_path, ":p") == current_buf_info.name then
            file_id_to_remove = file_entry.id or file_entry.bufnr
            break
        end
    end
    if file_id_to_remove then
        return delete_file_db(file_id_to_remove, state.workspace_id, state.tab_active, nil)
    else
        notify.error(state.lang.FILE_CURRENT_NOT_FOUND)
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
    local files = data.find_files(state.workspace_id, state.tab_active) or {}
    local normalized_path = vim.fn.fnamemodify(file_path, ":p")
    for _, file in ipairs(files) do
        local candidate_path = file.path or file.filePath
        if candidate_path and vim.fn.fnamemodify(candidate_path, ":p") == normalized_path then
            local file_id = file.id or file.bufnr
            cache.file_ids_map[1] = file_id
            M._switch_file()
            return true
        end
    end
    return false
end

M.clear_validation_cache = function()
    validation_cache = {}
end

return M
