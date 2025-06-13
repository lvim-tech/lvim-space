local config = require("lvim-space.config")
local notify = require("lvim-space.api.notify")
local state = require("lvim-space.api.state")
local data = require("lvim-space.api.data")
local ui = require("lvim-space.ui")
local utils = require("lvim-space.utils")
local common = require("lvim-space.ui.common")
local session = require("lvim-space.core.session")

local M = {}

local cache = {
    tab_ids_map = {},
    tabs_from_db = {},
    ctx = nil,
    workspace_display_name = "",
}

local last_real_win = nil

local function get_entity_def()
    return common.get_entity_type("tab")
end

local function get_project_def()
    return common.get_entity_type("project")
end

local function get_ws_def()
    return common.get_entity_type("workspace")
end

local function create_empty_workspace_tabs_structure()
    return { tab_ids = {}, tab_active = nil, created_at = os.time(), updated_at = os.time() }
end

local function create_empty_tab_data_storage()
    return { buffers = {}, created_at = os.time(), modified_at = os.time() }
end

local function validate_tab_name_for_add_or_rename(tab_name, workspace_id_context, tab_id_for_rename)
    local ok, err_code = common.validate_entity_name("tab", tab_name)
    if not ok then
        return nil, err_code
    end
    local trimmed_name = vim.trim(tab_name)
    local existing_tab_with_name = data.is_tab_name_exist(trimmed_name, workspace_id_context)
    if existing_tab_with_name then
        if tab_id_for_rename and tostring(existing_tab_with_name.id) == tostring(tab_id_for_rename) then
            return trimmed_name, nil
        else
            return nil, "EXIST_NAME"
        end
    end
    return trimmed_name, nil
end

local function update_tabs_state_in_db()
    if not config.autosave or not state.workspace_id then
        return
    end
    local ws = data.find_workspace_by_id(state.workspace_id, state.project_id)
    if ws then
        local tabs_json_obj = ws.tabs and vim.fn.json_decode(ws.tabs) or create_empty_workspace_tabs_structure()
        tabs_json_obj.tab_active = state.tab_active
        tabs_json_obj.tab_ids = state.tab_ids or {}
        tabs_json_obj.updated_at = os.time()
        data.update_workspace_tabs(vim.fn.json_encode(tabs_json_obj), state.workspace_id)
    end
end

local function add_tab_db(tab_name_input, workspace_id)
    local tab_def = get_entity_def()
    local tab_data_obj = create_empty_tab_data_storage()
    local tab_data_json_str = vim.fn.json_encode(tab_data_obj)
    local new_tab_id = data.add_tab(tab_name_input, tab_data_json_str, workspace_id)
    if not new_tab_id or type(new_tab_id) ~= "number" or new_tab_id <= 0 then
        return (tab_def and tab_def.add_failed) or "TAB_ADD_FAILED"
    end
    local current_ws = data.find_workspace_by_id(workspace_id, state.project_id)
    if not current_ws then
        data.delete_tab(new_tab_id, workspace_id)
        return (tab_def and tab_def.add_failed) or "TAB_ADD_FAILED"
    end
    local ws_tabs_data = current_ws.tabs and vim.fn.json_decode(current_ws.tabs)
        or create_empty_workspace_tabs_structure()
    if not ws_tabs_data.tab_ids then
        ws_tabs_data.tab_ids = {}
    end
    table.insert(ws_tabs_data.tab_ids, new_tab_id)
    ws_tabs_data.updated_at = os.time()
    local update_success = data.update_workspace_tabs(vim.fn.json_encode(ws_tabs_data), workspace_id)
    if not update_success then
        data.delete_tab(new_tab_id, workspace_id)
        return (tab_def and tab_def.add_failed) or "TAB_ADD_FAILED"
    end
    state.tab_ids = ws_tabs_data.tab_ids
    update_tabs_state_in_db()
    return new_tab_id
end

local function rename_tab_db(tab_id, new_tab_name_validated, workspace_id, selected_line_num)
    local success = data.update_tab_name(tab_id, new_tab_name_validated, workspace_id)
    if not success then
        return nil
    end
    update_tabs_state_in_db()
    vim.schedule(function()
        M.init(selected_line_num)
    end)
    return true
end

local function delete_tab_db(tab_id_to_delete, workspace_id, selected_line_num)
    local success = data.delete_tab(tab_id_to_delete, workspace_id)
    if not success then
        return nil
    end
    vim.schedule(function()
        local current_ws = data.find_workspace_by_id(workspace_id, state.project_id)
        if not current_ws then
            M.init(selected_line_num)
            return
        end
        local ws_tabs_data = current_ws.tabs and vim.fn.json_decode(current_ws.tabs)
            or create_empty_workspace_tabs_structure()
        if not ws_tabs_data.tab_ids then
            ws_tabs_data.tab_ids = {}
        end
        local index_to_remove = nil
        for i, id_in_list in ipairs(ws_tabs_data.tab_ids) do
            if tostring(id_in_list) == tostring(tab_id_to_delete) then
                index_to_remove = i
                break
            end
        end
        if index_to_remove then
            table.remove(ws_tabs_data.tab_ids, index_to_remove)
        end
        local was_active_tab = tostring(ws_tabs_data.tab_active) == tostring(tab_id_to_delete)
        if was_active_tab then
            ws_tabs_data.tab_active = nil
            state.tab_active = nil
            state.file_active = nil
            session.clear_current_state()
            session.close_all_file_windows_and_buffers()
            local main_win = state.ui and state.ui.content and state.ui.content.win
            if main_win and vim.api.nvim_win_is_valid(main_win) then
                vim.api.nvim_set_current_win(main_win)
                vim.cmd("enew")
            end
        end
        ws_tabs_data.updated_at = os.time()
        data.update_workspace_tabs(vim.fn.json_encode(ws_tabs_data), workspace_id)
        state.tab_ids = ws_tabs_data.tab_ids
        update_tabs_state_in_db()
        M.init(selected_line_num)
    end)
    return true
end

local function handle_move_operation(ctx, direction)
    if not ctx or not ctx.win or not vim.api.nvim_win_is_valid(ctx.win) then
        return
    end
    local current_visual_line = vim.api.nvim_win_get_cursor(ctx.win)[1]
    local tab_id_to_move = cache.tab_ids_map[current_visual_line]
    if not tab_id_to_move then
        return
    end
    local tab_to_move_data
    for _, t_entry in ipairs(cache.tabs_from_db) do
        if tostring(t_entry.id) == tostring(tab_id_to_move) then
            tab_to_move_data = t_entry
            break
        end
    end
    local tab_def = get_entity_def()
    if not tab_def then
        notify.error(state.lang.TAB_REORDER_FAILED or "Failed to reorder tab.")
        return
    end
    if not tab_to_move_data then
        notify.error(state.lang[tab_def.ui_cache_error] or "UI data inconsistency.")
        return
    end
    local current_sort_order = tonumber(tab_to_move_data.sort_order)
    if not current_sort_order then
        notify.error(state.lang[tab_def.reorder_failed_error] or "Failed to reorder tab.")
        return
    end
    if direction == "up" and current_sort_order <= 1 then
        notify.info(state.lang[tab_def.already_at_top] or "Tab is already at the top.")
        return
    elseif direction == "down" and current_sort_order >= #cache.tabs_from_db then
        notify.info(state.lang[tab_def.already_at_bottom] or "Tab is already at the bottom.")
        return
    end
    local target_sort_order = direction == "up" and (current_sort_order - 1) or (current_sort_order + 1)
    local new_order_table = {}
    for _, t_entry in ipairs(cache.tabs_from_db) do
        local entry_sort_order = tonumber(t_entry.sort_order)
        if not entry_sort_order then
            goto continue
        end
        local new_order_for_this_item = entry_sort_order
        if t_entry.id == tab_id_to_move then
            new_order_for_this_item = target_sort_order
        elseif entry_sort_order == target_sort_order then
            new_order_for_this_item = current_sort_order
        end
        table.insert(new_order_table, { id = t_entry.id, order = new_order_for_this_item })
        ::continue::
    end
    local success, err_msg_code = data.reorder_tabs(state.workspace_id, new_order_table)
    if success then
        local new_line = direction == "up" and (current_visual_line - 1) or (current_visual_line + 1)
        M.init(new_line)
    else
        local err_key_to_use = tab_def.reorder_failed_error
        if err_msg_code == "TAB_REORDER_MISSING_PARAMS" then
            err_key_to_use = tab_def.reorder_missing_params_error
        end
        notify.error(state.lang[err_key_to_use] or "Failed to reorder tab.")
        M.init(current_visual_line)
    end
end

function M.handle_tab_add()
    local tab_def = get_entity_def()
    if not tab_def then
        notify.error("An unexpected error occurred.")
        return
    end
    local default_name = "Tab " .. tostring(#(state.tab_ids or {}) + 1)
    ui.create_input_field(state.lang.TAB_NAME or "Tab Name:", default_name, function(input_tab_name)
        if not input_tab_name or vim.trim(input_tab_name) == "" then
            notify.info(state.lang.OPERATION_CANCELLED or "Operation cancelled.")
            return
        end
        local trimmed_name = vim.trim(input_tab_name)
        local validated_name, err_code = validate_tab_name_for_add_or_rename(trimmed_name, state.workspace_id, nil)
        if not validated_name then
            local err_key_from_def
            if err_code == "LEN_NAME" then
                err_key_from_def = tab_def.name_len_error
            elseif err_code == "EXIST_NAME" then
                err_key_from_def = tab_def.name_exist_error
            else
                err_key_from_def = tab_def.add_failed
            end
            notify.error(state.lang[err_key_from_def] or ("Invalid tab name: " .. (err_code or "unknown error")))
            return
        end
        local result_or_err_key = add_tab_db(validated_name, state.workspace_id)
        if type(result_or_err_key) == "number" and result_or_err_key > 0 then
            notify.info(state.lang[tab_def.added_success] or "Tab added successfully!")
            M.init()
        else
            notify.error(state.lang[result_or_err_key] or "Failed to add tab.")
        end
    end, { input_filetype = "lvim-space-tabs-input" })
end

function M.handle_tab_rename(ctx)
    local current_line_num = ctx
            and ctx.win
            and vim.api.nvim_win_is_valid(ctx.win)
            and vim.api.nvim_win_get_cursor(ctx.win)[1]
        or 1
    local tab_id_to_rename = common.get_id_at_cursor(cache.tab_ids_map)
    local current_name = ""
    if cache.tabs_from_db then
        for _, tab_entry in ipairs(cache.tabs_from_db) do
            if tostring(tab_entry.id) == tostring(tab_id_to_rename) then
                current_name = tab_entry.name
                break
            end
        end
    end
    if not tab_id_to_rename then
        return
    end
    common.rename_entity(
        "tab",
        tab_id_to_rename,
        current_name,
        state.workspace_id,
        function(id, new_name_from_input, workspace_id_context)
            local validated_name, err_code =
                validate_tab_name_for_add_or_rename(new_name_from_input, workspace_id_context, id)
            if not validated_name then
                return err_code
            end
            return rename_tab_db(id, validated_name, workspace_id_context, current_line_num)
        end
    )
end

function M.handle_tab_delete(ctx)
    local current_line_num = ctx
            and ctx.win
            and vim.api.nvim_win_is_valid(ctx.win)
            and vim.api.nvim_win_get_cursor(ctx.win)[1]
        or 1
    local tab_id_to_delete = common.get_id_at_cursor(cache.tab_ids_map)
    local entry_name = ""
    if cache.tabs_from_db then
        for _, tab_entry in ipairs(cache.tabs_from_db) do
            if tostring(tab_entry.id) == tostring(tab_id_to_delete) then
                entry_name = tab_entry.name
                break
            end
        end
    end
    if not tab_id_to_delete then
        return
    end

    common.delete_entity("tab", tab_id_to_delete, entry_name, state.workspace_id, function(del_id, ws_id)
        return delete_tab_db(del_id, ws_id, current_line_num)
    end)
end

function M.handle_tab_go(opts)
    opts = opts or {}
    local tab_def = get_entity_def()
    local tab_id_selected = common.get_id_at_cursor(cache.tab_ids_map)
    if not tab_id_selected then
        return
    end
    if tostring(state.tab_active) == tostring(tab_id_selected) then
        if opts.close_panel then
            ui.close_all()
            if opts.go_to_files then
                vim.schedule(function()
                    require("lvim-space.ui.files").init()
                end)
            end
        end
        return
    end
    local selected_tab = data.find_tab_by_id(tab_id_selected, state.workspace_id)
    if not selected_tab then
        notify.error(state.lang[(tab_def and tab_def.not_found) or "TAB_NOT_FOUND"] or "Tab not found.")
        return
    end
    local panel_win = state.ui and state.ui.content and state.ui.content.win
    local panel_is_valid = panel_win and vim.api.nvim_win_is_valid(panel_win)
    local cursor_pos = panel_is_valid and vim.api.nvim_win_get_cursor(panel_win)
    local current_line_in_ui = cursor_pos and cursor_pos[1] or nil
    local prev_disable_state = state.disable_auto_close
    state.disable_auto_close = true
    local success = session.switch_tab(tab_id_selected)
    update_tabs_state_in_db()
    vim.defer_fn(function()
        if success then
            local switched_to_msg = (tab_def and tab_def.switched_to and state.lang[tab_def.switched_to])
                or "Switched to tab: "
            notify.info(switched_to_msg .. (selected_tab.name or "Selected Tab"))
            if opts.close_panel then
                state.disable_auto_close = prev_disable_state
                ui.close_all()
                if opts.go_to_files then
                    vim.schedule(function()
                        require("lvim-space.ui.files").init()
                    end)
                end
            else
                M.init(current_line_in_ui)
                vim.defer_fn(function()
                    local new_panel_win = state.ui and state.ui.content and state.ui.content.win
                    if new_panel_win and vim.api.nvim_win_is_valid(new_panel_win) then
                        vim.api.nvim_set_current_win(new_panel_win)
                        if current_line_in_ui then
                            pcall(vim.api.nvim_win_set_cursor, new_panel_win, { current_line_in_ui, 0 })
                        end
                    end
                end, 50)
            end
        else
            notify.error(
                state.lang[(tab_def and tab_def.switch_failed) or "TAB_SWITCH_FAILED"] or "Failed to switch tab."
            )
            state.disable_auto_close = prev_disable_state
        end
    end, 100)
end

function M.handle_move_up(ctx)
    handle_move_operation(ctx, "up")
end

function M.handle_move_down(ctx)
    handle_move_operation(ctx, "down")
end

function M.navigate_to_projects()
    ui.close_all()
    require("lvim-space.ui.projects").init()
end

function M.navigate_to_workspaces()
    ui.close_all()
    require("lvim-space.ui.workspaces").init()
end

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

function M.navigate_to_search()
    if not state.project_id then
        notify.info(state.lang.PROJECT_NOT_ACTIVE or "No active project. Please select or add a project first.")
        return
    end
    ui.close_all()
    require("lvim-space.ui.search").init()
end

local function setup_keymaps(ctx)
    local keymap_opts = { buffer = ctx.buf, noremap = true, silent = true, nowait = true }
    vim.keymap.set("n", config.keymappings.action.add, function()
        M.handle_tab_add()
    end, keymap_opts)
    vim.keymap.set("n", config.keymappings.action.rename, function()
        if next(ctx.entities) ~= nil then
            M.handle_tab_rename(ctx)
        end
    end, keymap_opts)
    vim.keymap.set("n", config.keymappings.action.delete, function()
        if next(ctx.entities) ~= nil then
            M.handle_tab_delete(ctx)
        end
    end, keymap_opts)
    vim.keymap.set("n", config.keymappings.action.switch, function()
        if next(ctx.entities) ~= nil then
            M.handle_tab_go({ close_panel = false })
        end
    end, keymap_opts)
    vim.keymap.set("n", config.keymappings.action.enter, function()
        if next(ctx.entities) ~= nil then
            M.handle_tab_go({ close_panel = true })
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
    vim.keymap.set("n", config.keymappings.global.workspaces, function()
        M.navigate_to_workspaces()
    end, keymap_opts)
    vim.keymap.set("n", config.keymappings.global.files, function()
        if next(ctx.entities) ~= nil then
            M.navigate_to_files()
        end
    end, keymap_opts)
    vim.keymap.set("n", config.keymappings.global.search, function()
        M.navigate_to_search()
    end, keymap_opts)
end

M.init = function(selected_line_num)
    local project_def = get_project_def()
    local ws_def = get_ws_def()
    if not state.project_id then
        notify.error(state.lang[(project_def and project_def.not_active) or "PROJECT_NOT_ACTIVE"])
        common.open_entity_error("tab", (project_def and project_def.not_active) or "PROJECT_NOT_ACTIVE")
        common.setup_error_navigation((project_def and project_def.not_active) or "PROJECT_NOT_ACTIVE", last_real_win)
        return
    end
    if not state.workspace_id then
        notify.error(state.lang[(ws_def and ws_def.not_active) or "WORKSPACE_NOT_ACTIVE"])
        common.open_entity_error("tab", (ws_def and ws_def.not_active) or "WORKSPACE_NOT_ACTIVE")
        common.setup_error_navigation((ws_def and ws_def.not_active) or "WORKSPACE_NOT_ACTIVE", last_real_win)
        return
    end
    cache.workspace_display_name = "Unknown Workspace"
    local ws_data_ok, workspace_obj = pcall(data.find_workspace_by_id, state.workspace_id, state.project_id)
    if ws_data_ok and workspace_obj and workspace_obj.name then
        cache.workspace_display_name = workspace_obj.name
    end
    cache.tabs_from_db = data.find_tabs(state.workspace_id) or {}
    table.sort(cache.tabs_from_db, function(a, b)
        local order_a = tonumber(a.sort_order) or math.huge
        local order_b = tonumber(b.sort_order) or math.huge
        if order_a == order_b then
            return (a.name or "") < (b.name or "")
        end
        return order_a < order_b
    end)
    cache.tab_ids_map = {}
    local function get_buffer_count(tab_entry)
        if not tab_entry.data then
            return 0
        end
        local success, decoded_data = pcall(vim.fn.json_decode, tab_entry.data)
        if success and decoded_data and decoded_data.buffers then
            return #decoded_data.buffers
        end
        return 0
    end
    local actual_selected_line = selected_line_num
    if not actual_selected_line and state.tab_active then
        for i, tab_entry in ipairs(cache.tabs_from_db) do
            if tostring(tab_entry.id) == tostring(state.tab_active) then
                actual_selected_line = i
                break
            end
        end
    end
    local ctx_new = common.init_entity_list(
        "tab",
        cache.tabs_from_db,
        cache.tab_ids_map,
        M.init,
        state.tab_active,
        "id",
        actual_selected_line,
        function(tab_entry)
            local buffer_count = get_buffer_count(tab_entry)
            local buffer_count_display = utils.to_superscript and utils.to_superscript(buffer_count) or ""
            return (tab_entry.name or "???") .. buffer_count_display
        end
    )
    if not ctx_new then
        return
    end
    cache.ctx = ctx_new
    if cache.ctx.win and vim.api.nvim_win_is_valid(cache.ctx.win) then
        local win_config = vim.api.nvim_win_get_config(cache.ctx.win)
        local base_tabs_title = state.lang.TABS or "Tabs"
        local final_panel_title
        if
            cache.workspace_display_name
            and cache.workspace_display_name ~= "Unknown Workspace"
            and vim.trim(cache.workspace_display_name) ~= ""
        then
            final_panel_title = string.format("%s (%s)", base_tabs_title, cache.workspace_display_name)
        else
            final_panel_title = base_tabs_title
        end
        win_config.title = " " .. final_panel_title .. " "
        pcall(vim.api.nvim_win_set_config, cache.ctx.win, win_config)
    end
    setup_keymaps(cache.ctx)
end

M.get_current_tab_info = function()
    if not state.tab_active or not state.workspace_id then
        return nil
    end
    return data.find_tab_by_id(state.tab_active, state.workspace_id)
end

M.switch_to_tab_by_name = function(tab_name, workspace_id_context)
    local target_workspace_id = workspace_id_context or state.workspace_id
    if not target_workspace_id then
        return false
    end
    local tabs_in_workspace = data.find_tabs(target_workspace_id) or {}
    local found_tab = nil
    for _, tab_entry in ipairs(tabs_in_workspace) do
        if tab_entry.name == tab_name then
            found_tab = tab_entry
            break
        end
    end
    if found_tab then
        update_tabs_state_in_db()
        local success = session.switch_tab(found_tab.id)
        if success then
            update_tabs_state_in_db()
            ui.close_all()
            require("lvim-space.ui.files").init()
            return true
        else
            local tab_def = get_entity_def()
            notify.error(
                state.lang[(tab_def and tab_def.switch_failed) or "TAB_SWITCH_FAILED"] or "Failed to switch tab."
            )
            return false
        end
    else
        notify.error(state.lang.TAB_NOT_FOUND or "Tab not found.")
    end
    return false
end

return M
