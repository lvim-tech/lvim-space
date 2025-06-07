local config = require("lvim-space.config")
local notify = require("lvim-space.api.notify")
local state = require("lvim-space.api.state")
local ui = require("lvim-space.ui")

local M = {}

M.entity_types = {
    project = {
        name = "project",
        table = "projects",
        state_id = "project_id",
        empty_message = "PROJECTS_EMPTY",
        info_empty = "INFO_LINE_PROJECTS_EMPTY",
        info = "INFO_LINE_PROJECTS",
        title = "PROJECTS",
        min_name_len = 3,
        name_len_error = "PROJECT_NAME_LEN",
        name_exist_error = "PROJECT_NAME_EXIST",
        add_failed = "PROJECT_ADD_FAILED",
        rename_failed = "PROJECT_RENAME_FAILED",
        delete_confirm = "PROJECT_DELETE",
        delete_failed = "PROJECT_DELETE_FAILED",
        not_active = "PROJECT_NOT_ACTIVE",
        error_message = "PROJECT_ERROR",
    },
    workspace = {
        name = "workspace",
        table = "workspaces",
        state_id = "workspace_id",
        empty_message = "WORKSPACES_EMPTY",
        info_empty = "INFO_LINE_WORKSPACES_EMPTY",
        info = "INFO_LINE_WORKSPACES",
        title = "WORKSPACES",
        min_name_len = 3,
        name_len_error = "WORKSPACE_NAME_LEN",
        name_exist_error = "WORKSPACE_NAME_EXIST",
        add_failed = "WORKSPACE_ADD_FAILED",
        rename_failed = "WORKSPACE_RENAME_FAILED",
        delete_confirm = "WORKSPACE_DELETE",
        delete_failed = "WORKSPACE_DELETE_FAILED",
        not_active = "WORKSPACE_NOT_ACTIVE",
        error_message = "WORKSPACE_ERROR",
    },
    tab = {
        name = "tab",
        table = "tabs",
        state_id = "tab_active",
        empty_message = "TABS_EMPTY",
        info_empty = "INFO_LINE_TABS_EMPTY",
        info = "INFO_LINE_TABS",
        title = "TABS",
        min_name_len = 1,
        name_len_error = "TAB_NAME_LEN",
        name_exist_error = "TAB_NAME_EXIST",
        add_failed = "TAB_ADD_FAILED",
        rename_failed = "TAB_RENAME_FAILED",
        delete_confirm = "TAB_DELETE",
        delete_failed = "TAB_DELETE_FAILED",
        not_active = "TAB_NOT_ACTIVE",
        error_message = "TAB_ERROR",
    },
    file = {
        name = "file",
        table = "files",
        state_id = "file_active",
        empty_message = "FILES_EMPTY",
        info_empty = "INFO_LINE_FILES_EMPTY",
        info = "INFO_LINE_FILES",
        title = "FILES",
        min_name_len = 1,
        name_len_error = "FILE_PATH_LEN",
        name_exist_error = "FILE_PATH_EXIST",
        add_failed = "FILE_ADD_FAILED",
        rename_failed = "FILE_RENAME_FAILED",
        delete_confirm = "FILE_DELETE",
        delete_failed = "FILE_DELETE_FAILED",
        not_active = "FILE_NOT_ACTIVE",
        error_message = "FILE_ERROR",
    },
}

local icon_cache = {}
local function get_entity_icon(type_name, active, empty)
    local key = type_name .. "_" .. tostring(active) .. "_" .. tostring(empty)
    if icon_cache[key] then
        return icon_cache[key]
    end
    local icons = config.ui.icons or {}
    local icon
    if empty then
        icon = icons.empty or "󰇘 "
    else
        local m = {
            project = active and (icons.project_active or " ") or (icons.project or " "),
            workspace = active and (icons.workspace_active or " ") or (icons.workspace or " "),
            tab = active and (icons.tab_active or " ") or (icons.tab or " "),
            file = active and (icons.file_active or " ") or (icons.file or " "),
        }
        icon = m[type_name] or (active and "➤ " or "➤ ")
    end
    icon_cache[key] = icon
    return icon
end

local function determine_active(type_def, ent, active_id, custom)
    if custom then
        return custom(ent, active_id)
    end
    if type_def.name == "workspace" then
        return ent.active == true or ent.active == 1
    end
    local id = ent[type_def.id_field or "id"]
    return tostring(id) == tostring(active_id)
end

local function format_line(ent, type_name, active, fmt)
    local s = fmt and fmt(ent) or ent.name or ent.path or "???"
    s = s:gsub("^[>%s▶󰋜󰉋󰏘󰉌󰓩󰎃󰈙󰈚]*", "")
    s = vim.trim(s)
    return get_entity_icon(type_name, active, false) .. s
end

local function safe_get_cursor(win)
    if not win or not vim.api.nvim_win_is_valid(win) then
        return 1
    end
    local ok, cur = pcall(vim.api.nvim_win_get_cursor, win)
    return ok and cur[1] or 1
end

local function format_error_message(message)
    local error_icon = config.ui and config.ui.icons and config.ui.icons.empty or " "
    return error_icon .. message
end

M.get_id_at_cursor = function(list)
    if type(list) ~= "table" then
        return nil
    end
    local win = state.ui and state.ui.content and state.ui.content.win or 0
    local line = safe_get_cursor(win)
    return list[line]
end

M.add_entity = function(type_name, cb, parent)
    local dt = M.entity_types[type_name]
    if not dt then
        notify.error(state.lang.UNKNOWN_ENTITY_TYPE)
        return
    end
    ui.create_input_field(state.lang[string.upper(type_name) .. "_NAME"], "", function(name)
        if not name or vim.trim(name) == "" then
            notify.info(state.lang.OPERATION_CANCELLED)
            return
        end
        cb(vim.trim(name), parent)
    end)
end

M.rename_entity = function(type_name, id, cur, parent, cb)
    local dt = M.entity_types[type_name]
    if not dt then
        notify.error(state.lang.UNKNOWN_ENTITY_TYPE)
        return
    end
    ui.create_input_field(state.lang[string.upper(type_name) .. "_NEW_NAME"], cur or "", function(name)
        if not name or vim.trim(name) == "" then
            notify.info(state.lang.OPERATION_CANCELLED)
            return
        end
        local tname = vim.trim(name)
        if tname == cur then
            notify.info(state.lang.NO_CHANGES)
            return
        end
        local res = cb and cb(id, tname, parent) or nil
        if res == "LEN_NAME" then
            notify.error(state.lang[dt.name_len_error])
        elseif res == "EXIST_NAME" then
            notify.error(state.lang[dt.name_exist_error])
        elseif not res then
            notify.error(state.lang[dt.rename_failed])
        end
    end)
end

M.delete_entity = function(type_name, id, name, parent, cb)
    local dt = M.entity_types[type_name]
    if not dt then
        notify.error(state.lang.UNKNOWN_ENTITY_TYPE)
        return
    end
    local disp = name or "this item"
    ui.create_input_field(string.format(state.lang[dt.delete_confirm], disp), "", function(ans)
        if not ans then
            notify.info(state.lang.OPERATION_CANCELLED)
            return
        end
        local n = vim.trim(ans:lower())
        if n == "y" or n == "yes" then
            local res = cb and cb(id, parent) or nil
            if not res then
                notify.error(state.lang[dt.delete_failed])
            end
        else
            notify.info(state.lang.DELETION_CANCELLED)
        end
    end)
end

M.init_entity_list = function(type_name, ents, id_list, _, active_id, id_field, sel_line, fmt, custom)
    local dt = M.entity_types[type_name]
    if not dt then
        notify.error(state.lang.UNKNOWN_ENTITY_TYPE)
        return
    end
    ents = ents or {}
    id_list = id_list or {}
    local empty = #ents == 0
    local lines, found, cur_line = {}, false, 1
    dt.id_field = id_field or "id"
    for i, ent in ipairs(ents) do
        local active = determine_active(dt, ent, active_id, custom)
        table.insert(lines, format_line(ent, dt.name, active, fmt))
        id_list[i] = ent[dt.id_field]
        if active then
            cur_line, found = i, true
        end
    end
    if empty then
        table.insert(lines, get_entity_icon(dt.name, false, true) .. state.lang[dt.empty_message])
    elseif not found then
        state[dt.state_id] = nil
    end
    local cursor = math.max(1, math.min(sel_line or cur_line, #lines))
    local buf, win = ui.open_main(lines, state.lang[dt.title], cursor)
    if not buf or not win then
        notify.error(state.lang.FAILED_TO_CREATE_UI)
        return
    end
    vim.wo[win].signcolumn = "no"
    vim.bo[buf].modifiable = false
    vim.bo[buf].buftype = "nofile"
    ui.open_actions(empty and state.lang[dt.info_empty] or state.lang[dt.info])
    return { buf = buf, win = win, is_empty = empty, entities = ents, id_list = id_list, entity_type = dt }
end

M.open_entity_error = function(type_name, error_key)
    local dt = M.entity_types[type_name]
    if not dt then
        notify.error(state.lang.UNKNOWN_ENTITY_TYPE)
        return
    end

    local message = state.lang[error_key] or error_key
    local formatted_message = format_error_message(message)
    local buf, win = ui.open_main({ formatted_message }, state.lang[dt.title], 1)
    if buf then
        vim.bo[buf].buftype = "nofile"
    end
    return buf, win
end
M.validate_entity_name = function(type_name, name)
    local dt = M.entity_types[type_name]
    if not dt then
        return false, "Unknown entity type"
    end
    if not name or vim.trim(name) == "" then
        return false, "LEN_NAME"
    end
    if #vim.trim(name) < dt.min_name_len then
        return false, "LEN_NAME"
    end
    return true, nil
end

M.get_entity_type = function(type_name)
    return M.entity_types[type_name]
end

M.safe_ui_operation = function(name, fn, ...)
    local ok, res = pcall(fn, ...)
    if not ok then
        notify.error(state.lang.UI_OPERATION_FAILED .. name)
    end
    return res
end

M.refresh_entity_icons = function(buf, ents, type_name, active_id, custom)
    if not buf or not vim.api.nvim_buf_is_valid(buf) then
        return false
    end
    local dt = M.entity_types[type_name]
    if not dt then
        return false
    end
    local lines = {}
    for _, ent in ipairs(ents) do
        local active = determine_active(dt, ent, active_id, custom)
        table.insert(lines, format_line(ent, dt.name, active))
    end
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    return true
end

M.clear_icon_cache = function()
    icon_cache = {}
end

local function setup_error_navigation_keymaps(ctx, error_type)
    local buf = ctx.buf
    local opts = { buffer = buf, silent = true, nowait = true }
    vim.keymap.set("n", "q", function()
        require("lvim-space.ui").close_all()
        if ctx.last_real_win and vim.api.nvim_win_is_valid(ctx.last_real_win) then
            vim.api.nvim_set_current_win(ctx.last_real_win)
        end
    end, opts)
    vim.keymap.set("n", "<Esc>", function()
        require("lvim-space.ui").close_all()
        if ctx.last_real_win and vim.api.nvim_win_is_valid(ctx.last_real_win) then
            vim.api.nvim_set_current_win(ctx.last_real_win)
        end
    end, opts)
    if error_type == "PROJECT_NOT_ACTIVE" then
        vim.keymap.set("n", config.keymappings.global.projects or "p", function()
            require("lvim-space.ui.projects").init()
        end, opts)
    elseif error_type == "WORKSPACE_NOT_ACTIVE" then
        vim.keymap.set("n", config.keymappings.global.projects or "p", function()
            require("lvim-space.ui.projects").init()
        end, opts)

        if state.project_id then
            vim.keymap.set("n", config.keymappings.global.workspaces or "w", function()
                require("lvim-space.ui.workspaces").init()
            end, opts)
        end
    elseif error_type == "TAB_NOT_ACTIVE" then
        vim.keymap.set("n", config.keymappings.global.projects or "p", function()
            require("lvim-space.ui.projects").init()
        end, opts)

        if state.project_id then
            vim.keymap.set("n", config.keymappings.global.workspaces or "w", function()
                require("lvim-space.ui.workspaces").init()
            end, opts)
        end

        if state.project_id and state.workspace_id then
            vim.keymap.set("n", config.keymappings.global.tabs or "t", function()
                require("lvim-space.ui.tabs").init()
            end, opts)
        end
    end
end

local function get_error_info_line(error_type)
    local lang = state.lang
    if error_type == "PROJECT_NOT_ACTIVE" then
        return lang.INFO_LINE_PROJECT_ERROR
    elseif error_type == "WORKSPACE_NOT_ACTIVE" then
        if state.project_id then
            return lang.INFO_LINE_WORKSPACE_ERROR
        else
            return lang.INFO_LINE_PROJECT_ERROR
        end
    elseif error_type == "TAB_NOT_ACTIVE" then
        if state.project_id and state.workspace_id then
            return lang.INFO_LINE_TAB_ERROR
        elseif state.project_id then
            return lang.INFO_LINE_WORKSPACE_ERROR
        else
            return lang.INFO_LINE_PROJECT_ERROR
        end
    end
    return lang.INFO_LINE_GENERIC_QUIT
end

M.setup_error_navigation = function(error_type, last_real_win)
    local current_win = vim.api.nvim_get_current_win()
    local current_buf = vim.api.nvim_get_current_buf()
    local error_ctx = {
        win = current_win,
        buf = current_buf,
        error_state = error_type,
        last_real_win = last_real_win,
    }
    setup_error_navigation_keymaps(error_ctx, error_type)
    ui.open_actions(get_error_info_line(error_type))
end

return M
