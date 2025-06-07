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
local cache = { project_ids_map = {}, projects_from_db = {}, ctx = nil }
local last_real_win = nil
local validation_cache = {}

local function capture_current_window()
    local current_win = vim.api.nvim_get_current_win()
    if not ui.is_plugin_window(current_win) and vim.api.nvim_win_is_valid(current_win) then
        last_real_win = current_win
        log.debug("Remembered active window: " .. tostring(last_real_win))
    end
end

local function validate_project_name(project_name)
    local ok, err = common.validate_entity_name("project", project_name)
    if not ok then
        return nil, err
    end
    return vim.trim(project_name), nil
end

local function validate_project_path(project_path)
    if not project_path or vim.trim(project_path) == "" then
        return nil, "PATH_EMPTY"
    end
    local cache_key = project_path
    if validation_cache[cache_key] then
        return validation_cache[cache_key].path, validation_cache[cache_key].error
    end
    local normalized_path = vim.trim(project_path):gsub("/$", "")
    normalized_path = vim.fn.expand(normalized_path)
    normalized_path = vim.fn.fnamemodify(normalized_path, ":p")
    if not normalized_path:match("/$") then
        normalized_path = normalized_path .. "/"
    end
    local error_code = nil
    if vim.fn.isdirectory(normalized_path) ~= 1 then
        error_code = "PATH_NOT_FOUND"
    elseif not utils.has_permission(normalized_path) then
        error_code = "PATH_NO_ACCESS"
    elseif data.is_project_path_exist(normalized_path) then
        error_code = "PATH_EXISTS"
    end
    validation_cache[cache_key] = {
        path = error_code and nil or normalized_path,
        error = error_code,
    }
    return validation_cache[cache_key].path, validation_cache[cache_key].error
end

local function add_project_db(project_path, project_name)
    local validated_path, path_error = validate_project_path(project_path)
    if not validated_path then
        return nil, path_error
    end
    local validated_name, name_error = validate_project_name(project_name)
    if not validated_name then
        return nil, name_error
    end
    local existing_projects = data.is_project_name_exist(validated_name)
    if existing_projects and #existing_projects > 0 then
        return nil, "NAME_EXISTS"
    end
    local row_id = data.add_project(validated_path, validated_name)
    if not row_id then
        log.error("add_project_db: Failed to add project to database")
        return nil, "ADD_FAILED"
    end
    log.info(
        string.format(
            "add_project_db: Successfully added project '%s' at '%s' (ID: %s)",
            validated_name,
            validated_path,
            row_id
        )
    )
    validation_cache = {}
    return row_id, nil
end

local function rename_project_db(project_id, new_project_name, _, selected_line_num)
    local validated_name, error_code = validate_project_name(new_project_name)
    if not validated_name then
        return error_code
    end
    local existing_projects = data.is_project_name_exist(validated_name)
    if existing_projects and #existing_projects > 0 then
        local is_same_project = false
        for _, existing_id in ipairs(existing_projects) do
            if tostring(existing_id) == tostring(project_id) then
                is_same_project = true
                break
            end
        end
        if not is_same_project then
            return "EXIST_NAME"
        end
    end
    local success = data.update_project_name(project_id, validated_name)
    if not success then
        log.warn("rename_project_db: Failed to rename project ID " .. project_id)
        return nil
    end
    log.info(string.format("rename_project_db: Project ID %s renamed to '%s'", project_id, validated_name))
    vim.schedule(function()
        M.init(selected_line_num)
    end)
    return true
end

local function delete_project_db(project_id, _, selected_line_num)
    local success = data.delete_project(project_id)
    if not success then
        log.warn("delete_project_db: Failed to delete project ID " .. project_id)
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
        end
        M.init(selected_line_num)
    end)
    return true
end

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
            local tabs_json = ws.tabs and vim.fn.json_decode(ws.tabs) or {}
            tabs_json.tab_active = state.tab_active
            tabs_json.tab_ids = state.tab_ids
            data.update_workspace_tabs(vim.fn.json_encode(tabs_json), state.workspace_id)
        end
    end
end

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
    if not selected_ws then
        for _, ws in ipairs(all_workspaces) do
            if tostring(ws.project_id) == tostring(project_id) then
                selected_ws = ws
                break
            end
        end
    end
    if selected_ws then
        state.workspace_id = selected_ws.id
        local tabs = selected_ws.tabs and vim.fn.json_decode(selected_ws.tabs) or {}
        state.tab_active = tabs.tab_active
        state.tab_ids = tabs.tab_ids or {}
    else
        state.workspace_id = nil
        state.tab_active = nil
        state.tab_ids = {}
    end

    update_project_state_in_db()
end

local function space_load_project(project_id, selected_line)
    local selected_project = data.find_project_by_id(project_id)
    if not selected_project then
        notify.error(state.lang.PROJECT_NOT_FOUND)
        return
    end
    if vim.fn.isdirectory(selected_project.path) ~= 1 then
        notify.error(state.lang.DIRECTORY_NOT_FOUND)
        return
    end
    if not utils.has_permission(selected_project.path) then
        notify.error(state.lang.DIRECTORY_NOT_ACCESS)
        return
    end
    if state.tab_active then
        session.save_current_state(state.tab_active, true)
    end
    local old_disable_auto_close = state.disable_auto_close
    state.disable_auto_close = true

    local success, error_msg = pcall(function()
        vim.api.nvim_set_current_dir(selected_project.path)
    end)
    if not success then
        notify.error(state.lang.CHANGE_DIRECTORY_FAILED .. tostring(error_msg))
        state.disable_auto_close = old_disable_auto_close
        return
    end

    state.project_id = project_id
    set_active_workspace_for_project(project_id)

    local augroup_name = "LvimSpaceCursorBlend"
    local space_restore_augroup = vim.api.nvim_create_augroup("LvimSpaceProjectRestore", { clear = true })

    vim.api.nvim_clear_autocmds({ group = augroup_name })

    if state.workspace_id and state.tab_active then
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
                    notify.info(state.lang.PROJECT_SWITCHED_TO .. selected_project.name)
                end)
            end,
            once = true,
        })
        session.restore_state(state.tab_active, true)
    else
        state.workspace_id = nil
        state.tab_ids = {}
        state.tab_active = nil
        session.clear_current_state()
        vim.schedule(function()
            M.init(selected_line)
            if state.ui and state.ui.content and vim.api.nvim_win_is_valid(state.ui.content.win) then
                vim.cmd("hi Cursor blend=100")
                vim.api.nvim_set_current_win(state.ui.content.win)
                if selected_line then
                    pcall(vim.api.nvim_win_set_cursor, state.ui.content.win, { selected_line, 0 })
                end
            end
            state.disable_auto_close = old_disable_auto_close
            notify.info(state.lang.PROJECT_SWITCHED_TO .. selected_project.name)
        end)
    end

    update_project_state_in_db()
end

local function enter_navigate_next(project_id)
    local selected_project = data.find_project_by_id(project_id)
    if not selected_project then
        notify.error(state.lang.PROJECT_NOT_FOUND)
        return
    end
    if vim.fn.isdirectory(selected_project.path) ~= 1 then
        notify.error(state.lang.DIRECTORY_NOT_FOUND)
        return
    end
    if not utils.has_permission(selected_project.path) then
        notify.error(state.lang.DIRECTORY_NOT_ACCESS)
        return
    end
    if state.tab_active then
        session.save_current_state(state.tab_active, true)
    end
    local success, error_msg = pcall(function()
        vim.api.nvim_set_current_dir(selected_project.path)
    end)
    if not success then
        notify.error(state.lang.CHANGE_DIRECTORY_FAILED .. tostring(error_msg))
        return
    end
    state.project_id = project_id
    set_active_workspace_for_project(project_id)

    state.disable_auto_close = true
    ui.close_all()
    notify.info(state.lang.PROJECT_SWITCHED_TO .. selected_project.name)
    vim.schedule(function()
        if state.workspace_id and state.tab_active then
            session.restore_state(state.tab_active, true)
            vim.defer_fn(function()
                state.disable_auto_close = false
                require("lvim-space.ui.files").init()
            end, 100)
        elseif state.workspace_id then
            vim.defer_fn(function()
                state.disable_auto_close = false
                require("lvim-space.ui.tabs").init()
            end, 50)
        else
            state.workspace_id = nil
            state.tab_ids = {}
            state.tab_active = nil
            vim.defer_fn(function()
                state.disable_auto_close = false
                require("lvim-space.ui.workspaces").init(nil, { select_workspace = false })
            end, 50)
        end
    end)

    update_project_state_in_db()
end

function M.handle_project_add()
    M.add_project()
end

function M.handle_project_rename(ctx)
    common.rename_entity(
        "project",
        common.get_id_at_cursor(cache.project_ids_map),
        (cache.projects_from_db and cache.projects_from_db[common.get_id_at_cursor(cache.project_ids_map)] or {}).name,
        nil,
        function(id, new_name, _)
            return rename_project_db(
                id,
                new_name,
                nil,
                ctx and ctx.win and vim.api.nvim_win_get_cursor(ctx.win)[1] or 1
            )
        end
    )
end

function M.handle_project_delete(ctx)
    local proj_id = common.get_id_at_cursor(cache.project_ids_map)
    local entry
    for _, project in ipairs(cache.projects_from_db) do
        if project.id == proj_id then
            entry = project
            break
        end
    end
    common.delete_entity("project", proj_id, entry and entry.name, nil, function(id, _)
        return delete_project_db(id, nil, ctx and ctx.win and vim.api.nvim_win_get_cursor(ctx.win)[1] or 1)
    end)
end

function M.handle_project_switch(opts)
    local project_id_selected = common.get_id_at_cursor(cache.project_ids_map)
    if not project_id_selected then
        log.warn("switch_project: No project selected from list")
        return
    end
    local selected_line = cache.ctx
            and cache.ctx.win
            and vim.api.nvim_win_is_valid(cache.ctx.win)
            and vim.api.nvim_win_get_cursor(cache.ctx.win)[1]
        or nil
    if opts and opts.space_mode then
        space_load_project(project_id_selected, selected_line)
        return
    end
    if opts and opts.enter_mode then
        enter_navigate_next(project_id_selected)
        return
    end
    if tostring(state.project_id) == tostring(project_id_selected) then
        log.info("switch_project: Already in project ID: " .. tostring(project_id_selected))
        ui.close_all()
        return
    end
    space_load_project(project_id_selected, selected_line)
end

function M.navigate_to_workspaces()
    capture_current_window()
    if not state.project_id then
        notify.info(state.lang.PROJECT_NOT_ACTIVE)
        return
    end
    ui.close_all()
    require("lvim-space.ui.workspaces").init(nil, { select_workspace = true })
end

function M.navigate_to_tabs()
    capture_current_window()
    if not state.project_id then
        notify.info(state.lang.PROJECT_NOT_ACTIVE)
        return
    end
    ui.close_all()
    require("lvim-space.ui.tabs").init()
end

function M.navigate_to_files()
    capture_current_window()
    if not state.project_id then
        notify.info(state.lang.PROJECT_NOT_ACTIVE)
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
    log.debug("projects.M.init: Retrieving all projects")
    cache.projects_from_db = data.find_projects() or {}
    cache.project_ids_map = {}
    local ctx = common.init_entity_list(
        "project",
        cache.projects_from_db,
        cache.project_ids_map,
        M.init,
        state.project_id,
        "id",
        selected_line_num,
        function(project_entry)
            return string.format("%s [%s]", project_entry.name or "???", project_entry.path or "???")
        end
    )
    if not ctx then
        log.error("projects.M.init: common.init_entity_list returned no context")
        return
    end
    cache.ctx = ctx
    if ctx.win and vim.api.nvim_win_is_valid(ctx.win) then
        local win_config = vim.api.nvim_win_get_config(ctx.win)
        win_config.title = " " .. state.lang.PROJECTS .. " "
        pcall(vim.api.nvim_win_set_config, ctx.win, win_config)
    end
    setup_keymaps(ctx)
end

M.add_project = function()
    local current_dir = vim.fn.getcwd()
    ui.create_input_field(state.lang.PROJECT_PATH, current_dir, function(input_project_path)
        if not input_project_path or vim.trim(input_project_path) == "" then
            notify.info(state.lang.OPERATION_CANCELLED)
            return
        end
        local validated_path, path_error = validate_project_path(vim.trim(input_project_path))
        if not validated_path then
            local error_messages = {
                PATH_EMPTY = state.lang.PROJECT_PATH_EMPTY,
                PATH_NOT_FOUND = state.lang.DIRECTORY_NOT_FOUND,
                PATH_NO_ACCESS = state.lang.DIRECTORY_NOT_ACCESS,
                PATH_EXISTS = state.lang.PROJECT_PATH_EXIST,
            }
            notify.error(error_messages[path_error])
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
            local _, error_code = add_project_db(validated_path, vim.trim(input_project_name))
            if error_code then
                local error_messages = {
                    LEN_NAME = state.lang.PROJECT_NAME_LEN,
                    NAME_EXISTS = state.lang.PROJECT_NAME_EXIST,
                    ADD_FAILED = state.lang.PROJECT_ADD_FAILED,
                }
                notify.error(error_messages[error_code])
                if error_code == "LEN_NAME" or error_code == "NAME_EXISTS" then
                    vim.schedule(function()
                        ui.create_input_field(state.lang.PROJECT_NAME, default_name, function(retry_name)
                            if retry_name and vim.trim(retry_name) ~= "" then
                                local _, retry_error = add_project_db(validated_path, vim.trim(retry_name))
                                if retry_error then
                                    notify.error(error_messages[retry_error])
                                else
                                    notify.info(state.lang.PROJECT_ADDED_SUCCESS)
                                end
                                M.init()
                            end
                        end)
                    end)
                else
                    M.init()
                end
            else
                notify.info(state.lang.PROJECT_ADDED_SUCCESS)
                M.init()
            end
        end)
    end)
end

M.clear_validation_cache = function()
    validation_cache = {}
end

M.get_current_project_info = function()
    if not state.project_id then
        return nil
    end
    return data.find_project_by_id(state.project_id)
end

M.switch_to_project_by_name = function(project_name)
    local projects = data.find_projects() or {}
    for _, project in ipairs(projects) do
        if project.name == project_name then
            cache.project_ids_map[1] = project.id
            M.handle_project_switch({ space_mode = true })
            return true
        end
    end
    return false
end

return M
