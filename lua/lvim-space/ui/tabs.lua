-- tabs.lua
-- UI panel for managing tabs within the active workspace.
-- Handles listing, adding, renaming, deleting, reordering, and switching tabs.

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
    if not str then
        return default
    end
    local ok, result = pcall(vim.fn.json_decode, str)
    return (ok and type(result) == "table") and result or default
end

---@class TabsCache
---@field tab_ids_map table<number, number> Maps visual line number to tab ID.
---@field tabs_from_db table[] Raw tab records fetched from the database.
---@field ctx table|nil Current panel window/buffer context.
---@field workspace_display_name string Display name of the active workspace.
---@field last_cursor_position number Last known cursor row in the panel.

---@type TabsCache
local cache = {
    tab_ids_map = {},
    tabs_from_db = {},
    ctx = nil,
    workspace_display_name = "",
    last_cursor_position = 1,
}

---@type integer|nil Last non-plugin editor window handle.
local last_real_win = nil

local is_plugin_panel_win = ui.is_plugin_window

---@return table|nil Entity definition table for "tab".
local function get_entity_def()
    return common.get_entity_type("tab")
end

---@return table|nil Entity definition table for "project".
local function get_project_def()
    return common.get_entity_type("project")
end

---@return table|nil Entity definition table for "workspace".
local function get_ws_def()
    return common.get_entity_type("workspace")
end

---@return table A fresh workspace-tabs JSON structure with empty tab list.
local function create_empty_workspace_tabs_structure()
    return { tab_ids = {}, tab_active = nil, created_at = os.time(), updated_at = os.time() }
end

---@return table A fresh tab data storage object with an empty buffer list.
local function create_empty_tab_data_storage()
    return { buffers = {}, created_at = os.time(), modified_at = os.time() }
end

--- Saves the current non-plugin window as `last_real_win`.
local function save_window_context()
    local current_win = vim.api.nvim_get_current_win()
    if current_win and vim.api.nvim_win_is_valid(current_win) and not is_plugin_panel_win(current_win) then
        last_real_win = current_win
    end
end

--- Saves the cursor row from the panel window into `cache.last_cursor_position`.
local function save_cursor_position()
    if cache.ctx and cache.ctx.win and vim.api.nvim_win_is_valid(cache.ctx.win) then
        local cursor_pos = vim.api.nvim_win_get_cursor(cache.ctx.win)
        cache.last_cursor_position = cursor_pos[1]
    end
end

--- Registers a CursorMoved autocmd on the panel buffer to keep `cache.last_cursor_position` up to date.
---@param ctx table Panel context with `win` and `buf` fields.
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
        group = vim.api.nvim_create_augroup("LvimSpaceTabsCursor", { clear = true }),
    })
end

--- Refreshes the tab panel in-place without re-initialising the full window.
--- Falls back to `M.init` if the panel window or buffer is no longer valid.
M.refresh = function()
    if not cache.ctx or not cache.ctx.win or not vim.api.nvim_win_is_valid(cache.ctx.win) then
        return M.init()
    end

    if not cache.ctx.buf or not vim.api.nvim_buf_is_valid(cache.ctx.buf) then
        return M.init()
    end

    save_cursor_position()

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

    local icons = config.ui.icons
    local tab_active_icon = icons.tab_active or " "
    local tab_icon = icons.tab or " "

    local new_lines = {}
    for i, tab_entry in ipairs(cache.tabs_from_db) do
        cache.tab_ids_map[i] = tab_entry.id
        local is_active = tostring(tab_entry.id) == tostring(state.tab_active)
        local buffer_count = get_buffer_count(tab_entry)
        local buffer_count_display = utils.string.to_superscript(buffer_count)
        local display_text = (tab_entry.name or "???") .. buffer_count_display
        display_text = (is_active and tab_active_icon or tab_icon) .. display_text

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

    cache.ctx.is_empty = #new_lines == 0
    cache.ctx.entities = cache.tabs_from_db

    if cache.ctx.win and vim.api.nvim_win_is_valid(cache.ctx.win) then
        local win_config = vim.api.nvim_win_get_config(cache.ctx.win)
        win_config.title = " " .. final_panel_title .. " "
        pcall(vim.api.nvim_win_set_config, cache.ctx.win, win_config)
    end
end

--- Validates a tab name for add or rename operations.
--- Returns the trimmed name on success, or nil plus an error code on failure.
---@param tab_name string The proposed tab name (may be untrimmed).
---@param workspace_id_context number The workspace ID used for duplicate-name checking.
---@param tab_id_for_rename number|nil The ID of the tab being renamed, or nil when adding.
---@return string|nil validated_name The trimmed, validated name, or nil on error.
---@return string|nil err_code Error code such as "LEN_NAME" or "EXIST_NAME", or nil on success.
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

--- Persists the current tab state (active tab and tab ID list) into the workspace record.
--- Does nothing when autosave is disabled or no workspace is active.
local function update_tabs_state_in_db()
    if not config.autosave or not state.workspace_id then
        return
    end
    local ws = data.find_workspace_by_id(state.workspace_id, state.project_id)
    if ws then
        local tabs_json_obj = safe_json_decode(ws.tabs, create_empty_workspace_tabs_structure())
        tabs_json_obj.tab_active = state.tab_active
        tabs_json_obj.tab_ids = state.tab_ids or {}
        tabs_json_obj.updated_at = os.time()
        data.update_workspace_tabs(vim.fn.json_encode(tabs_json_obj), state.workspace_id)
    end
end

--- Creates a new tab record in the database and links it to the workspace.
---@param tab_name_input string The validated tab name.
---@param workspace_id number The workspace to which the new tab belongs.
---@return number|string result The new tab's integer ID on success, or an error-key string on failure.
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
    local ws_tabs_data = safe_json_decode(current_ws.tabs, create_empty_workspace_tabs_structure())
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

--- Updates the name of an existing tab in the database and schedules a panel reload.
---@param tab_id number The ID of the tab to rename.
---@param new_tab_name_validated string The already-validated new name.
---@param workspace_id number The workspace that owns the tab.
---@param selected_line_num number The panel line to restore focus to after reload.
---@return true|nil result true on success, nil on database failure.
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

--- Deletes a tab from the database, cleans up workspace tab lists,
--- and resets session state if the deleted tab was the active one.
---@param tab_id_to_delete number The ID of the tab to delete.
---@param workspace_id number The workspace that owns the tab.
---@param selected_line_num number The panel line to restore focus to after reload.
---@return true|nil result true on success, nil on database failure.
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
        local ws_tabs_data = safe_json_decode(current_ws.tabs, create_empty_workspace_tabs_structure())
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

--- Moves the tab under the cursor one position up or down in the sort order.
---@param ctx table Panel context with `win` field.
---@param direction "up"|"down" Direction of movement.
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

--- Opens an input prompt and adds a new tab to the active workspace.
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
            M.refresh()
        else
            notify.error(state.lang[result_or_err_key] or "Failed to add tab.")
        end
    end, { input_filetype = "lvim-space-tabs-input" })
end

--- Opens an input prompt pre-filled with the current tab name and renames it on confirmation.
---@param ctx table Panel context with `win` field used to determine the cursor row.
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

--- Prompts for confirmation and deletes the tab under the cursor.
---@param ctx table Panel context with `win` field used to determine the cursor row.
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

--- Switches to the tab under the cursor.
---@param opts? {close_panel?: boolean, go_to_files?: boolean} Optional behaviour flags.
---   `close_panel` closes all plugin panels after switching.
---   `go_to_files` additionally opens the files panel after closing.
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

--- Moves the tab under the cursor one position up in the list.
---@param ctx table Panel context with `win` field.
function M.handle_move_up(ctx)
    handle_move_operation(ctx, "up")
end

--- Moves the tab under the cursor one position down in the list.
---@param ctx table Panel context with `win` field.
function M.handle_move_down(ctx)
    handle_move_operation(ctx, "down")
end

--- Closes all plugin panels and opens the projects panel.
function M.navigate_to_projects()
    ui.close_all()
    require("lvim-space.ui.projects").init()
end

--- Closes all plugin panels and opens the workspaces panel.
function M.navigate_to_workspaces()
    ui.close_all()
    require("lvim-space.ui.workspaces").init()
end

--- Closes all plugin panels and opens the files panel, guarding against missing project/workspace/tab state.
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

--- Closes all plugin panels and opens the fuzzy search panel.
--- Shows a notification when no project is active.
function M.navigate_to_search()
    if not state.project_id then
        notify.info(state.lang.PROJECT_NOT_ACTIVE or "No active project. Please select or add a project first.")
        return
    end
    ui.close_all()
    require("lvim-space.ui.search").init()
end

--- Registers all buffer-local keymaps for the tabs panel.
---@param ctx table Panel context with `buf` and `entities` fields.
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

--- Initialises or re-initialises the tabs panel from scratch.
--- Validates that a project and workspace are active before opening.
---@param selected_line_num? number The panel line to place the cursor on after opening.
M.init = function(selected_line_num)
    save_window_context()

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
    if not actual_selected_line and cache.last_cursor_position > 1 then
        actual_selected_line = cache.last_cursor_position
    end
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
            local buffer_count_display = utils.string.to_superscript(buffer_count)
            return (tab_entry.name or "???") .. buffer_count_display
        end
    )
    if not ctx_new then
        return
    end
    cache.ctx = ctx_new

    if cache.ctx.win and vim.api.nvim_win_is_valid(cache.ctx.win) then
        local cursor_pos = vim.api.nvim_win_get_cursor(cache.ctx.win)
        cache.last_cursor_position = cursor_pos[1]

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
    setup_cursor_tracking(cache.ctx)
end

--- Returns the database record for the currently active tab.
---@return table|nil tab_record The active tab's data row, or nil when no tab is active.
M.get_current_tab_info = function()
    if not state.tab_active or not state.workspace_id then
        return nil
    end
    return data.find_tab_by_id(state.tab_active, state.workspace_id)
end

--- Finds a tab by name within the given (or active) workspace and switches to it.
--- Opens the files panel on success and shows a notification on failure.
---@param tab_name string The exact name of the tab to switch to.
---@param workspace_id_context? number Workspace to search in; defaults to `state.workspace_id`.
---@return boolean success true when the switch succeeded, false otherwise.
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
