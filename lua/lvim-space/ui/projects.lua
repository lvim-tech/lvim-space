--- Projects UI panel for lvim-space.
--- Manages the project list panel: rendering, keymaps, CRUD operations,
--- project switching, and navigation to child panels (workspaces/tabs/files).

local config = require("lvim-space.config")
local notify = require("lvim-space.api.notify")
local state = require("lvim-space.api.state")
local data = require("lvim-space.api.data")
local ui = require("lvim-space.ui")
local utils = require("lvim-space.utils")
local common = require("lvim-space.ui.common")
local session = require("lvim-space.core.session")

local M = {}

---Safely decode a JSON string, returning `default` on malformed input or nil.
---@param str string|nil JSON string to decode
---@param default table Fallback value when decoding fails
---@return table
local function safe_json_decode(str, default)
    if not str then return default end
    local ok, result = pcall(vim.fn.json_decode, str)
    return (ok and type(result) == "table") and result or default
end

---@class ProjectsCache
---@field project_ids_map table<number, number> Map from visual line number to project DB id
---@field projects_from_db table[] Sorted list of project records fetched from the database
---@field ctx table|nil Active panel context returned by common.init_entity_list
---@field validation_cache table<string, {path: string|nil, error: string|nil}> Cached path-validation results
---@field last_cursor_position number Last known cursor row in the panel window

---@type ProjectsCache
local cache = {
    project_ids_map = {},
    projects_from_db = {},
    ctx = nil,
    validation_cache = {},
    last_cursor_position = 1,
}

---@type number|nil Window handle of the last non-plugin editor window
local last_real_win = nil

local is_plugin_panel_win = ui.is_plugin_window

--- Saves the current window as the last real (non-plugin) editor window.
local function save_window_context()
    local current_win = vim.api.nvim_get_current_win()
    if current_win and vim.api.nvim_win_is_valid(current_win) and not is_plugin_panel_win(current_win) then
        last_real_win = current_win
    end
end

--- Persists the current cursor row from the panel window into the cache.
local function save_cursor_position()
    if cache.ctx and cache.ctx.win and vim.api.nvim_win_is_valid(cache.ctx.win) then
        local cursor_pos = vim.api.nvim_win_get_cursor(cache.ctx.win)
        cache.last_cursor_position = cursor_pos[1]
    end
end

--- Registers a CursorMoved autocmd that keeps `cache.last_cursor_position` up to date.
---@param ctx table Panel context with `win` and `buf` fields
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
        group = vim.api.nvim_create_augroup("LvimSpaceProjectsCursor", { clear = true }),
    })
end

--- Re-renders the project list in the existing panel window without reopening it.
--- Falls back to `M.init` when the window or buffer is no longer valid.
M.refresh = function()
    if not cache.ctx or not cache.ctx.win or not vim.api.nvim_win_is_valid(cache.ctx.win) then
        return M.init()
    end

    if not cache.ctx.buf or not vim.api.nvim_buf_is_valid(cache.ctx.buf) then
        return M.init()
    end

    save_cursor_position()

    cache.projects_from_db = data.find_projects() or {}
    table.sort(cache.projects_from_db, function(a, b)
        local order_a = tonumber(a.sort_order) or math.huge
        local order_b = tonumber(b.sort_order) or math.huge
        if order_a == order_b then
            return (a.name or "") < (b.name or "")
        end
        return order_a < order_b
    end)
    cache.project_ids_map = {}

    local icons = config.ui.icons
    local project_active_icon = icons.project_active or " "
    local project_icon        = icons.project        or " "

    local new_lines = {}
    for i, project_entry in ipairs(cache.projects_from_db) do
        cache.project_ids_map[i] = project_entry.id
        local is_active = tostring(project_entry.id) == tostring(state.project_id)
        local display_text = string.format("%s [%s]", project_entry.name or "???", project_entry.path or "???")
        display_text = (is_active and project_active_icon or project_icon) .. display_text

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

    if #new_lines > 0 and cache.ctx.win and vim.api.nvim_win_is_valid(cache.ctx.win) then
        local max_line = #new_lines
        local target_line = math.min(cache.last_cursor_position, max_line)
        target_line = math.max(target_line, 1)
        pcall(vim.api.nvim_win_set_cursor, cache.ctx.win, { target_line, 0 })
    end

    cache.ctx.is_empty = #new_lines == 0
    cache.ctx.entities = cache.projects_from_db

    if cache.ctx.win and vim.api.nvim_win_is_valid(cache.ctx.win) then
        local win_config = vim.api.nvim_win_get_config(cache.ctx.win)
        win_config.title = " " .. (state.lang.PROJECTS or "Projects") .. " "
        pcall(vim.api.nvim_win_set_config, cache.ctx.win, win_config)
    end
end

--- Returns the entity-type definition table for "project" from the common module.
---@return EntityTypeDef|nil entity_def Entity-type definition with error keys, icons, and labels
local function get_entity_def()
    return common.get_entity_type("project")
end

--- Validates a project name for an add or rename operation.
--- Checks length/format via common validation and uniqueness in the database.
---@param project_name string The candidate project name to validate
---@param project_id_for_rename number|nil When renaming, the id of the project being renamed (allows keeping the same name)
---@return string|nil validated_name Trimmed valid name, or nil on failure
---@return string|nil err_code Error code string such as "EXIST_NAME", or nil on success
local function validate_project_name_for_add_or_rename(project_name, project_id_for_rename)
    local ok, err_code = common.validate_entity_name("project", project_name)
    if not ok then
        return nil, err_code
    end
    local trimmed_name = vim.trim(project_name)
    local existing_project_ids_with_name = data.is_project_name_exist(trimmed_name)
    if existing_project_ids_with_name and #existing_project_ids_with_name > 0 then
        if project_id_for_rename then
            for _, existing_id in ipairs(existing_project_ids_with_name) do
                if tostring(existing_id) ~= tostring(project_id_for_rename) then
                    return nil, "EXIST_NAME"
                end
            end
        else
            return nil, "EXIST_NAME"
        end
    end
    return trimmed_name, nil
end

--- Validates a filesystem path for a project, checking existence, permissions,
--- and (for new projects) uniqueness in the database. Results are cached.
---@param project_path string Raw path string entered by the user
---@param is_new_project boolean When true, also checks that the path is not already registered
---@return string|nil normalized_path Expanded and normalised absolute path with trailing slash, or nil on error
---@return string|nil err_code Error code such as "DIRECTORY_NOT_FOUND", "DIRECTORY_NOT_ACCESS", or "PROJECT_PATH_EXIST"
local function validate_project_path(project_path, is_new_project)
    if not project_path or vim.trim(project_path) == "" then
        return nil, "PROJECT_PATH_EMPTY"
    end
    local cache_key = project_path .. tostring(is_new_project)
    if cache.validation_cache[cache_key] then
        return cache.validation_cache[cache_key].path, cache.validation_cache[cache_key].error
    end
    local normalized_path = vim.trim(project_path):gsub("/$", "")
    normalized_path = vim.fn.expand(normalized_path)
    normalized_path = vim.fn.fnamemodify(normalized_path, ":p")
    if not normalized_path:match("/$") then
        normalized_path = normalized_path .. "/"
    end
    local error_code = nil
    if vim.fn.isdirectory(normalized_path) ~= 1 then
        error_code = "DIRECTORY_NOT_FOUND"
    elseif not utils.file_system.has_permission(normalized_path) then
        error_code = "DIRECTORY_NOT_ACCESS"
    elseif is_new_project and data.is_project_path_exist(normalized_path) then
        error_code = "PROJECT_PATH_EXIST"
    end
    cache.validation_cache[cache_key] = {
        path = error_code and nil or normalized_path,
        error = error_code,
    }
    return cache.validation_cache[cache_key].path, cache.validation_cache[cache_key].error
end

--- Inserts a new project record into the database and clears the validation cache.
---@param project_path string Normalised absolute path for the project root
---@param project_name string Display name for the new project
---@return number|nil row_id The newly inserted row id, or nil on failure
---@return string|nil err_code "PROJECT_ADD_FAILED" on failure, nil on success
local function add_project_db(project_path, project_name)
    local row_id = data.add_project(project_path, project_name)
    if not row_id or type(row_id) ~= "number" or row_id <= 0 then
        return nil, "PROJECT_ADD_FAILED"
    end
    cache.validation_cache = {}
    return row_id, nil
end

--- Persists a new name for an existing project and schedules a panel re-init.
---@param project_id_to_rename number Database id of the project to rename
---@param new_validated_name string Already-validated new name
---@param _ any Unused context parameter (reserved for future use)
---@param selected_line_num number|nil Visual line to restore cursor to after re-init
---@return true|nil result true on success, nil on database failure
local function rename_project_db(project_id_to_rename, new_validated_name, _, selected_line_num)
    local success = data.update_project_name(project_id_to_rename, new_validated_name)
    if not success then
        return nil
    end
    vim.schedule(function()
        M.init(selected_line_num)
    end)
    return true
end

--- Deletes a project from the database and resets active state if it was the current project.
---@param project_id number Database id of the project to delete
---@param _ any Unused context parameter (reserved for future use)
---@param selected_line_num number|nil Visual line to restore cursor to after re-init
---@return true|nil result true on success, nil on database failure
local function delete_project_db(project_id, _, selected_line_num)
    local success = data.delete_project(project_id)
    if not success then
        return nil
    end
    vim.schedule(function()
        local was_active_project = tostring(state.project_id) == tostring(project_id)
        if was_active_project then
            state.project_id = nil
            state.workspace_id = nil
            state.tab_ids = {}
            state.tab_active = nil
            state.file_active = nil
            session.clear_current_state()
        end
        M.init(selected_line_num)
    end)
    return true
end

--- Persists the current workspace and tab state to the database when autosave is enabled.
--- Writes the active workspace flag and encodes tab ids/active tab into the workspace record.
local function update_project_state_in_db()
    if not config.autosave or not state.project_id then
        return
    end
    if state.workspace_id then
        data.set_workspace_active(state.workspace_id, state.project_id)
    end
    if state.workspace_id and state.tab_ids then
        local ws = data.find_workspace_by_id(state.workspace_id, state.project_id)
        if ws then
            local tabs_json_obj = safe_json_decode(ws.tabs, {})
            tabs_json_obj.tab_active = state.tab_active
            tabs_json_obj.tab_ids = state.tab_ids
            tabs_json_obj.updated_at = os.time()
            data.update_workspace_tabs(vim.fn.json_encode(tabs_json_obj), state.workspace_id)
        end
    end
end

--- Resolves and activates the appropriate workspace for the given project.
--- Prefers the workspace previously marked active; falls back to the first workspace.
--- Also restores tab state from the workspace's JSON blob and persists changes.
---@param project_id number Database id of the project being switched to
local function set_active_workspace_for_project(project_id)
    local all_workspaces = data.find_workspaces(project_id) or {}
    local selected_ws = nil
    for _, ws in ipairs(all_workspaces) do
        if
            tostring(ws.project_id) == tostring(project_id)
            and (ws.active == 1 or ws.active == "1" or ws.active == true)
        then
            selected_ws = ws
            break
        end
    end
    if not selected_ws and #all_workspaces > 0 then
        selected_ws = all_workspaces[1]
    end
    if selected_ws then
        state.workspace_id = selected_ws.id
        local tabs_obj = safe_json_decode(selected_ws.tabs, {})
        state.tab_active = tabs_obj.tab_active
        state.tab_ids = tabs_obj.tab_ids or {}
    else
        state.workspace_id = nil
        state.tab_active = nil
        state.tab_ids = {}
    end
    update_project_state_in_db()
end

--- Switches the active project in "space" mode: validates the path, saves the current
--- session, changes the working directory, activates the workspace, and restores state.
--- Triggers UI refresh once the session restore autocmd fires (or immediately if no session).
---@param project_id number Database id of the project to switch to
---@param selected_line_in_ui number|nil Visual line in the projects panel to restore after reinit
local function space_load_project(project_id, selected_line_in_ui)
    local selected_project = data.find_project_by_id(project_id)
    if not selected_project then
        notify.error(state.lang.PROJECT_NOT_FOUND)
        return
    end
    local path_to_check = selected_project.path
    if vim.fn.isdirectory(path_to_check) ~= 1 then
        notify.error((state.lang.DIRECTORY_NOT_FOUND or "Directory not found") .. ": " .. path_to_check)
        return
    end
    if not utils.file_system.has_permission(path_to_check) then
        notify.error((state.lang.DIRECTORY_NOT_ACCESS or "Directory not accessible") .. ": " .. path_to_check)
        return
    end
    if state.tab_active then
        session.save_current_state(state.tab_active, true)
    end
    local old_disable_auto_close = state.disable_auto_close
    state.disable_auto_close = true
    local success_chdir, error_msg_chdir = pcall(vim.api.nvim_set_current_dir, path_to_check)
    if not success_chdir then
        notify.error(
            (state.lang.CHANGE_DIRECTORY_FAILED or "Failed to change directory to %s"):format(path_to_check)
                .. " Error: "
                .. tostring(error_msg_chdir)
        )
        state.disable_auto_close = old_disable_auto_close
        return
    end
    state.project_id = project_id
    set_active_workspace_for_project(project_id)
    local space_restore_augroup = vim.api.nvim_create_augroup("LvimSpaceProjectRestore", { clear = true })
    local function final_ui_update_and_notify()
        M.init(selected_line_in_ui)
        if state.ui and state.ui.content and vim.api.nvim_win_is_valid(state.ui.content.win) then
            local main_ui_win = state.ui.content.win
            vim.api.nvim_set_current_win(main_ui_win)
            if selected_line_in_ui then
                pcall(vim.api.nvim_win_set_cursor, main_ui_win, { selected_line_in_ui, 0 })
            end
        end
        state.disable_auto_close = old_disable_auto_close
        notify.info(state.lang.PROJECT_SWITCHED_TO .. selected_project.name)
    end
    if state.workspace_id and state.tab_active then
        vim.api.nvim_create_autocmd({ "BufEnter", "WinEnter" }, {
            group = space_restore_augroup,
            callback = function()
                vim.api.nvim_clear_autocmds({ group = space_restore_augroup })
                vim.schedule(final_ui_update_and_notify)
            end,
            once = true,
        })
        session.restore_state(state.tab_active, true)
    else
        session.clear_current_state()
        vim.schedule(final_ui_update_and_notify)
    end
end

--- Switches to a project in "enter" mode: closes all panels, changes the working
--- directory, restores the session if available, then opens the deepest relevant panel
--- (files, tabs, or workspaces depending on the restored state).
---@param project_id number Database id of the project to navigate into
local function enter_navigate_next(project_id)
    local selected_project = data.find_project_by_id(project_id)
    if not selected_project then
        notify.error(state.lang.PROJECT_NOT_FOUND)
        return
    end
    local path_to_check = selected_project.path
    if vim.fn.isdirectory(path_to_check) ~= 1 then
        notify.error((state.lang.DIRECTORY_NOT_FOUND or "Directory not found") .. ": " .. path_to_check)
        return
    end
    if not utils.file_system.has_permission(path_to_check) then
        notify.error((state.lang.DIRECTORY_NOT_ACCESS or "Directory not accessible") .. ": " .. path_to_check)
        return
    end
    if state.tab_active then
        session.save_current_state(state.tab_active, true)
    end
    local success_chdir, error_msg_chdir = pcall(vim.api.nvim_set_current_dir, path_to_check)
    if not success_chdir then
        notify.error(
            (state.lang.CHANGE_DIRECTORY_FAILED or "Failed to change directory to %s"):format(path_to_check)
                .. " Error: "
                .. tostring(error_msg_chdir)
        )
        return
    end
    state.project_id = project_id
    set_active_workspace_for_project(project_id)
    state.disable_auto_close = true
    ui.close_all()
    notify.info(state.lang.PROJECT_SWITCHED_TO .. selected_project.name)
    vim.schedule(function()
        local target_init_func
        if state.workspace_id and state.tab_active then
            session.restore_state(state.tab_active, true)
            target_init_func = require("lvim-space.ui.files").init
        elseif state.workspace_id then
            target_init_func = require("lvim-space.ui.tabs").init
        else
            target_init_func = function()
                require("lvim-space.ui.workspaces").init(nil, { select_workspace = false })
            end
        end
        vim.schedule(function()
            state.disable_auto_close = false
            if target_init_func then
                target_init_func()
            end
        end)
    end)
end

--- Moves the project under the cursor one position up or down in the sort order,
--- swapping sort_order values with the adjacent project and refreshing the panel.
---@param ctx table Panel context with `win` field pointing to the projects window
---@param direction "up"|"down" Direction to move the project
local function handle_move_operation(ctx, direction)
    if not ctx or not ctx.win or not vim.api.nvim_win_is_valid(ctx.win) then
        return
    end
    local current_visual_line = vim.api.nvim_win_get_cursor(ctx.win)[1]
    local project_id_to_move = cache.project_ids_map[current_visual_line]
    if not project_id_to_move then
        return
    end
    local project_to_move_data = cache.projects_from_db[current_visual_line]
    local project_type_def = get_entity_def()
    if not project_type_def then
        notify.error(state.lang.PROJECT_REORDER_FAILED)
        return
    end
    if not project_to_move_data or tostring(project_to_move_data.id) ~= tostring(project_id_to_move) then
        notify.error(state.lang[project_type_def.ui_cache_error])
        return
    end
    local current_sort_order = tonumber(project_to_move_data.sort_order)
    if not current_sort_order then
        notify.error(state.lang[project_type_def.reorder_failed_error])
        return
    end
    if direction == "up" and current_visual_line <= 1 then
        notify.info(state.lang.PROJECT_ALREADY_AT_TOP)
        return
    elseif direction == "down" and current_visual_line >= #cache.projects_from_db then
        notify.info(state.lang.PROJECT_ALREADY_AT_BOTTOM)
        return
    end
    local target_sort_order = direction == "up" and (current_sort_order - 1) or (current_sort_order + 1)
    local new_order_table = {}
    for _, proj_entry in ipairs(cache.projects_from_db) do
        local entry_sort_order = tonumber(proj_entry.sort_order)
        if not entry_sort_order then
            goto continue
        end
        local new_order_for_this_item = entry_sort_order
        if proj_entry.id == project_id_to_move then
            new_order_for_this_item = target_sort_order
        elseif entry_sort_order == target_sort_order then
            new_order_for_this_item = current_sort_order
        end
        table.insert(new_order_table, { id = proj_entry.id, order = new_order_for_this_item })
        ::continue::
    end
    local success, err_msg_code = data.reorder_projects(new_order_table)
    if success then
        local new_line = direction == "up" and (current_visual_line - 1) or (current_visual_line + 1)
        M.init(new_line)
    else
        local err_key_to_use = project_type_def.reorder_failed_error
        if err_msg_code == "PROJECT_REORDER_MISSING_PARAMS" then
            err_key_to_use = project_type_def.reorder_missing_params_error
        end
        notify.error(state.lang[err_key_to_use])
        M.init(current_visual_line)
    end
end

--- Public entry point that delegates to `M.add_project` to start the add-project flow.
function M.handle_project_add()
    M.add_project()
end

--- Opens a rename prompt for the project under the cursor in the panel.
---@param ctx table Panel context; used to read the current cursor line
function M.handle_project_rename(ctx)
    local current_line_num = ctx
            and ctx.win
            and vim.api.nvim_win_is_valid(ctx.win)
            and vim.api.nvim_win_get_cursor(ctx.win)[1]
        or 1
    local project_id_to_rename_val = common.get_id_at_cursor(cache.project_ids_map)
    local current_name = ""
    if cache.projects_from_db and cache.projects_from_db[current_line_num] then
        current_name = cache.projects_from_db[current_line_num].name
    end
    common.rename_entity(
        "project",
        project_id_to_rename_val,
        current_name,
        project_id_to_rename_val,
        function(id_from_common, new_name_from_input, context_project_id)
            local validated_name, err_code =
                validate_project_name_for_add_or_rename(new_name_from_input, context_project_id)
            if not validated_name then
                return err_code
            end
            return rename_project_db(id_from_common, validated_name, nil, current_line_num)
        end
    )
end

--- Opens a confirmation/delete flow for the project under the cursor in the panel.
---@param ctx table Panel context; used to read the current cursor line
function M.handle_project_delete(ctx)
    local current_line_num = ctx
            and ctx.win
            and vim.api.nvim_win_is_valid(ctx.win)
            and vim.api.nvim_win_get_cursor(ctx.win)[1]
        or 1
    local proj_id = common.get_id_at_cursor(cache.project_ids_map)
    local entry_name = ""
    if cache.projects_from_db and cache.projects_from_db[current_line_num] then
        entry_name = cache.projects_from_db[current_line_num].name
    end
    common.delete_entity("project", proj_id, entry_name, nil, function(id, _)
        return delete_project_db(id, nil, current_line_num)
    end)
end

--- Activates the project under the cursor according to the provided mode option.
--- `opts.space_mode` stays in the panel UI; `opts.enter_mode` closes panels and
--- navigates to the deepest available child panel. Defaults to space_mode behaviour.
---@param opts {space_mode: boolean|nil, enter_mode: boolean|nil}|nil Navigation mode flags
function M.handle_project_go(opts)
    local project_id_selected = common.get_id_at_cursor(cache.project_ids_map)
    if not project_id_selected then
        return
    end
    local selected_line_in_ui = cache.ctx
            and cache.ctx.win
            and vim.api.nvim_win_is_valid(cache.ctx.win)
            and vim.api.nvim_win_get_cursor(cache.ctx.win)[1]
        or nil
    if opts and opts.space_mode then
        space_load_project(project_id_selected, selected_line_in_ui)
        return
    end
    if opts and opts.enter_mode then
        enter_navigate_next(project_id_selected)
        return
    end
    if tostring(state.project_id) == tostring(project_id_selected) then
        ui.close_all()
        return
    end
    space_load_project(project_id_selected, selected_line_in_ui)
end

--- Moves the project under the cursor one position up in the sort order.
---@param ctx table Panel context with a valid `win` field
function M.handle_move_up(ctx)
    handle_move_operation(ctx, "up")
end

--- Moves the project under the cursor one position down in the sort order.
---@param ctx table Panel context with a valid `win` field
function M.handle_move_down(ctx)
    handle_move_operation(ctx, "down")
end

--- Closes the current panel and opens the workspaces panel for the active project.
--- Shows an error state if no project is currently active.
function M.navigate_to_workspaces()
    if not state.project_id then
        notify.info(state.lang.PROJECT_NOT_ACTIVE)
        common.open_entity_error("workspace", "PROJECT_NOT_ACTIVE")
        common.setup_error_navigation("PROJECT_NOT_ACTIVE", last_real_win)
        return
    end
    ui.close_all()
    require("lvim-space.ui.workspaces").init(nil, { select_workspace = true })
end

--- Closes the current panel and opens the tabs panel for the active workspace.
--- Shows an error state if no project or workspace is currently active.
function M.navigate_to_tabs()
    if not state.project_id then
        notify.info(state.lang.PROJECT_NOT_ACTIVE)
        common.open_entity_error("tab", "PROJECT_NOT_ACTIVE")
        common.setup_error_navigation("PROJECT_NOT_ACTIVE", last_real_win)
        return
    end
    if not state.workspace_id then
        notify.info(state.lang.WORKSPACE_NOT_ACTIVE)
        common.open_entity_error("tab", "WORKSPACE_NOT_ACTIVE")
        common.setup_error_navigation("WORKSPACE_NOT_ACTIVE", last_real_win)
        return
    end
    ui.close_all()
    require("lvim-space.ui.tabs").init()
end

--- Closes the current panel and opens the files panel for the active tab.
--- Shows an error state if no project, workspace, or active tab exists.
function M.navigate_to_files()
    if not state.project_id then
        notify.info(state.lang.PROJECT_NOT_ACTIVE)
        common.open_entity_error("file", "PROJECT_NOT_ACTIVE")
        common.setup_error_navigation("PROJECT_NOT_ACTIVE", last_real_win)
        return
    end
    if not state.workspace_id then
        notify.info(state.lang.WORKSPACE_NOT_ACTIVE)
        common.open_entity_error("file", "WORKSPACE_NOT_ACTIVE")
        common.setup_error_navigation("WORKSPACE_NOT_ACTIVE", last_real_win)
        return
    end
    if not state.tab_active then
        notify.info(state.lang.TAB_NOT_ACTIVE)
        common.open_entity_error("file", "TAB_NOT_ACTIVE")
        common.setup_error_navigation("TAB_NOT_ACTIVE", last_real_win)
        return
    end
    ui.close_all()
    require("lvim-space.ui.files").init()
end

--- Closes the current panel and opens the search panel for the active tab.
--- Shows an error state if no project, workspace, or active tab exists.
function M.navigate_to_search()
    if not state.project_id then
        notify.info(state.lang.PROJECT_NOT_ACTIVE)
        common.open_entity_error("file", "PROJECT_NOT_ACTIVE")
        common.setup_error_navigation("PROJECT_NOT_ACTIVE", last_real_win)
        return
    end
    if not state.workspace_id then
        notify.info(state.lang.WORKSPACE_NOT_ACTIVE)
        common.open_entity_error("file", "WORKSPACE_NOT_ACTIVE")
        common.setup_error_navigation("WORKSPACE_NOT_ACTIVE", last_real_win)
        return
    end
    if not state.tab_active then
        notify.info(state.lang.TAB_NOT_ACTIVE)
        common.open_entity_error("file", "TAB_NOT_ACTIVE")
        common.setup_error_navigation("TAB_NOT_ACTIVE", last_real_win)
        return
    end
    ui.close_all()
    require("lvim-space.ui.search").init()
end

--- Registers all buffer-local keymaps for the projects panel.
---@param ctx table Panel context containing `buf` and `entities` fields
local function setup_keymaps(ctx)
    local keymap_opts = { buffer = ctx.buf, noremap = true, silent = true, nowait = true }
    vim.keymap.set("n", config.keymappings.action.add, function()
        M.handle_project_add()
    end, keymap_opts)
    vim.keymap.set("n", config.keymappings.action.rename, function()
        if next(ctx.entities) ~= nil then
            M.handle_project_rename(ctx)
        end
    end, keymap_opts)
    vim.keymap.set("n", config.keymappings.action.delete, function()
        if next(ctx.entities) ~= nil then
            M.handle_project_delete(ctx)
        end
    end, keymap_opts)
    vim.keymap.set("n", config.keymappings.action.move_down, function()
        if next(ctx.entities) ~= nil then
            M.handle_move_down(ctx)
        end
    end, keymap_opts)
    vim.keymap.set("n", config.keymappings.action.move_up, function()
        if next(ctx.entities) ~= nil then
            M.handle_move_up(ctx)
        end
    end, keymap_opts)
    vim.keymap.set("n", config.keymappings.action.switch, function()
        if next(ctx.entities) ~= nil then
            M.handle_project_go({ space_mode = true })
        end
    end, keymap_opts)
    vim.keymap.set("n", config.keymappings.action.enter, function()
        if next(ctx.entities) ~= nil then
            M.handle_project_go({ enter_mode = true })
        end
    end, keymap_opts)
    vim.keymap.set("n", config.keymappings.global.workspaces, function()
        if next(ctx.entities) ~= nil then
            M.navigate_to_workspaces()
        end
    end, keymap_opts)
    vim.keymap.set("n", config.keymappings.global.tabs, function()
        if next(ctx.entities) ~= nil then
            M.navigate_to_tabs()
        end
    end, keymap_opts)
    vim.keymap.set("n", config.keymappings.global.files, function()
        if next(ctx.entities) ~= nil then
            M.navigate_to_files()
        end
    end, keymap_opts)
    vim.keymap.set("n", config.keymappings.global.search, function()
        if next(ctx.entities) ~= nil then
            M.navigate_to_search()
        end
    end, keymap_opts)
end

--- Initialises (or re-initialises) the projects panel window.
--- Fetches projects from the database, sorts them, creates the panel via the common
--- module, sets the panel title, and registers keymaps and cursor tracking.
---@param selected_line_num number|nil Visual line to place the cursor on after opening; falls back to last position or active project row
M.init = function(selected_line_num)
    save_window_context()

    cache.projects_from_db = data.find_projects() or {}
    table.sort(cache.projects_from_db, function(a, b)
        local order_a = tonumber(a.sort_order) or math.huge
        local order_b = tonumber(b.sort_order) or math.huge
        if order_a == order_b then
            return (a.name or "") < (b.name or "")
        end
        return order_a < order_b
    end)
    cache.project_ids_map = {}

    local actual_selected_line = selected_line_num
    if not actual_selected_line and cache.last_cursor_position > 1 then
        actual_selected_line = cache.last_cursor_position
    end
    if not actual_selected_line and state.project_id then
        for i, proj in ipairs(cache.projects_from_db) do
            if tostring(proj.id) == tostring(state.project_id) then
                actual_selected_line = i
                break
            end
        end
    end

    local ctx = common.init_entity_list(
        "project",
        cache.projects_from_db,
        cache.project_ids_map,
        M.init,
        state.project_id,
        "id",
        actual_selected_line,
        function(project_entry)
            return string.format("%s [%s]", project_entry.name or "???", project_entry.path or "???")
        end
    )
    if not ctx then
        return
    end
    cache.ctx = ctx

    if ctx.win and vim.api.nvim_win_is_valid(ctx.win) then
        local cursor_pos = vim.api.nvim_win_get_cursor(ctx.win)
        cache.last_cursor_position = cursor_pos[1]

        local win_config = vim.api.nvim_win_get_config(ctx.win)
        win_config.title = " " .. (state.lang.PROJECTS or "Projects") .. " "
        pcall(vim.api.nvim_win_set_config, ctx.win, win_config)
    end

    setup_keymaps(ctx)
    setup_cursor_tracking(ctx)
end

--- Starts the interactive add-project flow: prompts for a path and then a name,
--- validates both inputs, inserts the project into the database, and refreshes the panel.
M.add_project = function()
    M.clear_validation_cache()
    local current_dir = vim.fn.getcwd()
    local project_type_def = get_entity_def()
    ui.create_input_field(state.lang.PROJECT_PATH, current_dir, function(input_project_path)
        if not input_project_path or vim.trim(input_project_path) == "" then
            notify.info(state.lang.OPERATION_CANCELLED)
            return
        end
        local validated_path, path_error_code = validate_project_path(vim.trim(input_project_path), true)
        if not validated_path then
            local error_message_key = path_error_code
            notify.error(state.lang[error_message_key] or ("Invalid project path: " .. path_error_code))
            vim.schedule(function()
                M.add_project()
            end)
            return
        end
        local default_name = vim.fn.fnamemodify(validated_path:gsub("/$", ""), ":t")
        ui.create_input_field(state.lang.PROJECT_NAME, default_name, function(input_project_name)
            if not input_project_name or vim.trim(input_project_name) == "" then
                notify.info(state.lang.OPERATION_CANCELLED)
                return
            end
            local validated_name, name_error_code = validate_project_name_for_add_or_rename(input_project_name, nil)
            if not validated_name then
                local error_message_key_from_def
                if project_type_def and name_error_code then
                    local key_suffix = name_error_code:lower() .. "_error"
                    error_message_key_from_def = project_type_def[key_suffix] or project_type_def.add_failed
                elseif project_type_def then
                    error_message_key_from_def = project_type_def.add_failed
                else
                    error_message_key_from_def = "PROJECT_ADD_FAILED"
                end
                notify.error(
                    state.lang[error_message_key_from_def]
                        or ("Invalid project name: " .. (name_error_code or "unknown error"))
                )
                return
            end
            local _, db_add_error_code = add_project_db(validated_path, validated_name)
            if db_add_error_code then
                notify.error(state.lang[(project_type_def and project_type_def.add_failed) or "PROJECT_ADD_FAILED"])
            else
                notify.info(state.lang.PROJECT_ADDED_SUCCESS or "Project added successfully!")
            end
            M.refresh()
        end)
    end)
end

--- Clears the path-validation result cache so subsequent calls re-validate paths.
M.clear_validation_cache = function()
    cache.validation_cache = {}
end

--- Returns the database record for the currently active project, or nil if none is set.
---@return table|nil project Project record table from the database, or nil
M.get_current_project_info = function()
    if not state.project_id then
        return nil
    end
    return data.find_project_by_id(state.project_id)
end

--- Finds a project by its display name and switches to it using space_mode.
--- Updates `cache.project_ids_map` so the panel selection stays consistent.
---@param project_name string Exact display name of the project to switch to
---@return boolean success true if a matching project was found and activated, false otherwise
M.switch_to_project_by_name = function(project_name)
    local projects = data.find_projects() or {}
    for i, project in ipairs(projects) do
        if project.name == project_name then
            if cache.project_ids_map then
                cache.project_ids_map[i] = project.id
            else
                state.project_id = project.id
            end
            M.handle_project_go({ space_mode = true })
            return true
        end
    end
    return false
end

return M
