local config = require("lvim-space.config")
local notify = require("lvim-space.api.notify")
local state = require("lvim-space.api.state")
local data = require("lvim-space.api.data")
local ui = require("lvim-space.ui")
local utils = require("lvim-space.utils")
local common = require("lvim-space.ui.common")
local session = require("lvim-space.core.session")
local tabs = require("lvim-space.ui.tabs")
local files = require("lvim-space.ui.files")
local log = require("lvim-space.api.log")

local M = {}
local cache = { workspace_ids_map = {}, workspaces_from_db = {}, ctx = nil, project_display_name = "" }
local last_real_win = nil

local function capture_current_window()
    local current_win = vim.api.nvim_get_current_win()
    if not ui.is_plugin_window(current_win) and vim.api.nvim_win_is_valid(current_win) then
        last_real_win = current_win
        log.debug("Remembered active window: " .. tostring(last_real_win))
    end
end

local function validate_workspace_name(workspace_name)
    local ok, err = common.validate_entity_name("workspace", workspace_name)
    if not ok then
        return nil, err
    end
    return vim.trim(workspace_name), nil
end

local function create_empty_workspace_tabs()
    return { tab_ids = {}, tab_active = nil, created_at = os.time(), updated_at = os.time() }
end

local function update_workspace_state_in_db()
    if not config.autosave or not state.workspace_id or not state.project_id then
        return
    end

    data.set_workspace_active(state.workspace_id, state.project_id)

    local ws = data.find_workspace_by_id(state.workspace_id, state.project_id)
    if ws then
        local tabs_json = ws.tabs and vim.fn.json_decode(ws.tabs) or {}
        tabs_json.tab_active = state.tab_active
        tabs_json.tab_ids = state.tab_ids or {}
        tabs_json.updated_at = os.time()
        data.update_workspace_tabs(vim.fn.json_encode(tabs_json), state.workspace_id)
    end
end

local function add_workspace_db(workspace_name, project_id)
    local validated_name, error_code = validate_workspace_name(workspace_name)
    if not validated_name then
        return error_code
    end
    local initial_tabs_structure = create_empty_workspace_tabs()
    local initial_tabs_json = vim.fn.json_encode(initial_tabs_structure)
    local result = data.add_workspace(validated_name, initial_tabs_json, project_id)
    if type(result) == "number" and result > 0 then
        vim.schedule(function()
            M.init()
        end)
        return result
    elseif type(result) == "string" then
        return result
    end
    return nil
end

local function rename_workspace_db(workspace_id, new_workspace_name, project_id, selected_line_num)
    local validated_name, error_code = validate_workspace_name(new_workspace_name)
    if not validated_name then
        return error_code
    end
    local status = data.update_workspace_name(workspace_id, validated_name, project_id)
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

local function space_load_session(workspace_id, selected_line)
    if not cache.ctx or not cache.ctx.buf then
        return
    end
    state.workspace_id = workspace_id
    local workspace = data.find_workspace_by_id(workspace_id, state.project_id)
    local workspace_tabs = workspace and workspace.tabs and vim.fn.json_decode(workspace.tabs) or {}
    state.tab_ids = workspace_tabs.tab_ids or {}
    state.tab_active = workspace_tabs.tab_active
    if config.autosave then
        update_workspace_state_in_db()
    end
    if not state.tab_active then
        M.init(selected_line)
        return
    end
    local old_disable_auto_close = state.disable_auto_close
    state.disable_auto_close = true
    local augroup_name = "LvimSpaceCursorBlend"
    local space_restore_augroup = vim.api.nvim_create_augroup("LvimSpaceRestore", { clear = true })
    vim.api.nvim_clear_autocmds({ group = augroup_name })
    vim.api.nvim_create_autocmd({ "BufEnter", "WinEnter" }, {
        group = space_restore_augroup,
        callback = function()
            vim.api.nvim_clear_autocmds({ group = space_restore_augroup })
            vim.schedule(function()
                M.init(selected_line)
                local cursor_group = vim.api.nvim_create_augroup(augroup_name, { clear = true })
                if state.ui and state.ui.content and vim.api.nvim_win_is_valid(state.ui.content.win) then
                    vim.cmd("hi Cursor blend=100")
                    local main_win = state.ui.content.win
                    vim.api.nvim_create_autocmd({ "WinLeave", "WinEnter" }, {
                        group = cursor_group,
                        callback = function()
                            local current_win = vim.api.nvim_get_current_win()
                            local blend = current_win == main_win and 100 or 0
                            vim.cmd("hi Cursor blend=" .. blend)
                        end,
                    })
                    vim.api.nvim_set_current_win(state.ui.content.win)
                    if selected_line then
                        pcall(vim.api.nvim_win_set_cursor, state.ui.content.win, { selected_line, 0 })
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
    local workspace_tabs = workspace and workspace.tabs and vim.fn.json_decode(workspace.tabs) or {}
    state.tab_ids = workspace_tabs.tab_ids or {}
    state.tab_active = workspace_tabs.tab_active
    if config.autosave then
        update_workspace_state_in_db()
    end
    ui.close_all()
    if state.tab_active then
        session.restore_state(state.tab_active, true)
        vim.schedule(function()
            files.init()
        end)
    else
        vim.schedule(function()
            tabs.init()
        end)
    end
end

function M.handle_workspace_add()
    local default_name = "Workspace " .. tostring(#(data.find_workspaces(state.project_id) or {}) + 1)
    ui.create_input_field(state.lang.WORKSPACE_NAME, default_name, function(input_workspace_name)
        if not input_workspace_name or vim.trim(input_workspace_name) == "" then
            notify.info(state.lang.OPERATION_CANCELLED)
            return
        end
        local result = add_workspace_db(vim.trim(input_workspace_name), state.project_id)
        if result == "LEN_NAME" then
            notify.error(state.lang.WORKSPACE_NAME_LEN)
        elseif result == "EXIST_NAME" then
            notify.error(state.lang.WORKSPACE_NAME_EXIST)
        elseif not result then
            notify.error(state.lang.WORKSPACE_ADD_FAILED)
        else
            notify.info(state.lang.WORKSPACE_ADDED_SUCCESS)
        end
    end)
end

function M.handle_workspace_rename(ctx)
    common.rename_entity(
        "workspace",
        common.get_id_at_cursor(cache.workspace_ids_map),
        (cache.workspaces_from_db and cache.workspaces_from_db[common.get_id_at_cursor(cache.workspace_ids_map)] or {}).name,
        state.project_id,
        function(id, new_name, proj_id)
            return rename_workspace_db(
                id,
                new_name,
                proj_id,
                ctx and ctx.win and vim.api.nvim_win_get_cursor(ctx.win)[1] or 1
            )
        end
    )
end

function M.handle_workspace_delete(ctx)
    local ws_id = common.get_id_at_cursor(cache.workspace_ids_map)
    local entry
    for _, workspace in ipairs(cache.workspaces_from_db) do
        if workspace.id == ws_id then
            entry = workspace
            break
        end
    end
    common.delete_entity("workspace", ws_id, entry and entry.name, state.project_id, function(del_id, proj_id)
        return delete_workspace_db(del_id, proj_id, ctx and ctx.win and vim.api.nvim_win_get_cursor(ctx.win)[1] or 1)
    end)
end

function M.handle_workspace_switch(opts)
    local workspace_id_selected = common.get_id_at_cursor(cache.workspace_ids_map)
    if not workspace_id_selected then
        return
    end
    local selected_line = cache.ctx
            and cache.ctx.win
            and vim.api.nvim_win_is_valid(cache.ctx.win)
            and vim.api.nvim_win_get_cursor(cache.ctx.win)[1]
        or nil
    if opts and opts.space_mode then
        space_load_session(workspace_id_selected, selected_line)
        return
    end
    if opts and opts.enter_mode then
        enter_navigate_to_last_panel(workspace_id_selected)
        return
    end
    state.workspace_id = workspace_id_selected
    local workspace = data.find_workspace_by_id(state.workspace_id, state.project_id)
    local workspace_tabs = workspace and workspace.tabs and vim.fn.json_decode(workspace.tabs) or {}
    state.tab_ids = workspace_tabs.tab_ids or {}
    state.tab_active = workspace_tabs.tab_active
    if config.autosave then
        update_workspace_state_in_db()
    end
    if opts and opts.close_panel then
        ui.close_all()
    end
    tabs.init()
end

function M.navigate_to_projects()
    capture_current_window()
    ui.close_all()
    require("lvim-space.ui.projects").init()
end

function M.navigate_to_tabs()
    if not state.workspace_id then
        notify.info(state.lang.WORKSPACE_NOT_ACTIVE)
        return
    end
    capture_current_window()
    ui.close_all()
    tabs.init()
end

function M.navigate_to_files()
    if not state.workspace_id then
        notify.info(state.lang.WORKSPACE_NOT_ACTIVE)
        return
    end
    if not state.tab_active then
        notify.info(state.lang.TAB_NOT_ACTIVE)
        return
    end
    capture_current_window()
    ui.close_all()
    files.init()
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
    vim.keymap.set("n", config.keymappings.global.projects, M.navigate_to_projects, keymap_opts)
    vim.keymap.set("n", config.keymappings.global.tabs, M.navigate_to_tabs, keymap_opts)
    vim.keymap.set("n", config.keymappings.global.files, M.navigate_to_files, keymap_opts)
end

M.init = function(selected_line_num, opts)
    capture_current_window()

    if not state.project_id then
        notify.error(state.lang.PROJECT_NOT_ACTIVE)
        common.open_entity_error("workspace", "PROJECT_NOT_ACTIVE")
        ui.open_actions(state.lang.INFO_LINE_GENERIC_QUIT)
        return
    end

    opts = opts or {}
    local select_workspace = (opts.select_workspace ~= false)
    if not state.project_id then
        notify.error(state.lang.WORKSPACE_NOT_ACTIVE)
        local buf, _ = ui.open_main({ " " .. state.lang.WORKSPACE_NOT_ACTIVE }, state.lang.WORKSPACES, 1)
        if buf then
            vim.bo[buf].buftype = "nofile"
        end
        ui.open_actions(state.lang.INFO_LINE_GENERIC_QUIT)
        return
    end

    cache.workspaces_from_db = data.find_workspaces(state.project_id) or {}
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

    local active_id = select_workspace and state.workspace_id or nil
    local entity_selected_line = selected_line_num
    if not selected_line_num and active_id then
        for idx, ws in ipairs(cache.workspaces_from_db) do
            if tostring(ws.id) == tostring(active_id) then
                entity_selected_line = idx
                break
            end
        end
    end

    local ctx = common.init_entity_list(
        "workspace",
        cache.workspaces_from_db,
        cache.workspace_ids_map,
        M.init,
        active_id,
        "id",
        entity_selected_line,
        function(workspace_entry)
            local tab_count = get_tab_count(workspace_entry)
            local tab_count_display = utils.to_superscript(tab_count)
            return workspace_entry.name .. tab_count_display
        end,
        function(entity, active_id_in_list)
            if not select_workspace then
                return false
            end
            return active_id_in_list and tostring(entity.id) == tostring(active_id_in_list)
        end
    )
    if not ctx then
        log.error("workspaces.M.init: common.init_entity_list returned no context")
        return
    end
    cache.ctx = ctx
    if ctx.win and vim.api.nvim_win_is_valid(ctx.win) then
        local win_config = vim.api.nvim_win_get_config(ctx.win)
        win_config.title = " " .. state.lang.WORKSPACES .. " "
        pcall(vim.api.nvim_win_set_config, ctx.win, win_config)
    end
    setup_keymaps(ctx)
end

M.get_current_workspace_info = function()
    if not state.workspace_id or not state.project_id then
        return nil
    end
    return data.find_workspace_by_id(state.workspace_id, state.project_id)
end

M.switch_to_workspace_by_name = function(workspace_name, project_id)
    local target_project_id = project_id or state.project_id
    if not target_project_id then
        return false
    end
    local workspaces = data.find_workspaces(target_project_id) or {}
    for _, workspace in ipairs(workspaces) do
        if workspace.name == workspace_name then
            M.handle_workspace_switch({})
            return true
        end
    end
    return false
end

return M
