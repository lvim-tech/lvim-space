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
local cache = { tab_ids_map = {}, tabs_from_db = {}, ctx = nil, workspace_display_name = "" }
local last_real_win = nil

local function capture_current_window()
    local current_win = vim.api.nvim_get_current_win()
    if not ui.is_plugin_window(current_win) and vim.api.nvim_win_is_valid(current_win) then
        last_real_win = current_win
        log.debug("Remembered active window: " .. tostring(last_real_win))
    end
end

local function validate_tab_name(tab_name)
    local ok, err = common.validate_entity_name("tab", tab_name)
    if not ok then
        return nil, err
    end
    return vim.trim(tab_name), nil
end

local function create_empty_tab_data()
    return { buffers = {}, created_at = os.time(), modified_at = os.time() }
end

local function update_tabs_state_in_db()
    if not config.autosave or not state.workspace_id then
        return
    end
    local ws = data.find_workspace_by_id(state.workspace_id, state.project_id)
    if ws then
        local tabs_json = ws.tabs and vim.fn.json_decode(ws.tabs) or {}
        tabs_json.tab_active = state.tab_active
        tabs_json.tab_ids = state.tab_ids or {}
        tabs_json.updated_at = os.time()
        data.update_workspace_tabs(vim.fn.json_encode(tabs_json), state.workspace_id)
    end
end

local function add_tab_db(tab_name, workspace_id)
    local validated_name, error_code = validate_tab_name(tab_name)
    if not validated_name then
        return error_code
    end
    local tab_data = create_empty_tab_data()
    local tab_data_json = vim.fn.json_encode(tab_data)
    local row_id = data.add_tab(validated_name, tab_data_json, workspace_id)
    if not row_id then
        log.error("add_tab_db: Failed to add tab to database")
        return "ADD_FAILED"
    end
    local workspace_info = {
        id = state.workspace_id,
        tab_ids = state.tab_ids or {},
        tab_active = state.tab_active,
    }
    table.insert(workspace_info.tab_ids, row_id)
    local workspace_tabs_raw = {
        tab_ids = workspace_info.tab_ids or {},
        tab_active = workspace_info.tab_active,
        updated_at = os.time(),
    }
    local workspace_tabs_json = vim.fn.json_encode(workspace_tabs_raw)
    local success = data.update_workspace_tabs(workspace_tabs_json, workspace_id)
    if not success then
        data.delete_tab(row_id, workspace_id)
        return "ADD_FAILED"
    end

    update_tabs_state_in_db()
    return row_id
end

local function rename_tab_db(tab_id, new_tab_name, workspace_id, selected_line_num)
    local validated_name, error_code = validate_tab_name(new_tab_name)
    if not validated_name then
        return error_code
    end
    local success = data.update_tab_name(tab_id, validated_name, workspace_id)
    if not success then
        log.warn("rename_tab_db: Failed to rename tab ID " .. tab_id)
        return nil
    end
    log.info(string.format("rename_tab_db: Tab ID %s renamed to '%s'", tab_id, validated_name))

    update_tabs_state_in_db()
    vim.schedule(function()
        M.init(selected_line_num)
    end)
    return true
end

local function delete_tab_db(tab_id, workspace_id, selected_line_num)
    local success = data.delete_tab(tab_id, workspace_id)
    if not success then
        log.warn("delete_tab_db: Failed to delete tab ID " .. tab_id)
        return nil
    end
    log.info("delete_tab_db: Tab ID " .. tab_id .. " deleted successfully")
    vim.schedule(function()
        local workspace_info = {
            id = state.workspace_id,
            tab_ids = state.tab_ids or {},
            tab_active = state.tab_active,
        }
        local index_to_remove = nil
        for i, id in ipairs(workspace_info.tab_ids) do
            if tostring(id) == tostring(tab_id) then
                index_to_remove = i
                break
            end
        end
        if index_to_remove then
            table.remove(workspace_info.tab_ids, index_to_remove)
        end
        local was_active_tab = tostring(workspace_info.tab_active) == tostring(tab_id)
        if was_active_tab then
            workspace_info.tab_active = nil
            state.file_active = nil
            session.clear_current_state()
            session.close_all_file_windows_and_buffers()
            local main_win = state.ui and state.ui.content and state.ui.content.win
            if main_win and vim.api.nvim_win_is_valid(main_win) then
                vim.api.nvim_set_current_win(main_win)
                vim.cmd("enew")
            end
        end
        local workspace_tabs_raw = {
            tab_ids = workspace_info.tab_ids or {},
            tab_active = workspace_info.tab_active,
            updated_at = os.time(),
        }
        local workspace_tabs_json = vim.fn.json_encode(workspace_tabs_raw)
        data.update_workspace_tabs(workspace_tabs_json, workspace_id)

        update_tabs_state_in_db()
        M.init(selected_line_num)
    end)
    return true
end

function M.handle_tab_add()
    local default_name = "Tab " .. tostring(#(state.tab_ids or {}) + 1)
    ui.create_input_field(state.lang.TAB_NAME, default_name, function(input_tab_name)
        if not input_tab_name or vim.trim(input_tab_name) == "" then
            notify.info(state.lang.OPERATION_CANCELLED)
            return
        end
        local result = add_tab_db(vim.trim(input_tab_name), state.workspace_id)
        if result == "LEN_NAME" then
            notify.error(state.lang.TAB_NAME_LEN)
        elseif result == "EXIST_NAME" then
            notify.error(state.lang.TAB_NAME_EXIST)
        elseif result == "ADD_FAILED" then
            notify.error(state.lang.TAB_ADD_FAILED)
        else
            notify.info(state.lang.TAB_ADDED_SUCCESS)
            M.init()
        end
    end)
end

function M.handle_tab_rename(ctx)
    common.rename_entity(
        "tab",
        common.get_id_at_cursor(cache.tab_ids_map),
        (cache.tabs_from_db and cache.tabs_from_db[common.get_id_at_cursor(cache.tab_ids_map)] or {}).name,
        state.workspace_id,
        function(id, new_name, ws_id)
            return rename_tab_db(id, new_name, ws_id, ctx and ctx.win and vim.api.nvim_win_get_cursor(ctx.win)[1] or 1)
        end
    )
end

function M.handle_tab_delete(ctx)
    local tab_id = common.get_id_at_cursor(cache.tab_ids_map)
    local entry
    for _, tab in ipairs(cache.tabs_from_db) do
        if tab.id == tab_id then
            entry = tab
            break
        end
    end
    common.delete_entity("tab", tab_id, entry and entry.name, state.workspace_id, function(del_id, ws_id)
        return delete_tab_db(del_id, ws_id, ctx and ctx.win and vim.api.nvim_win_get_cursor(ctx.win)[1] or 1)
    end)
end

function M.handle_tab_switch(opts)
    opts = opts or {}
    local tab_id_selected = common.get_id_at_cursor(cache.tab_ids_map)
    if not tab_id_selected then
        log.warn("switch_tab: No tab selected from list")
        return
    end
    if tostring(state.tab_active) == tostring(tab_id_selected) then
        log.info("switch_tab: Already in tab ID: " .. tostring(tab_id_selected))
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
        notify.error(state.lang.TAB_NOT_FOUND)
        return
    end
    local panel_win = state.ui and state.ui.content and state.ui.content.win
    local panel_is_valid = panel_win and vim.api.nvim_win_is_valid(panel_win)
    local cursor_pos = panel_is_valid and vim.api.nvim_win_get_cursor(panel_win)
    local current_line = cursor_pos and cursor_pos[1] or nil
    local prev_disable_state = state.disable_auto_close
    state.disable_auto_close = true
    local success = session.switch_tab(tab_id_selected)

    update_tabs_state_in_db()
    vim.defer_fn(function()
        if success then
            log.info("switch_tab: Successfully switched to tab " .. tostring(tab_id_selected))
            if opts.close_panel then
                state.disable_auto_close = prev_disable_state
                ui.close_all()
                if opts.go_to_files then
                    vim.schedule(function()
                        require("lvim-space.ui.files").init()
                    end)
                end
            else
                M.init(current_line)
                vim.defer_fn(function()
                    local new_panel_win = state.ui and state.ui.content and state.ui.content.win
                    if new_panel_win and vim.api.nvim_win_is_valid(new_panel_win) then
                        vim.api.nvim_set_current_win(new_panel_win)
                        if current_line then
                            pcall(vim.api.nvim_win_set_cursor, new_panel_win, { current_line, 0 })
                        end
                    end
                end, 50)
            end
        else
            notify.error(state.lang.TAB_SWITCH_FAILED)
            state.disable_auto_close = prev_disable_state
        end
    end, 100)
end

function M.navigate_to_projects()
    capture_current_window()
    ui.close_all()
    require("lvim-space.ui.projects").init()
end

function M.navigate_to_workspaces()
    capture_current_window()
    ui.close_all()
    require("lvim-space.ui.workspaces").init()
end

function M.navigate_to_files()
    if not state.tab_active then
        notify.info(state.lang.TAB_NOT_ACTIVE)
        return
    end
    capture_current_window()
    ui.close_all()
    require("lvim-space.ui.files").init()
end

local function setup_keymaps(ctx)
    local keymap_opts = { buffer = ctx.buf, noremap = true, silent = true, nowait = true }
    vim.keymap.set("n", config.keymappings.action.add, M.handle_tab_add, keymap_opts)
    vim.keymap.set("n", config.keymappings.action.rename, function()
        M.handle_tab_rename(ctx)
    end, keymap_opts)
    vim.keymap.set("n", config.keymappings.action.delete, function()
        M.handle_tab_delete(ctx)
    end, keymap_opts)
    vim.keymap.set("n", config.keymappings.action.switch, function()
        M.handle_tab_switch({ close_panel = false })
    end, keymap_opts)
    vim.keymap.set("n", "<CR>", function()
        M.handle_tab_switch({ close_panel = true, go_to_files = true })
    end, keymap_opts)
    vim.keymap.set("n", "<Space>", function()
        M.handle_tab_switch({ close_panel = false })
    end, keymap_opts)
    vim.keymap.set("n", config.keymappings.global.projects, M.navigate_to_projects, keymap_opts)
    vim.keymap.set("n", config.keymappings.global.workspaces, M.navigate_to_workspaces, keymap_opts)
    vim.keymap.set("n", config.keymappings.global.files, M.navigate_to_files, keymap_opts)
end

M.init = function(selected_line_num)
    capture_current_window()

    if not state.project_id then
        notify.error(state.lang.PROJECT_NOT_ACTIVE)
        common.open_entity_error("file", "PROJECT_NOT_ACTIVE")
        common.setup_error_navigation("PROJECT_NOT_ACTIVE", last_real_win)
        return
    end

    if not state.workspace_id then
        notify.error(state.lang.WORKSPACE_NOT_ACTIVE)
        common.open_entity_error("file", "WORKSPACE_NOT_ACTIVE")
        common.setup_error_navigation("WORKSPACE_NOT_ACTIVE", last_real_win)
        return
    end

    cache.tabs_from_db = data.find_tabs(state.workspace_id) or {}

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
    local ctx = common.init_entity_list(
        "tab",
        cache.tabs_from_db,
        cache.tab_ids_map,
        M.init,
        state.tab_active,
        "id",
        selected_line_num,
        function(tab_entry)
            local buffer_count = get_buffer_count(tab_entry)
            local buffer_count_display = utils.to_superscript and utils.to_superscript(buffer_count) or ""
            return (tab_entry.name or "???") .. buffer_count_display
        end
    )
    if not ctx then
        log.error("tabs.M.init: common.init_entity_list returned no context")
        return
    end
    cache.ctx = ctx
    if ctx.win and vim.api.nvim_win_is_valid(ctx.win) then
        local win_config = vim.api.nvim_win_get_config(ctx.win)
        win_config.title = " " .. state.lang.TABS .. " "
        pcall(vim.api.nvim_win_set_config, ctx.win, win_config)
    end
    setup_keymaps(ctx)
end

M.get_current_tab_info = function()
    if not state.tab_active or not state.workspace_id then
        return nil
    end
    return data.find_tab_by_id(state.tab_active, state.workspace_id)
end

M.switch_to_tab_by_name = function(tab_name, workspace_id)
    local target_workspace_id = workspace_id or state.workspace_id
    if not target_workspace_id then
        return false
    end

    local tabs = data.find_tabs(target_workspace_id) or {}
    for _, tab in ipairs(tabs) do
        if tab.name == tab_name then
            update_tabs_state_in_db()
            return session.switch_tab(tab.id)
        end
    end
    return false
end

return M
