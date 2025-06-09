local config = require("lvim-space.config")
local notify = require("lvim-space.api.notify")
local state = require("lvim-space.api.state")
local data = require("lvim-space.api.data")
local ui = require("lvim-space.ui")
local utils = require("lvim-space.utils")
local common = require("lvim-space.ui.common")
local session = require("lvim-space.core.session")
local log = require("lvim-space.api.log")

local M = {}

local cache = {
    project_ids_map = {},
    projects_from_db = {},
    ctx = nil,
    validation_cache = {},
}

local last_real_win = nil

local function get_entity_def()
    return common.get_entity_type("project")
end

local function capture_current_window()
    local current_win = vim.api.nvim_get_current_win()
    if not ui.is_plugin_window(current_win) and vim.api.nvim_win_is_valid(current_win) then
        last_real_win = current_win
        log.debug("projects.capture_current_window: Remembered active window: " .. tostring(last_real_win))
    end
end

local function validate_project_name_for_add_or_rename(project_name, project_id_for_rename)
    local project_type_def = get_entity_def()
    if not project_type_def then
        log.error("validate_project_name_for_add_or_rename: 'project' entity type definition not found.")
        return nil, "UNKNOWN_ENTITY_TYPE"
    end

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

local function validate_project_path(project_path, is_new_project)
    local project_type_def = get_entity_def()
    if not project_type_def then
        log.error("validate_project_path: 'project' entity type definition not found.")
        return nil, "UNKNOWN_ENTITY_TYPE"
    end

    if not project_path or vim.trim(project_path) == "" then
        return nil, "PROJECT_PATH_EMPTY"
    end

    local cache_key = project_path .. tostring(is_new_project)
    if cache.validation_cache[cache_key] then
        log.debug("validate_project_path: Using cached validation for path: " .. project_path)
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
    elseif not utils.has_permission(normalized_path) then
        error_code = "DIRECTORY_NOT_ACCESS"
    elseif is_new_project and data.is_project_path_exist(normalized_path) then
        error_code = "PROJECT_PATH_EXIST"
    end

    cache.validation_cache[cache_key] = {
        path = error_code and nil or normalized_path,
        error = error_code,
    }
    log.debug(
        string.format(
            "validate_project_path: Validation for '%s' (new: %s) -> Path: %s, Error: %s",
            project_path,
            tostring(is_new_project),
            cache.validation_cache[cache_key].path or "nil",
            cache.validation_cache[cache_key].error or "nil"
        )
    )
    return cache.validation_cache[cache_key].path, cache.validation_cache[cache_key].error
end

local function add_project_db(project_path, project_name)
    local row_id = data.add_project(project_path, project_name)
    if not row_id or type(row_id) ~= "number" or row_id <= 0 then
        log.error(
            string.format(
                "add_project_db: Failed to add project '%s' at '%s' to database. DB returned: %s",
                project_name,
                project_path,
                tostring(row_id)
            )
        )
        return nil, "PROJECT_ADD_FAILED"
    end
    log.info(
        string.format(
            "add_project_db: Successfully added project '%s' at '%s' (ID: %s)",
            project_name,
            project_path,
            row_id
        )
    )
    cache.validation_cache = {}
    return row_id, nil
end

local function rename_project_db(project_id_to_rename, new_validated_name, _, selected_line_num)
    local success = data.update_project_name(project_id_to_rename, new_validated_name)
    if not success then
        log.warn("rename_project_db: Failed to rename project ID " .. project_id_to_rename .. " in database.")
        return nil
    end
    log.info(
        string.format("rename_project_db: Project ID %s renamed to '%s'", project_id_to_rename, new_validated_name)
    )
    vim.schedule(function()
        M.init(selected_line_num)
    end)
    return true
end

local function delete_project_db(project_id, _, selected_line_num)
    local success = data.delete_project(project_id)
    if not success then
        log.warn("delete_project_db: Failed to delete project ID " .. project_id .. " from database.")
        return nil
    end
    log.info("delete_project_db: Project ID " .. project_id .. " deleted successfully")
    vim.schedule(function()
        local was_active_project = tostring(state.project_id) == tostring(project_id)
        if was_active_project then
            state.project_id = nil
            state.workspace_id = nil
            state.tab_ids = {}
            state.tab_active = nil
            state.file_active = nil
            session.clear_current_state()
            log.info("delete_project_db: Cleared active state as deleted project was active.")
        end
        M.init(selected_line_num)
    end)
    return true
end

local function update_project_state_in_db()
    if not config.autosave or not state.project_id then
        return
    end
    log.debug("update_project_state_in_db: Attempting to update state for project_id: " .. state.project_id)

    if state.workspace_id then
        log.debug(
            "update_project_state_in_db: Setting workspace_id "
                .. state.workspace_id
                .. " active for project "
                .. state.project_id
        )
        data.set_workspace_active(state.workspace_id, state.project_id)
    end

    if state.workspace_id and state.tab_ids then
        local ws = data.find_workspace_by_id(state.workspace_id, state.project_id)
        if ws then
            local tabs_json_obj = ws.tabs and vim.fn.json_decode(ws.tabs) or {}
            tabs_json_obj.tab_active = state.tab_active
            tabs_json_obj.tab_ids = state.tab_ids
            tabs_json_obj.updated_at = os.time()
            log.debug(
                "update_project_state_in_db: Updating tabs for workspace_id "
                    .. state.workspace_id
                    .. ": "
                    .. vim.inspect(tabs_json_obj)
            )
            data.update_workspace_tabs(vim.fn.json_encode(tabs_json_obj), state.workspace_id)
        else
            log.warn(
                "update_project_state_in_db: Could not find workspace " .. state.workspace_id .. " to update tabs."
            )
        end
    end
end

local function set_active_workspace_for_project(project_id)
    local all_workspaces = data.find_workspaces(project_id) or {}
    local selected_ws = nil

    log.debug("set_active_workspace_for_project: Finding active or first workspace for project_id: " .. project_id)
    for _, ws in ipairs(all_workspaces) do
        if
            tostring(ws.project_id) == tostring(project_id)
            and (ws.active == 1 or ws.active == "1" or ws.active == true)
        then
            selected_ws = ws
            log.debug(
                "set_active_workspace_for_project: Found active workspace: " .. ws.name .. " (ID: " .. ws.id .. ")"
            )
            break
        end
    end
    if not selected_ws and #all_workspaces > 0 then
        selected_ws = all_workspaces[1]
        log.debug(
            "set_active_workspace_for_project: No active workspace found. Selecting first one: "
                .. selected_ws.name
                .. " (ID: "
                .. selected_ws.id
                .. ")"
        )
    end

    if selected_ws then
        state.workspace_id = selected_ws.id
        local tabs_obj = selected_ws.tabs and vim.fn.json_decode(selected_ws.tabs) or {}
        state.tab_active = tabs_obj.tab_active
        state.tab_ids = tabs_obj.tab_ids or {}
        log.debug(
            string.format(
                "set_active_workspace_for_project: Set workspace_id: %s, tab_active: %s, tab_ids count: %d",
                tostring(state.workspace_id),
                tostring(state.tab_active),
                #state.tab_ids
            )
        )
    else
        state.workspace_id = nil
        state.tab_active = nil
        state.tab_ids = {}
        log.debug("set_active_workspace_for_project: No workspace found for project. Clearing workspace state.")
    end

    update_project_state_in_db()
end

local function space_load_project(project_id, selected_line_in_ui)
    local selected_project = data.find_project_by_id(project_id)
    if not selected_project then
        notify.error(state.lang.PROJECT_NOT_FOUND)
        return
    end
    log.info("space_load_project: Loading project: " .. selected_project.name .. " (ID: " .. project_id .. ")")

    local path_to_check = selected_project.path
    if vim.fn.isdirectory(path_to_check) ~= 1 then
        notify.error(state.lang.DIRECTORY_NOT_FOUND .. ": " .. path_to_check)
        return
    end
    if not utils.has_permission(path_to_check) then
        notify.error(state.lang.DIRECTORY_NOT_ACCESS .. ": " .. path_to_check)
        return
    end

    if state.tab_active then
        log.debug("space_load_project: Saving current session for tab_id: " .. state.tab_active)
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
    log.info("space_load_project: Changed current directory to: " .. path_to_check)

    state.project_id = project_id
    set_active_workspace_for_project(project_id)

    local augroup_name = "LvimSpaceCursorBlend"
    local space_restore_augroup = vim.api.nvim_create_augroup("LvimSpaceProjectRestore", { clear = true })
    vim.api.nvim_clear_autocmds({ group = augroup_name })

    local function final_ui_update_and_notify()
        M.init(selected_line_in_ui)
        local cursor_blend_augroup = vim.api.nvim_create_augroup(augroup_name, { clear = true })
        if state.ui and state.ui.content and vim.api.nvim_win_is_valid(state.ui.content.win) then
            vim.cmd("hi Cursor blend=100")
            local main_ui_win = state.ui.content.win
            vim.api.nvim_create_autocmd({ "WinLeave", "WinEnter" }, {
                group = cursor_blend_augroup,
                callback = function()
                    local current_event_win = vim.api.nvim_get_current_win()
                    local blend_value = current_event_win == main_ui_win and 100 or 0
                    vim.cmd("hi Cursor blend=" .. blend_value)
                end,
            })
            vim.api.nvim_set_current_win(main_ui_win)
            if selected_line_in_ui then
                pcall(vim.api.nvim_win_set_cursor, main_ui_win, { selected_line_in_ui, 0 })
            end
        end
        state.disable_auto_close = old_disable_auto_close
        notify.info(state.lang.PROJECT_SWITCHED_TO .. selected_project.name)
        log.info("space_load_project: Project switch to '" .. selected_project.name .. "' completed.")
    end

    if state.workspace_id and state.tab_active then
        log.debug("space_load_project: Restoring session for tab_id: " .. state.tab_active)
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
        log.debug("space_load_project: No active workspace/tab to restore. Clearing current state and updating UI.")
        session.clear_current_state()
        vim.schedule(final_ui_update_and_notify)
    end
end

local function enter_navigate_next(project_id)
    local selected_project = data.find_project_by_id(project_id)
    if not selected_project then
        notify.error(state.lang.PROJECT_NOT_FOUND)
        return
    end
    log.info("enter_navigate_next: Entering project: " .. selected_project.name .. " (ID: " .. project_id .. ")")

    local path_to_check = selected_project.path
    if vim.fn.isdirectory(path_to_check) ~= 1 then
        notify.error(state.lang.DIRECTORY_NOT_FOUND .. ": " .. path_to_check)
        return
    end
    if not utils.has_permission(path_to_check) then
        notify.error(state.lang.DIRECTORY_NOT_ACCESS .. ": " .. path_to_check)
        return
    end

    if state.tab_active then
        log.debug("enter_navigate_next: Saving current session for tab_id: " .. state.tab_active)
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
    log.info("enter_navigate_next: Changed current directory to: " .. path_to_check)

    state.project_id = project_id
    set_active_workspace_for_project(project_id)

    state.disable_auto_close = true
    ui.close_all()
    notify.info(state.lang.PROJECT_SWITCHED_TO .. selected_project.name)

    vim.schedule(function()
        local target_init_func
        local next_panel_log_msg
        if state.workspace_id and state.tab_active then
            log.debug(
                "enter_navigate_next: Restoring session for tab_id: "
                    .. state.tab_active
                    .. " and navigating to files panel."
            )
            session.restore_state(state.tab_active, true)
            target_init_func = require("lvim-space.ui.files").init
            next_panel_log_msg = "files panel"
        elseif state.workspace_id then
            target_init_func = require("lvim-space.ui.tabs").init
            next_panel_log_msg = "tabs panel"
        else
            target_init_func = function()
                require("lvim-space.ui.workspaces").init(nil, { select_workspace = false })
            end
            next_panel_log_msg = "workspaces panel (no active workspace)"
        end

        vim.defer_fn(function()
            log.info("enter_navigate_next: Navigating to " .. next_panel_log_msg)
            state.disable_auto_close = false
            if target_init_func then
                target_init_func()
            end
        end, 50)
    end)
end

local function handle_move_operation(ctx, direction)
    if not ctx or not ctx.win or not vim.api.nvim_win_is_valid(ctx.win) then
        log.warn("projects.handle_move_operation: Invalid UI context or window.")
        return
    end

    local current_visual_line = vim.api.nvim_win_get_cursor(ctx.win)[1]
    local project_id_to_move = cache.project_ids_map[current_visual_line]

    if not project_id_to_move then
        log.warn(
            "projects.handle_move_operation: Could not determine project at current line ("
                .. current_visual_line
                .. ")."
        )
        return
    end

    local project_to_move_data = cache.projects_from_db[current_visual_line]
    local project_type_def = get_entity_def()

    if not project_type_def then
        log.error("projects.handle_move_operation: 'project' entity type definition not found in common.lua.")
        notify.error(state.lang.PROJECT_REORDER_FAILED)
        return
    end

    if not project_to_move_data or tostring(project_to_move_data.id) ~= tostring(project_id_to_move) then
        log.error(
            string.format(
                "projects.handle_move_operation: Cache inconsistency for line %d. ID from map: %s, ID from data: %s, Name from data: %s",
                current_visual_line,
                tostring(project_id_to_move),
                project_to_move_data and tostring(project_to_move_data.id) or "nil",
                project_to_move_data and project_to_move_data.name or "nil"
            )
        )
        notify.error(state.lang[project_type_def.ui_cache_error])
        return
    end

    local current_sort_order = tonumber(project_to_move_data.sort_order)
    if not current_sort_order then
        log.error(
            "projects.handle_move_operation: project_to_move_data.sort_order is not a number: "
                .. tostring(project_to_move_data.sort_order)
        )
        notify.error(state.lang[project_type_def.reorder_failed_error])
        return
    end

    if direction == "up" and current_sort_order <= 1 then
        notify.info(state.lang.PROJECT_ALREADY_AT_TOP)
        return
    elseif direction == "down" and current_sort_order >= #cache.projects_from_db then
        notify.info(state.lang.PROJECT_ALREADY_AT_BOTTOM)
        return
    end

    local target_sort_order = direction == "up" and (current_sort_order - 1) or (current_sort_order + 1)
    local new_order_table = {}

    for _, proj_entry in ipairs(cache.projects_from_db) do
        local entry_sort_order = tonumber(proj_entry.sort_order)
        if not entry_sort_order then
            log.warn(
                "projects.handle_move_operation: Found project with invalid sort_order in cache: ID "
                    .. proj_entry.id
                    .. ", sort_order: "
                    .. tostring(proj_entry.sort_order)
            )
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

    log.debug("projects.handle_move_operation: Reordering projects with table: " .. vim.inspect(new_order_table))
    local success, err_msg_code = data.reorder_projects(new_order_table)

    if success then
        log.info(
            string.format(
                "Project ID %s ('%s') moved %s from sort_order %d to %d.",
                project_id_to_move,
                project_to_move_data.name,
                direction,
                current_sort_order,
                target_sort_order
            )
        )
        local new_line = direction == "up" and (current_visual_line - 1) or (current_visual_line + 1)
        M.init(new_line)
    else
        log.error(
            string.format("projects.handle_move_operation: Error reordering projects. Code: %s", tostring(err_msg_code))
        )
        local err_key_to_use = project_type_def.reorder_failed_error
        if err_msg_code == "PROJECT_REORDER_MISSING_PARAMS" then
            err_key_to_use = project_type_def.reorder_missing_params_error
        end
        notify.error(state.lang[err_key_to_use])
        M.init(current_visual_line)
    end
end

function M.handle_project_add()
    M.add_project()
end

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
    else
        log.warn(
            "handle_project_rename: Could not find project data in cache for line: "
                .. current_line_num
                .. ". Using empty current_name."
        )
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
    else
        log.warn("handle_project_delete: Could not find project data in cache for line: " .. current_line_num)
    end

    common.delete_entity("project", proj_id, entry_name, nil, function(id, _)
        return delete_project_db(id, nil, current_line_num)
    end)
end

function M.handle_project_switch(opts)
    local project_id_selected = common.get_id_at_cursor(cache.project_ids_map)
    if not project_id_selected then
        log.warn("projects.handle_project_switch: No project selected from list (ID at cursor is nil).")
        return
    end
    local selected_line_in_ui = cache.ctx
            and cache.ctx.win
            and vim.api.nvim_win_is_valid(cache.ctx.win)
            and vim.api.nvim_win_get_cursor(cache.ctx.win)[1]
        or nil

    log.debug(
        string.format(
            "projects.handle_project_switch: Selected project ID: %s, UI line: %s, space_mode: %s, enter_mode: %s",
            tostring(project_id_selected),
            tostring(selected_line_in_ui),
            tostring(opts and opts.space_mode),
            tostring(opts and opts.enter_mode)
        )
    )

    if opts and opts.space_mode then
        space_load_project(project_id_selected, selected_line_in_ui)
        return
    end
    if opts and opts.enter_mode then
        enter_navigate_next(project_id_selected)
        return
    end
    if tostring(state.project_id) == tostring(project_id_selected) then
        log.info(
            "projects.handle_project_switch: Already in project ID: "
                .. tostring(project_id_selected)
                .. ". Closing UI."
        )
        ui.close_all()
        return
    end
    space_load_project(project_id_selected, selected_line_in_ui)
end

function M.handle_move_up(ctx)
    handle_move_operation(ctx, "up")
end

function M.handle_move_down(ctx)
    handle_move_operation(ctx, "down")
end

function M.navigate_to_workspaces()
    capture_current_window()
    if not state.project_id then
        notify.info(state.lang.PROJECT_NOT_ACTIVE)
        common.open_entity_error("workspace", "PROJECT_NOT_ACTIVE")
        common.setup_error_navigation("PROJECT_NOT_ACTIVE", last_real_win)
        return
    end
    ui.close_all()
    require("lvim-space.ui.workspaces").init(nil, { select_workspace = true })
end

function M.navigate_to_tabs()
    capture_current_window()
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

function M.navigate_to_files()
    capture_current_window()
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

local function setup_keymaps(ctx)
    local keymap_opts = { buffer = ctx.buf, noremap = true, silent = true, nowait = true }

    vim.keymap.set("n", config.keymappings.action.add, M.handle_project_add, keymap_opts)
    vim.keymap.set("n", config.keymappings.action.rename, function()
        M.handle_project_rename(ctx)
    end, keymap_opts)
    vim.keymap.set("n", config.keymappings.action.delete, function()
        M.handle_project_delete(ctx)
    end, keymap_opts)

    if config.keymappings.action.move_down then
        vim.keymap.set("n", config.keymappings.action.move_down, function()
            M.handle_move_down(ctx)
        end, keymap_opts)
    end
    if config.keymappings.action.move_up then
        vim.keymap.set("n", config.keymappings.action.move_up, function()
            M.handle_move_up(ctx)
        end, keymap_opts)
    end

    vim.keymap.set("n", config.keymappings.action.switch, function()
        M.handle_project_switch({ space_mode = true })
    end, keymap_opts)
    vim.keymap.set("n", "<CR>", function()
        M.handle_project_switch({ enter_mode = true })
    end, keymap_opts)

    if state.project_id then
        vim.keymap.set("n", config.keymappings.global.workspaces, M.navigate_to_workspaces, keymap_opts)
        vim.keymap.set("n", config.keymappings.global.tabs, M.navigate_to_tabs, keymap_opts)
        vim.keymap.set("n", config.keymappings.global.files, M.navigate_to_files, keymap_opts)
    else
        pcall(vim.keymap.del, "n", config.keymappings.global.workspaces, { buffer = ctx.buf })
        pcall(vim.keymap.del, "n", config.keymappings.global.tabs, { buffer = ctx.buf })
        pcall(vim.keymap.del, "n", config.keymappings.global.files, { buffer = ctx.buf })
    end
end

M.init = function(selected_line_num)
    capture_current_window()
    log.debug("projects.M.init: Initializing projects list. Selected line hint: " .. tostring(selected_line_num))

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
    if not actual_selected_line and state.project_id then
        for i, proj in ipairs(cache.projects_from_db) do
            if tostring(proj.id) == tostring(state.project_id) then
                actual_selected_line = i
                log.debug("projects.M.init: Found active project ID " .. state.project_id .. " at line " .. i)
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
        log.error("projects.M.init: common.init_entity_list returned no context. UI creation likely failed.")
        return
    end

    cache.ctx = ctx
    if ctx.win and vim.api.nvim_win_is_valid(ctx.win) then
        local win_config = vim.api.nvim_win_get_config(ctx.win)
        win_config.title = " " .. state.lang.PROJECTS .. " "
        pcall(vim.api.nvim_win_set_config, ctx.win, win_config)
    end

    setup_keymaps(ctx)
    log.debug("projects.M.init: Projects list initialized successfully.")
end

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
            M.init()
        end)
    end)
end

M.clear_validation_cache = function()
    log.debug("projects.clear_validation_cache: Clearing path validation cache.")
    cache.validation_cache = {}
end

M.get_current_project_info = function()
    if not state.project_id then
        return nil
    end
    return data.find_project_by_id(state.project_id)
end

M.switch_to_project_by_name = function(project_name)
    log.debug("projects.switch_to_project_by_name: Attempting to switch to project by name: " .. project_name)
    local projects = data.find_projects() or {}
    for i, project in ipairs(projects) do
        if project.name == project_name then
            log.debug(
                "projects.switch_to_project_by_name: Found project '"
                    .. project_name
                    .. "' at index "
                    .. i
                    .. " with ID "
                    .. project.id
            )
            if cache.project_ids_map then
                cache.project_ids_map[i] = project.id
            else
                log.warn(
                    "projects.switch_to_project_by_name: cache.project_ids_map is nil. Simulating selection via state."
                )
                state.project_id = project.id
            end
            M.handle_project_switch({ space_mode = true })
            return true
        end
    end
    log.warn("projects.switch_to_project_by_name: Project with name '" .. project_name .. "' not found.")
    return false
end

return M
