local state = require("lvim-space.api.state")
local db = require("lvim-space.persistence.db")
local log = require("lvim-space.api.log")

local M = {}

local function validate_params(params, required_fields)
    for _, field in ipairs(required_fields) do
        if not params[field] then
            log.warn(string.format("Missing required parameter: %s", field))
            return false
        end
    end
    return true
end

local function get_next_sort_order(table_name, conditions)
    local items = db.find(table_name, conditions or {})
    local max_order = 0

    if items and #items > 0 then
        for _, item in ipairs(items) do
            if type(item.sort_order) == "number" and item.sort_order > max_order then
                max_order = item.sort_order
            end
        end
    end

    return max_order + 1
end

M.find_project_by_cwd = function()
    local cwd = vim.loop.cwd()
    if cwd ~= nil and not cwd:match("/$") then
        cwd = cwd .. "/"
    end
    local result = db.find("projects", { path = cwd })
    return result and result[1]
end

M.find_projects = function(options)
    options = options or { sort_by = "sort_order", sort_order_dir = "ASC" }
    return db.find("projects", {}, options)
end

M.find_project_by_id = function(project_id)
    if not project_id then
        return nil
    end
    local result = db.find("projects", { id = project_id })
    return result and result[1] or nil
end

M.find_project_by_path = function(project_path)
    if not project_path then
        return nil
    end
    local result = db.find("projects", { path = project_path })
    return result and result[1] or nil
end

M.is_project_name_exist = function(project_name)
    if not project_name then
        return nil
    end
    local results = db.find("projects", { name = project_name })
    if results and #results > 0 then
        local ids = {}
        for _, res in ipairs(results) do
            table.insert(ids, res.id)
        end
        return ids
    end
    return nil
end

M.is_project_path_exist = function(project_path)
    if not project_path then
        return nil
    end
    local result = db.find("projects", { path = project_path })
    return result and result[1] or nil
end

M.add_project = function(project_path, project_name)
    if
        not validate_params(
            { project_path = project_path, project_name = project_name },
            { "project_path", "project_name" }
        )
    then
        return false
    end

    local next_order = get_next_sort_order("projects")

    log.debug(
        string.format("Adding project. Name: %s, Path: %s, Next Sort Order: %d", project_name, project_path, next_order)
    )

    return db.insert("projects", {
        name = project_name,
        path = project_path,
        sort_order = next_order,
    })
end

M.update_project_name = function(project_id, project_new_name)
    if
        not validate_params(
            { project_id = project_id, project_new_name = project_new_name },
            { "project_id", "project_new_name" }
        )
    then
        return false
    end
    return db.update("projects", { id = project_id }, { name = project_new_name })
end

M.update_project_sort_order = function(project_id, new_order)
    if not validate_params({ project_id = project_id, new_order = new_order }, { "project_id", "new_order" }) then
        return false
    end

    if type(new_order) ~= "number" then
        log.warn("update_project_sort_order: new_order must be a number")
        return false
    end

    return db.update("projects", { id = project_id }, { sort_order = new_order })
end

M.reorder_projects = function(project_order_table)
    if not project_order_table or type(project_order_table) ~= "table" or #project_order_table == 0 then
        log.warn("reorder_projects: project_order_table is missing or not a non-empty table.")
        return false, "PROJECT_REORDER_MISSING_PARAMS"
    end

    local success_all = true
    for _, item in ipairs(project_order_table) do
        if not item or not item.id or not item.order then
            log.warn("reorder_projects: Invalid item in project_order_table.", item)
            success_all = false
        else
            local result_one = M.update_project_sort_order(item.id, item.order)
            if not result_one then
                log.warn(
                    string.format(
                        "reorder_projects: Failed to update sort_order for project ID %s to %d",
                        item.id,
                        item.order
                    )
                )
                success_all = false
            end
        end
    end

    if not success_all then
        return false, "PROJECT_REORDER_FAILED"
    end

    log.info("reorder_projects: Successfully reordered projects.")
    return true, nil
end

M.delete_project = function(project_id)
    if not project_id then
        log.warn("delete_project: Missing project_id")
        return false
    end

    log.info("M.delete_project: Deleting project with ID: " .. project_id)

    local workspaces_to_delete = M.find_workspaces(project_id)
    if workspaces_to_delete and #workspaces_to_delete > 0 then
        for _, ws in ipairs(workspaces_to_delete) do
            log.debug("M.delete_project: Deleting associated workspace ID: " .. ws.id)
            M.delete_workspace(ws.id, project_id)
        end
    end

    return db.remove("projects", { id = project_id })
end

M.find_current_workspace = function(project_id)
    if not project_id then
        return nil
    end
    local result = db.find("workspaces", { project_id = project_id, active = true })
    return result and result[1] or nil
end

M.find_workspaces = function(project_id, options)
    if not project_id then
        log.debug("find_workspaces: Called without project_id, returning empty table.")
        return {}
    end
    options = options or { sort_by = "sort_order", sort_order_dir = "ASC" }
    return db.find("workspaces", { project_id = project_id }, options)
end

M.find_workspace_by_id = function(workspace_id, project_id)
    if not workspace_id or not project_id then
        return nil
    end
    local result = db.find("workspaces", { id = workspace_id, project_id = project_id })
    return result and result[1] or nil
end

M.is_workspace_name_exist = function(workspace_name, project_id)
    if not workspace_name or not project_id then
        return nil
    end
    local result = db.find("workspaces", { project_id = project_id, name = workspace_name })
    return result and result[1] or nil
end

M.add_workspace = function(workspace_name, workspace_tabs_json, project_id)
    if
        not validate_params(
            { workspace_name = workspace_name, project_id = project_id },
            { "workspace_name", "project_id" }
        )
    then
        return "ADD_FAILED"
    end

    local next_order = get_next_sort_order("workspaces", { project_id = project_id })

    if M.set_workspaces_inactive(project_id) then
        return db.insert("workspaces", {
            project_id = project_id,
            name = workspace_name,
            tabs = workspace_tabs_json,
            active = true,
            sort_order = next_order,
        })
    end

    log.warn("add_workspace: Failed to set other workspaces inactive for project " .. project_id)
    return false
end

M.update_workspace_name = function(workspace_id, workspace_new_name, project_id)
    if
        not validate_params(
            { workspace_id = workspace_id, workspace_new_name = workspace_new_name, project_id = project_id },
            { "workspace_id", "workspace_new_name", "project_id" }
        )
    then
        return false
    end
    return db.update("workspaces", { id = workspace_id, project_id = project_id }, { name = workspace_new_name })
end

M.update_workspace_sort_order = function(workspace_id, project_id, new_order)
    if
        not validate_params(
            { workspace_id = workspace_id, project_id = project_id, new_order = new_order },
            { "workspace_id", "project_id", "new_order" }
        )
    then
        return false
    end

    if type(new_order) ~= "number" then
        log.warn("update_workspace_sort_order: new_order must be a number")
        return false
    end

    return db.update("workspaces", { id = workspace_id, project_id = project_id }, { sort_order = new_order })
end

M.reorder_workspaces = function(project_id, workspace_order_table)
    if not validate_params({ project_id = project_id }, { "project_id" }) then
        return false, "WORKSPACE_REORDER_MISSING_PARAMS"
    end

    if not workspace_order_table or type(workspace_order_table) ~= "table" or #workspace_order_table == 0 then
        log.warn("reorder_workspaces: workspace_order_table is missing or not a non-empty table.")
        return false, "WORKSPACE_REORDER_MISSING_PARAMS"
    end

    local success_all = true
    for _, item in ipairs(workspace_order_table) do
        if not item or not item.id or not item.order then
            log.warn("reorder_workspaces: Invalid item in workspace_order_table.", item)
            success_all = false
        else
            local result_one = M.update_workspace_sort_order(item.id, project_id, item.order)
            if not result_one then
                log.warn(
                    string.format(
                        "reorder_workspaces: Failed to update sort_order for workspace ID %s to %d",
                        item.id,
                        item.order
                    )
                )
                success_all = false
            end
        end
    end

    if not success_all then
        return false, "WORKSPACE_REORDER_FAILED"
    end

    log.info("reorder_workspaces: Successfully reordered workspaces for project " .. project_id)
    return true, nil
end

M.set_workspaces_inactive = function(project_id)
    if not project_id then
        return false
    end

    local found = db.find("workspaces", { project_id = project_id, active = true })
    if found == false then
        return false
    elseif not found or #found == 0 then
        return true
    else
        return db.update("workspaces", { project_id = project_id }, { active = false })
    end
end

M.set_workspace_active = function(workspace_id, project_id)
    if
        not validate_params({ workspace_id = workspace_id, project_id = project_id }, { "workspace_id", "project_id" })
    then
        return false
    end

    if M.set_workspaces_inactive(project_id) then
        return db.update("workspaces", { id = workspace_id, project_id = project_id }, { active = true })
    end
    return false
end

M.delete_workspace = function(workspace_id, project_id)
    if
        not validate_params({ workspace_id = workspace_id, project_id = project_id }, { "workspace_id", "project_id" })
    then
        return false
    end

    log.info("M.delete_workspace: Deleting workspace ID: " .. workspace_id .. " from project ID: " .. project_id)

    local tabs_to_delete = M.find_tabs(workspace_id)
    if tabs_to_delete and #tabs_to_delete > 0 then
        for _, t in ipairs(tabs_to_delete) do
            log.debug("M.delete_workspace: Deleting associated tab ID: " .. t.id)
            M.delete_tab(t.id, workspace_id)
        end
    end

    return db.remove("workspaces", { id = workspace_id, project_id = project_id })
end

M.update_workspace_tabs = function(workspace_tabs_json, workspace_id)
    if
        not validate_params(
            { workspace_tabs_json = workspace_tabs_json, workspace_id = workspace_id },
            { "workspace_tabs_json", "workspace_id" }
        )
    then
        return false
    end
    return db.update("workspaces", { id = workspace_id }, { tabs = workspace_tabs_json })
end

M.find_current_tab = function(workspace_id_param, project_id_param)
    local ws_id = workspace_id_param or state.workspace_id
    local p_id = project_id_param or state.project_id

    if not ws_id or not p_id then
        log.debug(
            "M.find_current_tab: workspace_id or project_id is nil. ws_id: "
                .. tostring(ws_id)
                .. ", p_id: "
                .. tostring(p_id)
        )
        return nil
    end

    local ws = M.find_workspace_by_id(ws_id, p_id)
    if ws and ws.tabs then
        local ok_decode, decoded_tabs = pcall(vim.fn.json_decode, ws.tabs)
        if ok_decode and decoded_tabs and decoded_tabs.tab_active then
            return M.find_tab_by_id(decoded_tabs.tab_active, ws_id)
        else
            if not ok_decode then
                log.warn("M.find_current_tab: Failed to decode tabs JSON for workspace " .. ws_id)
            end
        end
    end
    return nil
end

M.find_tab_by_id = function(tab_id, workspace_id)
    if not tab_id or not workspace_id then
        return nil
    end
    local result = db.find("tabs", { id = tab_id, workspace_id = workspace_id })
    return result and result[1] or nil
end

M.find_tabs = function(workspace_id, options)
    if not workspace_id then
        log.debug("find_tabs: Called without workspace_id, returning empty table.")
        return {}
    end
    options = options or { sort_by = "sort_order", sort_order_dir = "ASC" }
    return db.find("tabs", { workspace_id = workspace_id }, options)
end

M.is_tab_name_exist = function(tab_name, workspace_id)
    if not tab_name or not workspace_id then
        return nil
    end
    local result = db.find("tabs", { workspace_id = workspace_id, name = tab_name })
    return result and result[1] or nil
end

M.add_tab = function(tab_name, tab_data_json, workspace_id)
    if not validate_params({ tab_name = tab_name, workspace_id = workspace_id }, { "tab_name", "workspace_id" }) then
        return "ADD_FAILED"
    end

    local next_order = get_next_sort_order("tabs", { workspace_id = workspace_id })

    log.debug(string.format("Adding tab '%s' to workspace %s. Next sort_order: %d", tab_name, workspace_id, next_order))

    return db.insert("tabs", {
        workspace_id = workspace_id,
        name = tab_name,
        data = tab_data_json,
        sort_order = next_order,
    })
end

M.update_tab_name = function(tab_id, tab_new_name, workspace_id)
    if
        not validate_params(
            { tab_id = tab_id, tab_new_name = tab_new_name, workspace_id = workspace_id },
            { "tab_id", "tab_new_name", "workspace_id" }
        )
    then
        return false
    end
    return db.update("tabs", { id = tab_id, workspace_id = workspace_id }, { name = tab_new_name })
end

M.update_tab_sort_order = function(tab_id, workspace_id, new_order)
    if
        not validate_params(
            { tab_id = tab_id, workspace_id = workspace_id, new_order = new_order },
            { "tab_id", "workspace_id", "new_order" }
        )
    then
        return false
    end

    if type(new_order) ~= "number" then
        log.warn("update_tab_sort_order: new_order must be a number")
        return false
    end

    return db.update("tabs", { id = tab_id, workspace_id = workspace_id }, { sort_order = new_order })
end

M.reorder_tabs = function(workspace_id, tab_order_table)
    if not validate_params({ workspace_id = workspace_id }, { "workspace_id" }) then
        return false, "TAB_REORDER_MISSING_PARAMS"
    end

    if not tab_order_table or type(tab_order_table) ~= "table" or #tab_order_table == 0 then
        log.warn("reorder_tabs: tab_order_table is missing or not a non-empty table.")
        return false, "TAB_REORDER_MISSING_PARAMS"
    end

    local success_all = true
    for _, item in ipairs(tab_order_table) do
        if not item or not item.id or not item.order then
            log.warn("reorder_tabs: Invalid item in tab_order_table.", item)
            success_all = false
        else
            local result_one = M.update_tab_sort_order(item.id, workspace_id, item.order)
            if not result_one then
                log.warn(
                    string.format("reorder_tabs: Failed to update sort_order for tab ID %s to %d", item.id, item.order)
                )
                success_all = false
            end
        end
    end

    if not success_all then
        return false, "TAB_REORDER_FAILED"
    end

    log.info("reorder_tabs: Successfully reordered tabs for workspace " .. workspace_id)
    return true, nil
end

M.delete_tab = function(tab_id, workspace_id)
    if not validate_params({ tab_id = tab_id, workspace_id = workspace_id }, { "tab_id", "workspace_id" }) then
        return false
    end

    log.info("M.delete_tab: Deleting tab ID: " .. tab_id .. " from workspace ID: " .. workspace_id)
    return db.remove("tabs", { id = tab_id, workspace_id = workspace_id })
end

M.update_tab_data = function(tab_id, tab_data_json, workspace_id)
    if
        not validate_params(
            { tab_id = tab_id, tab_data_json = tab_data_json, workspace_id = workspace_id },
            { "tab_id", "tab_data_json", "workspace_id" }
        )
    then
        return false
    end
    return db.update("tabs", { id = tab_id, workspace_id = workspace_id }, { data = tab_data_json })
end

M.find_files = function(tab_id_param, workspace_id_param)
    if
        not validate_params(
            { tab_id_param = tab_id_param, workspace_id_param = workspace_id_param },
            { "tab_id_param", "workspace_id_param" }
        )
    then
        return {}
    end

    local tab_record = M.find_tab_by_id(tab_id_param, workspace_id_param)
    if not tab_record then
        log.debug("M.find_files: No tab record found for tab_id: " .. tab_id_param)
        return {}
    end

    if not tab_record.data then
        log.debug("M.find_files: Tab record has no 'data' field.")
        return {}
    end

    local ok, tab_data_json = pcall(vim.fn.json_decode, tab_record.data)
    if not ok then
        log.warn("M.find_files: Failed to decode tab data JSON: " .. tostring(tab_data_json))
        return {}
    end

    if not tab_data_json.buffers or type(tab_data_json.buffers) ~= "table" then
        log.debug("M.find_files: No valid 'buffers' table found.")
        return {}
    end

    local files_list = {}
    for i, buf_info in ipairs(tab_data_json.buffers) do
        if type(buf_info) == "table" and buf_info.filePath then
            table.insert(files_list, {
                id = buf_info.filePath,
                path = buf_info.filePath,
                name = vim.fn.fnamemodify(buf_info.filePath, ":t"),
                bufnr_original = buf_info.bufnr,
                tab_id = tab_id_param,
                workspace_id = workspace_id_param,
            })
        else
            log.debug("M.find_files: Skipping invalid buffer entry at index " .. i)
        end
    end

    log.debug("M.find_files: Found " .. #files_list .. " files")
    return files_list
end

M.clear_data_for_project = function(project_id)
    if not project_id then
        log.warn("clear_data_for_project: Missing project_id")
        return false
    end

    log.info("clear_data_for_project: Clearing all data for project ID: " .. project_id)

    local workspaces = M.find_workspaces(project_id)
    if workspaces and #workspaces > 0 then
        for _, ws in ipairs(workspaces) do
            M.clear_data_for_workspace(ws.id, project_id)
        end
    end

    return db.remove("projects", { id = project_id })
end

M.clear_data_for_workspace = function(workspace_id, project_id)
    if
        not validate_params({ workspace_id = workspace_id, project_id = project_id }, { "workspace_id", "project_id" })
    then
        return false
    end

    log.info("clear_data_for_workspace: Clearing all data for workspace ID: " .. workspace_id)

    local tabs = M.find_tabs(workspace_id)
    if tabs and #tabs > 0 then
        for _, t in ipairs(tabs) do
            M.delete_tab(t.id, workspace_id)
        end
    end

    return db.remove("workspaces", { id = workspace_id, project_id = project_id })
end

return M
