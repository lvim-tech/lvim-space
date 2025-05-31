local config = require("lvim-space.config")
local notify = require("lvim-space.api.notify")
local state = require("lvim-space.api.state")
local ui = require("lvim-space.ui")

local M = {}

-- Enhanced entity type definitions with validation
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
    },
}

-- Enhanced cursor position detection with fallback
M.get_id_at_cursor = function(id_list)
    if not id_list or type(id_list) ~= "table" then
        return nil
    end

    local cursor_line = 1

    -- Try to get cursor position from plugin window first
    if state.ui and state.ui.content and state.ui.content.win and 
       vim.api.nvim_win_is_valid(state.ui.content.win) then
        local success, cursor_pos = pcall(vim.api.nvim_win_get_cursor, state.ui.content.win)
        if success and cursor_pos then
            cursor_line = cursor_pos[1]
        end
    else
        -- Fallback to current window
        local success, cursor_pos = pcall(vim.api.nvim_win_get_cursor, 0)
        if success and cursor_pos then
            cursor_line = cursor_pos[1]
        end
    end

    return id_list[cursor_line]
end

-- Enhanced entity addition with validation
M.add_entity = function(type_name, callback, parent_id)
    local entity_type = M.entity_types[type_name]
    if not entity_type then
        notify.error("Unknown entity type: " .. tostring(type_name))
        return
    end

    local prompt = state.lang[string.upper(type_name) .. "_NAME"] or (type_name .. " name:")

    ui.create_input_field(prompt, "", function(name)
        if not name or vim.trim(name) == "" then
            notify.info("Operation cancelled")
            return
        end

        if callback then
            callback(vim.trim(name), parent_id)
        end
    end)
end

-- Enhanced entity renaming with better validation
M.rename_entity = function(type_name, id, current_name, parent_id, callback)
    local entity_type = M.entity_types[type_name]
    if not entity_type then
        notify.error("Unknown entity type: " .. tostring(type_name))
        return
    end

    local prompt = state.lang[string.upper(type_name) .. "_NEW_NAME"] or ("New " .. type_name .. " name:")

    ui.create_input_field(prompt, current_name or "", function(new_name, selected_line)
        if not new_name or vim.trim(new_name) == "" then
            notify.info("Operation cancelled")
            return
        end

        local trimmed_name = vim.trim(new_name)
        if trimmed_name == current_name then
            notify.info("No changes made")
            return
        end

        if callback then
            local result = callback(id, trimmed_name, parent_id, selected_line)
            if result == "LEN_NAME" then
                notify.error(state.lang[entity_type.name_len_error] or "Name is too short")
            elseif result == "EXIST_NAME" then
                notify.error(state.lang[entity_type.name_exist_error] or "Name already exists")
            elseif not result then
                notify.error(state.lang[entity_type.rename_failed] or "Failed to rename")
            end
        end
    end)
end

-- Enhanced entity deletion with better confirmation
M.delete_entity = function(type_name, id, name, parent_id, callback)
    local entity_type = M.entity_types[type_name]
    if not entity_type then
        notify.error("Unknown entity type: " .. tostring(type_name))
        return
    end

    local display_name = name or "this item"
    local confirm_message = state.lang[entity_type.delete_confirm] or ("Delete " .. type_name .. ": %s? (y/N)")
    local prompt = string.format(confirm_message, display_name)

    ui.create_input_field(prompt, "", function(answer, selected_line)
        if not answer then
            notify.info("Operation cancelled")
            return
        end

        local normalized_answer = vim.trim(answer:lower())
        if normalized_answer == "y" or normalized_answer == "yes" then
            if callback then
                local result = callback(id, parent_id, selected_line)
                if not result then
                    notify.error(state.lang[entity_type.delete_failed] or "Failed to delete")
                end
            end
        else
            notify.info("Deletion cancelled")
        end
    end)
end

-- Enhanced icon handling with proper positioning
local function get_entity_icon(entity_type_name, is_active, is_empty)
    local icons = config.ui.icons or {}
    
    if is_empty then
        return icons.empty or "󰇘 "
    end
    
    -- Entity-specific icons
    local entity_icons = {
        project = is_active and (icons.project_active or "󰋜 ") or (icons.project or "󰉋 "),
        workspace = is_active and (icons.workspace_active or "󰏘 ") or (icons.workspace or "󰉌 "),
        tab = is_active and (icons.tab_active or "󰓩 ") or (icons.tab or "󰎃 "),
        file = is_active and (icons.file_active or "󰈙 ") or (icons.file or "󰈚 "),
    }
    
    return entity_icons[entity_type_name] or (is_active and "▶ " or "  ")
end

-- Centralized active state detection to avoid duplication
local function determine_active_state(entity_type, entity, active_id, custom_active_fn)
    if custom_active_fn then
        return custom_active_fn(entity, active_id)
    end

    if entity_type.name == "workspace" then
        return entity.active == true or entity.active == 1
    else
        return tostring(entity[entity_type.id_field or "id"] or "") == tostring(active_id or "")
    end
end

-- Enhanced list formatting with proper icon integration
local function format_entity_line(entity, entity_type_name, is_active, formatter)
    local line_content
    if formatter then
        line_content = formatter(entity)
    else
        line_content = entity.name or entity.path or "???"
    end

    -- Clean any existing prefixes from formatter
    line_content = line_content:gsub("^[>%s▶󰋜󰉋󰏘󰉌󰓩󰎃󰈙󰈚]*", "")
    line_content = vim.trim(line_content)

    -- Get appropriate icon
    local icon = get_entity_icon(entity_type_name, is_active, false)
    
    return icon .. line_content
end

-- Enhanced entity list initialization with better icon handling
M.init_entity_list = function(
    type_name,
    entities,
    id_list,
    _, -- init_function kept for compatibility but unused
    active_id,
    id_field,
    selected_line,
    formatter,
    custom_active_fn
)
    local entity_type = M.entity_types[type_name]
    if not entity_type then
        notify.error("Unknown entity type: " .. tostring(type_name))
        return nil
    end

    if not entities or type(entities) ~= "table" then
        entities = {}
    end

    if not id_list or type(id_list) ~= "table" then
        notify.error("Invalid id_list provided")
        return nil
    end

    local is_empty = #entities == 0
    local lines = {}
    local current_line = 1
    local found_active = false

    -- Store the id_field for later use
    entity_type.id_field = id_field or "id"

    -- Format entity lines
    for i, entity in ipairs(entities) do
        local entity_id = entity[entity_type.id_field]
        local is_active = determine_active_state(entity_type, entity, active_id, custom_active_fn)

        local formatted_line = format_entity_line(entity, entity_type.name, is_active, formatter)
        table.insert(lines, formatted_line)
        id_list[i] = entity_id

        if is_active then
            current_line = i
            found_active = true
        end
    end

    -- Handle empty state
    if is_empty then
        local empty_message = state.lang[entity_type.empty_message] or ("No " .. type_name .. "s available")
        local empty_icon = get_entity_icon(entity_type.name, false, true)
        table.insert(lines, empty_icon .. empty_message)
    end

    -- Reset state if active item not found
    if not found_active and not is_empty and entity_type.state_id then
        state[entity_type.state_id] = nil
        current_line = 1
    end

    -- Determine cursor position
    local cursor_line = selected_line or current_line
    cursor_line = math.max(1, math.min(cursor_line, #lines))

    -- Create UI
    local title = state.lang[entity_type.title] or string.upper(type_name .. "S")
    local buf, win = ui.open_main(lines, title, cursor_line)

    if not buf or not win then
        notify.error("Failed to create UI for " .. type_name)
        return nil
    end

    -- Configure window - remove signcolumn since icons are in text
    vim.wo[win].signcolumn = "no"
    vim.bo[buf].modifiable = false
    vim.bo[buf].buftype = "nofile"

    -- Set info line
    local info_message = is_empty and 
        (state.lang[entity_type.info_empty] or "Empty list") or
        (state.lang[entity_type.info] or "Use arrow keys to navigate")

    ui.open_actions(info_message)

    return {
        buf = buf,
        win = win,
        is_empty = is_empty,
        entities = entities,
        id_list = id_list,
        entity_type = entity_type,
    }
end

-- Utility function for entity validation
M.validate_entity_name = function(type_name, name)
    local entity_type = M.entity_types[type_name]
    if not entity_type then
        return false, "Unknown entity type"
    end

    if not name or vim.trim(name) == "" then
        return false, "LEN_NAME"
    end

    if #vim.trim(name) < entity_type.min_name_len then
        return false, "LEN_NAME"
    end

    return true, nil
end

-- Utility function to get entity type info
M.get_entity_type = function(type_name)
    return M.entity_types[type_name]
end

-- Enhanced error handling wrapper for UI operations
M.safe_ui_operation = function(operation_name, operation_fn, ...)
    local success, result = pcall(operation_fn, ...)
    if not success then
        notify.error("UI operation failed: " .. operation_name .. " - " .. tostring(result))
        return nil
    end
    return result
end

-- Utility function to refresh entity icons (for dynamic updates)
M.refresh_entity_icons = function(buf, entities, entity_type_name, active_id, custom_active_fn)
    if not buf or not vim.api.nvim_buf_is_valid(buf) then
        return false
    end
    
    local entity_type = M.entity_types[entity_type_name]
    if not entity_type then
        return false
    end
    
    local lines = {}
    for i, entity in ipairs(entities) do
        local entity_id = entity[entity_type.id_field or "id"]
        local is_active = determine_active_state(entity_type, entity, active_id, custom_active_fn)
        
        local formatted_line = format_entity_line(entity, entity_type.name, is_active, nil)
        table.insert(lines, formatted_line)
    end
    
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    
    return true
end

return M
