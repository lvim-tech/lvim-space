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
        return
    end
    if state.workspace_id then
        data.set_workspace_active(state.workspace_id, state.project_id)
        local ws = data.find_workspace_by_id(state.workspace_id, state.project_id)
        if ws then
            local tabs_json_obj = ws.tabs and vim.fn.json_decode(ws.tabs) or create_empty_workspace_tabs()
            tabs_json_obj.tab_active = state.tab_active
            tabs_json_obj.tab_ids = state.tab_ids or {}
            tabs_json_obj.updated_at = os.time()
            data.update_workspace_tabs(vim.fn.json_encode(tabs_json_obj), state.workspace_id)
        end
    else
        data.set_workspaces_inactive(state.project_id)
    end
end

local function add_workspace_db(workspace_name, project_id)
    local ws_def = get_entity_def()
    local initial_tabs_structure = create_empty_workspace_tabs()
    local initial_tabs_json = vim.fn.json_encode(initial_tabs_structure)
    local result = data.add_workspace(workspace_name, initial_tabs_json, project_id)
    if type(result) == "number" and result > 0 then
        vim.schedule(function()
            M.init()
        end)
        return result
    elseif type(result) == "string" then
        return result
    else
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
        return
    end
    state.workspace_id = workspace_id
    local workspace = data.find_workspace_by_id(workspace_id, state.project_id)
    local workspace_tabs_obj = workspace and workspace.tabs and vim.fn.json_decode(workspace.tabs)
        or create_empty_workspace_tabs()

    state.tab_ids = workspace_tabs_obj.tab_ids or {}
    state.tab_active = workspace_tabs_obj.tab_active
    if config.autosave then
        update_workspace_state_in_db()
    end
    if not state.tab_active then
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
            end)
        end,
        once = true,
    })
    session.restore_state(state.tab_active, true)
end

local function enter_navigate_to_last_panel(workspace_id)
    state.workspace_id = workspace_id
    local workspace = data.find_workspace_by_id(workspace_id, state.project_id)
    local workspace_tabs_obj = workspace and workspace.tabs and vim.fn.json_decode(workspace.tabs)
        or create_empty_workspace_tabs()
    state.tab_ids = workspace_tabs_obj.tab_ids or {}
    state.tab_active = workspace_tabs_obj.tab_active
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
        session.restore_state(state.tab_active, true)
        vim.schedule(function()
            files_ui_module.init()
        end)
    else
        vim.schedule(function()
            tabs_ui_module.init()
        end)
    end
end

local function handle_move_operation(ctx, direction)
    if not ctx or not ctx.win or not vim.api.nvim_win_is_valid(ctx.win) then
        return
    end
    local current_visual_line = vim.api.nvim_win_get_cursor(ctx.win)[1]
    local workspace_id_to_move = cache.workspace_ids_map[current_visual_line]
    if not workspace_id_to_move then
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
        notify.error(state.lang.WORKSPACE_REORDER_FAILED or "Failed to reorder workspace.")
        return
    end
    if not workspace_to_move_data then
        notify.error(state.lang[ws_def.ui_cache_error] or "UI data inconsistency.")
        return
    end
    local current_sort_order = tonumber(workspace_to_move_data.sort_order)
    if not current_sort_order then
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
        local new_line = direction == "up" and (current_visual_line - 1) or (current_visual_line + 1)
        M.init(new_line)
    else
        local err_key_to_use = (ws_def and ws_def.reorder_failed_error) or "WORKSPACE_REORDER_FAILED"
        if err_msg_code == "WORKSPACE_REORDER_MISSING_PARAMS" then
            err_key_to_use = (ws_def and ws_def.reorder_missing_params_error) or "WORKSPACE_REORDER_MISSING_PARAMS"
        end
        notify.error(state.lang[err_key_to_use] or "Failed to reorder workspace.")
        M.init(current_visual_line)
    end
end

M.handle_workspace_add = function()
    local ws_def = get_entity_def()
    if not ws_def then
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
    end, { input_filetype = "lvim-space-workspace-input" }) -- Добавена опция тук
end

M.handle_workspace_rename = function(ctx)
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

M.handle_workspace_delete = function(ctx)
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
        return
    end
    common.delete_entity("workspace", ws_id_to_delete, entry_name, state.project_id, function(del_id, proj_id)
        return delete_workspace_db(del_id, proj_id, current_line_num)
    end)
end

M.handle_workspace_go = function(opts)
    local ws_def = get_entity_def()
    local workspace_id_selected = common.get_id_at_cursor(cache.workspace_ids_map)
    if not workspace_id_selected then
        return
    end
    local selected_line_in_ui = cache.ctx
            and cache.ctx.win
            and vim.api.nvim_win_is_valid(cache.ctx.win)
            and vim.api.nvim_win_get_cursor(cache.ctx.win)[1]
        or nil
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

M.handle_move_up = function(ctx)
    handle_move_operation(ctx, "up")
end

M.handle_move_down = function(ctx)
    handle_move_operation(ctx, "down")
end

M.navigate_to_projects = function()
    ui.close_all()
    require("lvim-space.ui.projects").init()
end

M.navigate_to_tabs = function()
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
    tabs_ui_module.init()
end

M.navigate_to_files = function()
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
    files_ui_module.init()
end

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

local function setup_keymaps(ctx)
    local keymap_opts = { buffer = ctx.buf, noremap = true, silent = true, nowait = true }
    vim.keymap.set("n", config.keymappings.action.add, function()
        M.handle_workspace_add()
    end, keymap_opts)
    vim.keymap.set("n", config.keymappings.action.rename, function()
        if next(ctx.entities) ~= nil then
            M.handle_workspace_rename(ctx)
        end
    end, keymap_opts)
    vim.keymap.set("n", config.keymappings.action.delete, function()
        if next(ctx.entities) ~= nil then
            M.handle_workspace_delete(ctx)
        end
    end, keymap_opts)
    vim.keymap.set("n", config.keymappings.action.switch, function()
        if next(ctx.entities) ~= nil then
            M.handle_workspace_go({ space_mode = true })
        end
    end, keymap_opts)
    vim.keymap.set("n", config.keymappings.action.enter, function()
        if next(ctx.entities) ~= nil then
            M.handle_workspace_go({ enter_mode = true })
        end
    end, keymap_opts)
    vim.keymap.set("n", config.keymappings.action.move_up, function()
        if next(ctx.entities) ~= nil then
            M.handle_move_up(ctx)
        end
    end, keymap_opts)
    vim.keymap.set("n", config.keymappings.action.move_down, function()
        if next(ctx.entities) ~= nil then
            M.handle_move_down(ctx)
        end
    end, keymap_opts)
    vim.keymap.set("n", config.keymappings.global.projects, function()
        M.navigate_to_projects()
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

M.init = function(selected_line_num, opts)
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
end

M.switch_to_workspace_by_name = function(workspace_name, project_id_context)
    local target_project_id = project_id_context or state.project_id
    if not target_project_id then
        return false
    end
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
            M.handle_workspace_go({ space_mode = true, close_panel = false })
            return true
        else
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
        notify.error(state.lang[(ws_def and ws_def.not_found) or "WORKSPACE_NOT_FOUND"] or "Workspace not found.")
    end
    return false
end

return M
