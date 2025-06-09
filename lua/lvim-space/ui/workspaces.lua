local config = require("lvim-space.config")
local notify = require("lvim-space.api.notify")
local state = require("lvim-space.api.state")
local data = require("lvim-space.api.data")
local ui = require("lvim-space.ui")
local utils = require("lvim-space.utils")
local common = require("lvim-space.ui.common")
local session = require("lvim-space.core.session")
local tabs_ui_module = require("lvim-space.ui.tabs")
local files_ui_module = require("lvim-space.ui.files")
local log = require("lvim-space.api.log")

local M = {}

local cache = {
    workspace_ids_map = {},
    workspaces_from_db = {},
    ctx = nil,
    project_display_name = "",
}

local last_real_win = nil

local function get_entity_def()
    return common.get_entity_type("workspace")
end

local function get_project_def()
    return common.get_entity_type("project")
end

local function create_empty_workspace_tabs()
    return { tab_ids = {}, tab_active = nil, created_at = os.time(), updated_at = os.time() }
end

local function capture_current_window()
    local current_win = vim.api.nvim_get_current_win()
    if not ui.is_plugin_window(current_win) and vim.api.nvim_win_is_valid(current_win) then
        last_real_win = current_win
        log.debug("workspaces.capture_current_window: Remembered active window: " .. tostring(last_real_win))
    end
end

local function validate_workspace_name_for_add_or_rename(workspace_name, project_id_context, workspace_id_for_rename)
    local ok, err_code = common.validate_entity_name("workspace", workspace_name)
    if not ok then
        return nil, err_code
    end

    local trimmed_name = vim.trim(workspace_name)
    local existing_workspace = data.is_workspace_name_exist(trimmed_name, project_id_context)

    if existing_workspace then
        if workspace_id_for_rename and tostring(existing_workspace.id) == tostring(workspace_id_for_rename) then
            return trimmed_name, nil
        else
            return nil, "EXIST_NAME"
        end
    end
    return trimmed_name, nil
end

local function update_workspace_state_in_db()
    if not config.autosave or not state.project_id then
        log.debug("update_workspace_state_in_db: Autosave disabled or no project_id. Skipping.")
        return
    end
    log.debug(
        "update_workspace_state_in_db: Attempting to update state for project_id: "
            .. state.project_id
            .. ", workspace_id: "
            .. (state.workspace_id or "nil")
    )

    if state.workspace_id then
        data.set_workspace_active(state.workspace_id, state.project_id)
        local ws = data.find_workspace_by_id(state.workspace_id, state.project_id)
        if ws then
            local tabs_json_obj = ws.tabs and vim.fn.json_decode(ws.tabs) or create_empty_workspace_tabs()
            tabs_json_obj.tab_active = state.tab_active
            tabs_json_obj.tab_ids = state.tab_ids or {}
            tabs_json_obj.updated_at = os.time()
            log.debug(
                "update_workspace_state_in_db: Updating tabs for workspace_id "
                    .. state.workspace_id
                    .. ": "
                    .. vim.inspect(tabs_json_obj)
            )
            data.update_workspace_tabs(vim.fn.json_encode(tabs_json_obj), state.workspace_id)
        else
            log.warn(
                "update_workspace_state_in_db: Could not find workspace "
                    .. state.workspace_id
                    .. " for project "
                    .. state.project_id
                    .. " to update tabs."
            )
        end
    else
        log.debug(
            "update_workspace_state_in_db: No active workspace_id. Ensuring all workspaces for project "
                .. state.project_id
                .. " are inactive."
        )
        data.set_workspaces_inactive(state.project_id)
    end
end

local function add_workspace_db(workspace_name, project_id)
    local ws_def = get_entity_def()
    local initial_tabs_structure = create_empty_workspace_tabs()
    local initial_tabs_json = vim.fn.json_encode(initial_tabs_structure)
    local result = data.add_workspace(workspace_name, initial_tabs_json, project_id)

    if type(result) == "number" and result > 0 then
        log.info(
            string.format(
                "add_workspace_db: Workspace '%s' added to project %s with ID %d",
                workspace_name,
                project_id,
                result
            )
        )
        vim.schedule(function()
            M.init()
        end)
        return result
    elseif type(result) == "string" then
        log.warn(
            string.format(
                "add_workspace_db: Failed to add workspace '%s' to project %s. Error code: %s",
                workspace_name,
                project_id,
                result
            )
        )
        return result
    else
        log.error(
            string.format(
                "add_workspace_db: Failed to add workspace '%s' to project %s. Unknown error. DB returned: %s",
                workspace_name,
                project_id,
                tostring(result)
            )
        )
        return (ws_def and ws_def.add_failed) or "WORKSPACE_ADD_FAILED"
    end
end

local function rename_workspace_db(workspace_id, new_validated_name, project_id, selected_line_num)
    local status = data.update_workspace_name(workspace_id, new_validated_name, project_id)
    if status == true then
        if config.autosave then
            update_workspace_state_in_db()
        end
        vim.schedule(function()
            M.init(selected_line_num)
        end)
        return true
    elseif type(status) == "string" then
        return status
    end
    return false
end

local function delete_workspace_db(workspace_id, project_id, selected_line_num)
    local status = data.delete_workspace(workspace_id, project_id)
    if not status then
        return nil
    end
    vim.schedule(function()
        local was_active_workspace = tostring(state.workspace_id) == tostring(workspace_id)
        if was_active_workspace then
            state.workspace_id = nil
            state.tab_ids = {}
            state.tab_active = nil
            state.file_active = nil
            session.clear_current_state()
            log.info("delete_workspace_db: Cleared active state as deleted workspace was active.")
        end
        if config.autosave then
            update_workspace_state_in_db()
        end
        M.init(selected_line_num)
    end)
    return true
end

local function space_load_session(workspace_id, selected_line_in_ui)
    if not cache.ctx or not cache.ctx.buf or not vim.api.nvim_buf_is_valid(cache.ctx.buf) then
        log.warn("space_load_session: UI context or buffer is invalid. Aborting.")
        return
    end
    log.info(
        "space_load_session: Loading session for workspace_id: "
            .. workspace_id
            .. " in project_id: "
            .. state.project_id
    )
    state.workspace_id = workspace_id
    local workspace = data.find_workspace_by_id(workspace_id, state.project_id)
    local workspace_tabs_obj = workspace and workspace.tabs and vim.fn.json_decode(workspace.tabs)
        or create_empty_workspace_tabs()

    state.tab_ids = workspace_tabs_obj.tab_ids or {}
    state.tab_active = workspace_tabs_obj.tab_active
    log.debug(
        string.format(
            "space_load_session: Set tab_ids count: %d, tab_active: %s",
            #state.tab_ids,
            tostring(state.tab_active)
        )
    )

    if config.autosave then
        update_workspace_state_in_db()
    end

    if not state.tab_active then
        log.info("space_load_session: No active tab in workspace. Re-initializing workspace UI.")
        local ws_def = get_entity_def()
        local switched_to_msg = (ws_def and ws_def.switched_to and state.lang[ws_def.switched_to])
            or "Switched to workspace: "
        local ws_name = workspace and workspace.name or "Unknown Workspace"
        notify.info(switched_to_msg .. ws_name)
        M.init(selected_line_in_ui)
        return
    end

    local old_disable_auto_close = state.disable_auto_close
    state.disable_auto_close = true
    local augroup_name = "LvimSpaceCursorBlend"
    local space_restore_augroup = vim.api.nvim_create_augroup("LvimSpaceWorkspaceRestore", { clear = true })
    vim.api.nvim_clear_autocmds({ group = augroup_name })

    vim.api.nvim_create_autocmd({ "BufEnter", "WinEnter" }, {
        group = space_restore_augroup,
        callback = function()
            vim.api.nvim_clear_autocmds({ group = space_restore_augroup })
            vim.schedule(function()
                local ws_def = get_entity_def()
                local switched_to_msg = (ws_def and ws_def.switched_to and state.lang[ws_def.switched_to])
                    or "Switched to workspace: "
                local ws_name_for_notify = (workspace and workspace.name) or "Selected Workspace"
                notify.info(switched_to_msg .. ws_name_for_notify)

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
                log.info("space_load_session: Session restored and workspace UI updated.")
            end)
        end,
        once = true,
    })
    log.debug("space_load_session: Restoring state for tab_id: " .. state.tab_active)
    session.restore_state(state.tab_active, true)
end

local function enter_navigate_to_last_panel(workspace_id)
    log.info("enter_navigate_to_last_panel: Entering workspace_id: " .. workspace_id)
    state.workspace_id = workspace_id
    local workspace = data.find_workspace_by_id(workspace_id, state.project_id)
    local workspace_tabs_obj = workspace and workspace.tabs and vim.fn.json_decode(workspace.tabs)
        or create_empty_workspace_tabs()

    state.tab_ids = workspace_tabs_obj.tab_ids or {}
    state.tab_active = workspace_tabs_obj.tab_active
    log.debug(
        string.format(
            "enter_navigate_to_last_panel: Set tab_ids count: %d, tab_active: %s",
            #state.tab_ids,
            tostring(state.tab_active)
        )
    )

    if config.autosave then
        update_workspace_state_in_db()
    end

    ui.close_all()
    local ws_def = get_entity_def()
    local switched_to_msg = (ws_def and ws_def.switched_to and state.lang[ws_def.switched_to])
        or "Switched to workspace: "
    local ws_name_for_notify = (workspace and workspace.name) or "Selected Workspace"
    notify.info(switched_to_msg .. ws_name_for_notify)

    if state.tab_active then
        log.debug("enter_navigate_to_last_panel: Active tab found. Restoring session and navigating to files panel.")
        session.restore_state(state.tab_active, true)
        vim.schedule(function()
            files_ui_module.init()
        end)
    else
        log.debug("enter_navigate_to_last_panel: No active tab. Navigating to tabs panel.")
        vim.schedule(function()
            tabs_ui_module.init()
        end)
    end
end

local function handle_move_operation(ctx, direction)
    if not ctx or not ctx.win or not vim.api.nvim_win_is_valid(ctx.win) then
        log.warn("workspaces.handle_move_operation: Invalid UI context or window.")
        return
    end

    local current_visual_line = vim.api.nvim_win_get_cursor(ctx.win)[1]
    local workspace_id_to_move = cache.workspace_ids_map[current_visual_line]

    if not workspace_id_to_move then
        log.warn(
            "workspaces.handle_move_operation: Could not determine workspace at current line ("
                .. current_visual_line
                .. ")."
        )
        return
    end

    local workspace_to_move_data = nil
    for _, ws_entry in ipairs(cache.workspaces_from_db) do
        if tostring(ws_entry.id) == tostring(workspace_id_to_move) then
            workspace_to_move_data = ws_entry
            break
        end
    end

    local ws_def = get_entity_def()

    if not ws_def then
        log.error("workspaces.handle_move_operation: 'workspace' entity type definition not found.")
        notify.error(state.lang.WORKSPACE_REORDER_FAILED or "Failed to reorder workspace.")
        return
    end

    if not workspace_to_move_data then
        log.error(
            string.format(
                "workspaces.handle_move_operation: Cache inconsistency for line %d. ID from map: %s. Data for this ID not found in cache.",
                current_visual_line,
                tostring(workspace_id_to_move)
            )
        )
        notify.error(state.lang[ws_def.ui_cache_error] or "UI data inconsistency.")
        return
    end

    local current_sort_order = tonumber(workspace_to_move_data.sort_order)
    if not current_sort_order then
        log.error(
            "workspaces.handle_move_operation: workspace_to_move_data.sort_order is not a number: "
                .. tostring(workspace_to_move_data.sort_order)
        )
        notify.error(state.lang[ws_def.reorder_failed_error] or "Failed to reorder workspace.")
        return
    end

    if direction == "up" and current_sort_order <= 1 then
        notify.info(state.lang[ws_def.already_at_top] or "Workspace is already at the top.")
        return
    elseif direction == "down" and current_sort_order >= #cache.workspaces_from_db then
        notify.info(state.lang[ws_def.already_at_bottom] or "Workspace is already at the bottom.")
        return
    end

    local target_sort_order = direction == "up" and (current_sort_order - 1) or (current_sort_order + 1)
    local new_order_table = {}

    for _, ws_entry in ipairs(cache.workspaces_from_db) do
        local entry_sort_order = tonumber(ws_entry.sort_order)
        if not entry_sort_order then
            log.warn(
                "workspaces.handle_move_operation: Found workspace with invalid sort_order in cache: ID "
                    .. ws_entry.id
                    .. ", sort_order: "
                    .. tostring(ws_entry.sort_order)
            )
            goto continue_ws_loop
        end

        local new_order_for_this_item = entry_sort_order
        if ws_entry.id == workspace_id_to_move then
            new_order_for_this_item = target_sort_order
        elseif entry_sort_order == target_sort_order then
            new_order_for_this_item = current_sort_order
        end
        table.insert(new_order_table, { id = ws_entry.id, order = new_order_for_this_item })
        ::continue_ws_loop::
    end

    local success, err_msg_code = data.reorder_workspaces(state.project_id, new_order_table)

    if success then
        log.info(
            string.format(
                "Workspace ID %s ('%s') moved %s from sort_order %d to %d in project %s.",
                workspace_id_to_move,
                workspace_to_move_data.name,
                direction,
                current_sort_order,
                target_sort_order,
                state.project_id
            )
        )
        local new_line = direction == "up" and (current_visual_line - 1) or (current_visual_line + 1)
        M.init(new_line)
    else
        log.error(
            string.format(
                "workspaces.handle_move_operation: Error reordering workspace ID %s in project %s: Code: %s",
                workspace_id_to_move,
                state.project_id,
                tostring(err_msg_code)
            )
        )
        local err_key_to_use = (ws_def and ws_def.reorder_failed_error) or "WORKSPACE_REORDER_FAILED"
        if err_msg_code == "WORKSPACE_REORDER_MISSING_PARAMS" then
            err_key_to_use = (ws_def and ws_def.reorder_missing_params_error) or "WORKSPACE_REORDER_MISSING_PARAMS"
        end
        notify.error(state.lang[err_key_to_use] or "Failed to reorder workspace.")
        M.init(current_visual_line)
    end
end

function M.handle_workspace_add()
    local ws_def = get_entity_def()
    if not ws_def then
        log.error("handle_workspace_add: 'workspace' entity type definition not found.")
        notify.error("An unexpected error occurred while trying to add a workspace.")
        return
    end

    local default_name = "Workspace " .. tostring(#(data.find_workspaces(state.project_id) or {}) + 1)
    ui.create_input_field(state.lang.WORKSPACE_NAME or "Workspace Name:", default_name, function(input_workspace_name)
        if not input_workspace_name or vim.trim(input_workspace_name) == "" then
            notify.info(state.lang.OPERATION_CANCELLED or "Operation cancelled.")
            return
        end
        local trimmed_name = vim.trim(input_workspace_name)
        local validated_name, err_code = validate_workspace_name_for_add_or_rename(trimmed_name, state.project_id, nil)
        if not validated_name then
            local err_key_from_def
            if err_code == "LEN_NAME" then
                err_key_from_def = ws_def.name_len_error
            elseif err_code == "EXIST_NAME" then
                err_key_from_def = ws_def.name_exist_error
            else
                err_key_from_def = ws_def.add_failed
            end
            notify.error(state.lang[err_key_from_def] or ("Invalid workspace name: " .. (err_code or "unknown error")))
            return
        end

        local result_or_err_code = add_workspace_db(validated_name, state.project_id)
        if type(result_or_err_code) == "number" and result_or_err_code > 0 then
            notify.info(state.lang[ws_def.added_success] or "Workspace added successfully!")
        else
            local err_key_to_use = ws_def.add_failed
            if type(result_or_err_code) == "string" then
                if result_or_err_code == "EXIST_NAME" then
                    err_key_to_use = ws_def.name_exist_error
                elseif state.lang[result_or_err_code] then
                    err_key_to_use = result_or_err_code
                end
            end
            notify.error(state.lang[err_key_to_use] or "Failed to add workspace.")
        end
    end)
end

function M.handle_workspace_rename(ctx)
    local current_line_num = ctx
            and ctx.win
            and vim.api.nvim_win_is_valid(ctx.win)
            and vim.api.nvim_win_get_cursor(ctx.win)[1]
        or 1
    local workspace_id_to_rename = common.get_id_at_cursor(cache.workspace_ids_map)
    local current_name = ""
    if cache.workspaces_from_db then
        for _, ws_entry in ipairs(cache.workspaces_from_db) do
            if tostring(ws_entry.id) == tostring(workspace_id_to_rename) then
                current_name = ws_entry.name
                break
            end
        end
    end
    if not workspace_id_to_rename then
        log.warn("handle_workspace_rename: No workspace ID found at cursor line " .. current_line_num)
        return
    end

    common.rename_entity(
        "workspace",
        workspace_id_to_rename,
        current_name,
        state.project_id,
        function(id, new_name_from_input, project_id_context)
            local validated_name, err_code =
                validate_workspace_name_for_add_or_rename(new_name_from_input, project_id_context, id)
            if not validated_name then
                return err_code
            end
            return rename_workspace_db(id, validated_name, project_id_context, current_line_num)
        end
    )
end

function M.handle_workspace_delete(ctx)
    local current_line_num = ctx
            and ctx.win
            and vim.api.nvim_win_is_valid(ctx.win)
            and vim.api.nvim_win_get_cursor(ctx.win)[1]
        or 1
    local ws_id_to_delete = common.get_id_at_cursor(cache.workspace_ids_map)
    local entry_name = ""
    if cache.workspaces_from_db then
        for _, ws_entry in ipairs(cache.workspaces_from_db) do
            if tostring(ws_entry.id) == tostring(ws_id_to_delete) then
                entry_name = ws_entry.name
                break
            end
        end
    end
    if not ws_id_to_delete then
        log.warn("handle_workspace_delete: No workspace ID found at cursor line " .. current_line_num)
        return
    end

    common.delete_entity("workspace", ws_id_to_delete, entry_name, state.project_id, function(del_id, proj_id)
        return delete_workspace_db(del_id, proj_id, current_line_num)
    end)
end

function M.handle_workspace_switch(opts)
    local ws_def = get_entity_def()
    local workspace_id_selected = common.get_id_at_cursor(cache.workspace_ids_map)
    if not workspace_id_selected then
        log.warn("handle_workspace_switch: No workspace selected (ID at cursor is nil).")
        return
    end
    local selected_line_in_ui = cache.ctx
            and cache.ctx.win
            and vim.api.nvim_win_is_valid(cache.ctx.win)
            and vim.api.nvim_win_get_cursor(cache.ctx.win)[1]
        or nil
    log.debug(
        string.format(
            "handle_workspace_switch: Selected workspace ID: %s, UI line: %s, space_mode: %s, enter_mode: %s",
            tostring(workspace_id_selected),
            tostring(selected_line_in_ui),
            tostring(opts and opts.space_mode),
            tostring(opts and opts.enter_mode)
        )
    )

    if opts and opts.space_mode then
        space_load_session(workspace_id_selected, selected_line_in_ui)
        return
    end
    if opts and opts.enter_mode then
        enter_navigate_to_last_panel(workspace_id_selected)
        return
    end

    state.workspace_id = workspace_id_selected
    local workspace = data.find_workspace_by_id(state.workspace_id, state.project_id)
    local workspace_tabs_obj = workspace and workspace.tabs and vim.fn.json_decode(workspace.tabs)
        or create_empty_workspace_tabs()
    state.tab_ids = workspace_tabs_obj.tab_ids or {}
    state.tab_active = workspace_tabs_obj.tab_active
    log.debug(
        string.format(
            "handle_workspace_switch (standard): Set tab_ids count: %d, tab_active: %s",
            #state.tab_ids,
            tostring(state.tab_active)
        )
    )

    if config.autosave then
        update_workspace_state_in_db()
    end

    local switched_to_msg = (ws_def and ws_def.switched_to and state.lang[ws_def.switched_to])
        or "Switched to workspace: "
    local ws_name_for_notify = (workspace and workspace.name) or "Selected Workspace"
    notify.info(switched_to_msg .. ws_name_for_notify)

    if opts and opts.close_panel then
        ui.close_all()
    end
    tabs_ui_module.init()
end

function M.handle_move_up(ctx)
    handle_move_operation(ctx, "up")
end

function M.handle_move_down(ctx)
    handle_move_operation(ctx, "down")
end

function M.navigate_to_projects()
    capture_current_window()
    ui.close_all()
    require("lvim-space.ui.projects").init()
end

function M.navigate_to_tabs()
    capture_current_window()
    local project_def = get_project_def()
    local ws_def = get_entity_def()

    if not state.project_id then
        notify.info(
            state.lang[(project_def and project_def.not_active) or "PROJECT_NOT_ACTIVE"] or "Project not active."
        )
        common.open_entity_error("tab", (project_def and project_def.not_active) or "PROJECT_NOT_ACTIVE")
        common.setup_error_navigation((project_def and project_def.not_active) or "PROJECT_NOT_ACTIVE", last_real_win)
        return
    end
    if not state.workspace_id then
        notify.info(state.lang[(ws_def and ws_def.not_active) or "WORKSPACE_NOT_ACTIVE"] or "Workspace not active.")
        common.open_entity_error("tab", (ws_def and ws_def.not_active) or "WORKSPACE_NOT_ACTIVE")
        common.setup_error_navigation((ws_def and ws_def.not_active) or "WORKSPACE_NOT_ACTIVE", last_real_win)
        return
    end
    ui.close_all()
    tabs_ui_module.init()
end

function M.navigate_to_files()
    capture_current_window()
    local project_def = get_project_def()
    local ws_def = get_entity_def()
    local tab_def = common.get_entity_type("tab")

    if not state.project_id then
        notify.info(
            state.lang[(project_def and project_def.not_active) or "PROJECT_NOT_ACTIVE"] or "Project not active."
        )
        common.open_entity_error("file", (project_def and project_def.not_active) or "PROJECT_NOT_ACTIVE")
        common.setup_error_navigation((project_def and project_def.not_active) or "PROJECT_NOT_ACTIVE", last_real_win)
        return
    end
    if not state.workspace_id then
        notify.info(state.lang[(ws_def and ws_def.not_active) or "WORKSPACE_NOT_ACTIVE"] or "Workspace not active.")
        common.open_entity_error("file", (ws_def and ws_def.not_active) or "WORKSPACE_NOT_ACTIVE")
        common.setup_error_navigation((ws_def and ws_def.not_active) or "WORKSPACE_NOT_ACTIVE", last_real_win)
        return
    end
    if not state.tab_active then
        notify.info(state.lang[(tab_def and tab_def.not_active) or "TAB_NOT_ACTIVE"] or "Tab not active.")
        common.open_entity_error("file", (tab_def and tab_def.not_active) or "TAB_NOT_ACTIVE")
        common.setup_error_navigation((tab_def and tab_def.not_active) or "TAB_NOT_ACTIVE", last_real_win)
        return
    end
    ui.close_all()
    files_ui_module.init()
end

local function setup_keymaps(ctx)
    local keymap_opts = { buffer = ctx.buf, noremap = true, silent = true, nowait = true }

    vim.keymap.set("n", config.keymappings.action.add, M.handle_workspace_add, keymap_opts)
    vim.keymap.set("n", config.keymappings.action.rename, function()
        M.handle_workspace_rename(ctx)
    end, keymap_opts)
    vim.keymap.set("n", config.keymappings.action.delete, function()
        M.handle_workspace_delete(ctx)
    end, keymap_opts)
    vim.keymap.set("n", config.keymappings.action.switch, function()
        M.handle_workspace_switch({ space_mode = true, close_panel = false })
    end, keymap_opts)
    vim.keymap.set("n", "<CR>", function()
        M.handle_workspace_switch({ enter_mode = true, close_panel = true })
    end, keymap_opts)

    if config.keymappings.action.move_up then
        vim.keymap.set("n", config.keymappings.action.move_up, function()
            M.handle_move_up(ctx)
        end, keymap_opts)
    end
    if config.keymappings.action.move_down then
        vim.keymap.set("n", config.keymappings.action.move_down, function()
            M.handle_move_down(ctx)
        end, keymap_opts)
    end

    vim.keymap.set("n", config.keymappings.global.projects, M.navigate_to_projects, keymap_opts)
    vim.keymap.set("n", config.keymappings.global.tabs, M.navigate_to_tabs, keymap_opts)
    vim.keymap.set("n", config.keymappings.global.files, M.navigate_to_files, keymap_opts)
end

M.init = function(selected_line_num, opts)
    capture_current_window()
    log.debug(
        "workspaces.M.init: Initializing workspaces list for project_id: "
            .. (state.project_id or "nil")
            .. ". Selected line hint: "
            .. tostring(selected_line_num)
    )
    local project_entity_def = get_project_def()

    if not state.project_id then
        notify.error(
            state.lang[(project_entity_def and project_entity_def.not_active) or "PROJECT_NOT_ACTIVE"]
                or "Project not active."
        )
        common.open_entity_error(
            "workspace",
            (project_entity_def and project_entity_def.not_active) or "PROJECT_NOT_ACTIVE"
        )
        common.setup_error_navigation(
            (project_entity_def and project_entity_def.not_active) or "PROJECT_NOT_ACTIVE",
            last_real_win
        )
        return
    end

    cache.project_display_name = "Unknown Project"
    local proj_data_ok, project_obj = pcall(data.find_project_by_id, state.project_id)
    if proj_data_ok and project_obj and project_obj.name then
        cache.project_display_name = project_obj.name
    else
        log.warn(
            "workspaces.M.init: Could not retrieve current project name for project_id: " .. tostring(state.project_id)
        )
    end

    opts = opts or {}
    local select_workspace_on_init = (opts.select_workspace ~= false)

    cache.workspaces_from_db = data.find_workspaces(state.project_id) or {}
    table.sort(cache.workspaces_from_db, function(a, b)
        local order_a = tonumber(a.sort_order) or math.huge
        local order_b = tonumber(b.sort_order) or math.huge
        if order_a == order_b then
            return (a.name or "") < (b.name or "")
        end
        return order_a < order_b
    end)
    cache.workspace_ids_map = {}

    local function get_tab_count(workspace_entry)
        if not workspace_entry.tabs then
            return 0
        end
        local success, decoded_tabs = pcall(vim.fn.json_decode, workspace_entry.tabs)
        if success and decoded_tabs and decoded_tabs.tab_ids then
            return #decoded_tabs.tab_ids
        end
        return 0
    end

    local active_id_for_list = select_workspace_on_init and state.workspace_id or nil
    local entity_selected_line = selected_line_num

    if not entity_selected_line and active_id_for_list then
        for idx, ws in ipairs(cache.workspaces_from_db) do
            if tostring(ws.id) == tostring(active_id_for_list) then
                entity_selected_line = idx
                log.debug("workspaces.M.init: Found active workspace ID " .. active_id_for_list .. " at line " .. idx)
                break
            end
        end
    end

    local ctx_new = common.init_entity_list(
        "workspace",
        cache.workspaces_from_db,
        cache.workspace_ids_map,
        M.init,
        active_id_for_list,
        "id",
        entity_selected_line,
        function(workspace_entry)
            local tab_count = get_tab_count(workspace_entry)
            local tab_count_display = utils.to_superscript(tab_count)
            return (workspace_entry.name or "???") .. tab_count_display
        end,
        function(entity, active_id_in_list_param)
            if not select_workspace_on_init then
                return false
            end
            return active_id_in_list_param and tostring(entity.id) == tostring(active_id_in_list_param)
        end
    )

    if not ctx_new then
        log.error("workspaces.M.init: common.init_entity_list returned no context. UI creation likely failed.")
        return
    end

    cache.ctx = ctx_new
    if cache.ctx.win and vim.api.nvim_win_is_valid(cache.ctx.win) then
        local win_config = vim.api.nvim_win_get_config(cache.ctx.win)
        local ws_def = get_entity_def()
        local base_ws_title = state.lang[(ws_def and ws_def.title) or "WORKSPACES"] or "Workspaces"
        local final_panel_title

        if
            cache.project_display_name
            and cache.project_display_name ~= "Unknown Project"
            and vim.trim(cache.project_display_name) ~= ""
        then
            final_panel_title = string.format("%s (%s)", base_ws_title, cache.project_display_name)
        else
            final_panel_title = base_ws_title
        end
        win_config.title = " " .. final_panel_title .. " "
        pcall(vim.api.nvim_win_set_config, cache.ctx.win, win_config)
    end

    setup_keymaps(cache.ctx)
    log.debug("workspaces.M.init: Workspaces list initialized successfully.")
end

M.get_current_workspace_info = function()
    if not state.workspace_id or not state.project_id then
        return nil
    end
    return data.find_workspace_by_id(state.workspace_id, state.project_id)
end

M.switch_to_workspace_by_name = function(workspace_name, project_id_context)
    local target_project_id = project_id_context or state.project_id
    if not target_project_id then
        log.warn("switch_to_workspace_by_name: No target_project_id provided or in state.")
        return false
    end
    log.debug(
        "switch_to_workspace_by_name: Attempting to switch to workspace '"
            .. workspace_name
            .. "' in project "
            .. target_project_id
    )

    local workspaces_in_project = data.find_workspaces(target_project_id) or {}
    local found_workspace = nil
    for _, ws in ipairs(workspaces_in_project) do
        if ws.name == workspace_name then
            found_workspace = ws
            break
        end
    end

    local ws_def = get_entity_def()
    if found_workspace then
        log.debug("switch_to_workspace_by_name: Found workspace ID: " .. found_workspace.id)
        if not cache.ctx or not cache.ctx.is_empty then
            M.init(nil, { select_workspace = false })
        end
        local line_in_cache = nil
        for i, ws_in_cache in ipairs(cache.workspaces_from_db or {}) do
            if ws_in_cache.id == found_workspace.id then
                line_in_cache = i
                break
            end
        end

        if line_in_cache and cache.workspace_ids_map then
            cache.workspace_ids_map[line_in_cache] = found_workspace.id
            log.debug(
                "switch_to_workspace_by_name: Mapped workspace ID "
                    .. found_workspace.id
                    .. " to line "
                    .. line_in_cache
                    .. " in UI cache."
            )
            M.handle_workspace_switch({ space_mode = true, close_panel = false })
            return true
        else
            log.warn(
                "switch_to_workspace_by_name: Could not find workspace in UI cache or map is nil. Attempting direct state change."
            )
            state.workspace_id = found_workspace.id
            local workspace_tabs_obj = found_workspace.tabs and vim.fn.json_decode(found_workspace.tabs)
                or create_empty_workspace_tabs()
            state.tab_ids = workspace_tabs_obj.tab_ids or {}
            state.tab_active = workspace_tabs_obj.tab_active
            if config.autosave then
                update_workspace_state_in_db()
            end
            ui.close_all()
            if state.tab_active then
                session.restore_state(state.tab_active, true)
                files_ui_module.init()
            else
                tabs_ui_module.init()
            end
            return true
        end
    else
        log.warn(
            "switch_to_workspace_by_name: Workspace with name '"
                .. workspace_name
                .. "' not found in project "
                .. target_project_id
        )
        notify.error(state.lang[(ws_def and ws_def.not_found) or "WORKSPACE_NOT_FOUND"] or "Workspace not found.")
    end
    return false
end

return M
