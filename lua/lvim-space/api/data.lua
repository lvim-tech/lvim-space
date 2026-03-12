-- Data access layer for lvim-space: CRUD operations for projects, workspaces, tabs, and files.
-- All public functions wrap the persistence layer (db) and apply input validation before
-- performing any database operation.

local state = require("lvim-space.api.state")
local db = require("lvim-space.persistence.db")

local M = {}

---@class OrderItem
---@field id any  The record identifier
---@field order number  The desired sort position

---Validate that every field listed in `required_fields` is present and truthy in `params`.
---@param params table<string, any>  Table of parameter key/value pairs to validate
---@param required_fields string[]  List of key names that must be non-nil/non-false
---@return boolean ok  True when all required fields are present
local function validate_params(params, required_fields)
    for _, field in ipairs(required_fields) do
        if not params[field] then
            return false
        end
    end
    return true
end

---Compute the next available sort_order value for records in `table_name` that match
---the optional `conditions` filter.
---@param table_name string  Database table to query
---@param conditions table<string, any>|nil  Optional WHERE conditions; defaults to `{}`
---@return number  One greater than the current maximum sort_order (starts at 1 when table is empty)
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

---Find the project whose path matches the current working directory.
---@return table|nil  Project record, or nil if not found
M.find_project_by_cwd = function()
    local cwd = (vim.uv or vim.loop).cwd()
    if cwd ~= nil and not cwd:match("/$") then
        cwd = cwd .. "/"
    end
    local result = db.find("projects", { path = cwd })
    return result and result[1] --[[@as table|nil]]
end

---Return all projects, ordered by sort_order ascending by default.
---@param options table|nil  Optional db.find options (e.g. sort_by, sort_order_dir)
---@return table[]  List of project records
M.find_projects = function(options)
    options = options or { sort_by = "sort_order", sort_order_dir = "ASC" }
    ---@diagnostic disable-next-line: return-type-mismatch
    return db.find("projects", {}, options)
end

---Find a single project by its primary key.
---@param project_id any  The project ID to look up
---@return table|nil  Project record, or nil if not found or id is falsy
M.find_project_by_id = function(project_id)
    if not project_id then
        return nil
    end
    local result = db.find("projects", { id = project_id })
    return result and result[1] or nil
end

---Find a single project by its filesystem path.
---@param project_path string|nil  Absolute path to search for
---@return table|nil  Project record, or nil if not found
M.find_project_by_path = function(project_path)
    if not project_path then
        return nil
    end
    local result = db.find("projects", { path = project_path })
    return result and result[1] or nil
end

---Check whether a project with the given name already exists.
---@param project_name string|nil  Name to search for
---@return any[]|nil  Array of matching project IDs, or nil if none found
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

---Check whether a project with the given path already exists.
---@param project_path string|nil  Filesystem path to search for
---@return table|nil  Existing project record, or nil if not found
M.is_project_path_exist = function(project_path)
    if not project_path then
        return nil
    end
    local result = db.find("projects", { path = project_path })
    return result and result[1] or nil
end

---Insert a new project record with the next available sort_order.
---@param project_path string  Absolute filesystem path for the project
---@param project_name string  Display name for the project
---@return any  Inserted record ID on success, or false if params are invalid
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
    return db.insert("projects", {
        name = project_name,
        path = project_path,
        sort_order = next_order,
    })
end

---Rename an existing project.
---@param project_id any  ID of the project to update
---@param project_new_name string  New display name
---@return boolean  True on success, false if params are invalid or update fails
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

---Update the sort_order of a project.
---@param project_id any  ID of the project to update
---@param new_order number  New sort position (must be a number)
---@return boolean  True on success, false if validation fails
M.update_project_sort_order = function(project_id, new_order)
    if not validate_params({ project_id = project_id, new_order = new_order }, { "project_id", "new_order" }) then
        return false
    end
    if type(new_order) ~= "number" then
        return false
    end
    return db.update("projects", { id = project_id }, { sort_order = new_order })
end

---Bulk-update sort_order for a list of projects.
---@param project_order_table OrderItem[]  Array of `{id, order}` entries
---@return boolean ok  True if all updates succeeded
---@return string|nil err  Error key string on failure, nil on success
M.reorder_projects = function(project_order_table)
    if not project_order_table or type(project_order_table) ~= "table" or #project_order_table == 0 then
        return false, "PROJECT_REORDER_MISSING_PARAMS"
    end
    local success_all = true
    for _, item in ipairs(project_order_table) do
        if not item or not item.id or not item.order then
            success_all = false
        else
            local result_one = M.update_project_sort_order(item.id, item.order)
            if not result_one then
                success_all = false
            end
        end
    end
    if not success_all then
        return false, "PROJECT_REORDER_FAILED"
    end
    return true, nil
end

---Delete a project. Child workspaces and tabs are removed via CASCADE DELETE.
---@param project_id any  ID of the project to remove
---@return boolean  True on success, false if id is falsy
M.delete_project = function(project_id)
    if not project_id then
        return false
    end
    -- CASCADE DELETE on workspaces → tabs handles child removal automatically.
    return db.remove("projects", { id = project_id })
end

---Return the currently active workspace for a project.
---@param project_id any  ID of the owning project
---@return table|nil  Active workspace record, or nil if not found
M.find_current_workspace = function(project_id)
    if not project_id then
        return nil
    end
    local result = db.find("workspaces", { project_id = project_id, active = true })
    return result and result[1] or nil
end

---Return all workspaces belonging to a project, ordered by sort_order ascending by default.
---@param project_id any  ID of the owning project
---@param options table|nil  Optional db.find options
---@return table[]  List of workspace records (empty table if project_id is falsy)
M.find_workspaces = function(project_id, options)
    if not project_id then
        return {}
    end
    options = options or { sort_by = "sort_order", sort_order_dir = "ASC" }
    ---@diagnostic disable-next-line: return-type-mismatch
    return db.find("workspaces", { project_id = project_id }, options)
end

---Find a single workspace by its ID within a specific project.
---@param workspace_id any  Workspace primary key
---@param project_id any  Owning project primary key
---@return table|nil  Workspace record, or nil if either ID is falsy or not found
M.find_workspace_by_id = function(workspace_id, project_id)
    if not workspace_id or not project_id then
        return nil
    end
    local result = db.find("workspaces", { id = workspace_id, project_id = project_id })
    return result and result[1] or nil
end

---Check whether a workspace with the given name exists in a project.
---@param workspace_name string|nil  Name to look up
---@param project_id any  Owning project ID
---@return table|nil  Existing workspace record, or nil if not found
M.is_workspace_name_exist = function(workspace_name, project_id)
    if not workspace_name or not project_id then
        return nil
    end
    local result = db.find("workspaces", { project_id = project_id, name = workspace_name })
    return result and result[1] or nil
end

---Insert a new workspace, deactivate all other workspaces in the project, and mark the new
---one as active.
---@param workspace_name string  Display name for the new workspace
---@param workspace_tabs_json string|nil  JSON-encoded tabs snapshot (may be nil)
---@param project_id any  Owning project ID
---@return any  Inserted record ID on success, `"ADD_FAILED"` if params are invalid, or false on error
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
    return false
end

---Rename an existing workspace.
---@param workspace_id any  ID of the workspace to update
---@param workspace_new_name string  New display name
---@param project_id any  Owning project ID
---@return boolean  True on success, false if params are invalid
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

---Update the sort_order of a workspace within a project.
---@param workspace_id any  ID of the workspace to update
---@param project_id any  Owning project ID
---@param new_order number  New sort position (must be a number)
---@return boolean  True on success, false if validation fails
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
        return false
    end
    return db.update("workspaces", { id = workspace_id, project_id = project_id }, { sort_order = new_order })
end

---Bulk-update sort_order for a list of workspaces belonging to a project.
---@param project_id any  Owning project ID
---@param workspace_order_table OrderItem[]  Array of `{id, order}` entries
---@return boolean ok  True if all updates succeeded
---@return string|nil err  Error key string on failure, nil on success
M.reorder_workspaces = function(project_id, workspace_order_table)
    if not validate_params({ project_id = project_id }, { "project_id" }) then
        return false, "WORKSPACE_REORDER_MISSING_PARAMS"
    end
    if not workspace_order_table or type(workspace_order_table) ~= "table" or #workspace_order_table == 0 then
        return false, "WORKSPACE_REORDER_MISSING_PARAMS"
    end
    local success_all = true
    for _, item in ipairs(workspace_order_table) do
        if not item or not item.id or not item.order then
            success_all = false
        else
            local result_one = M.update_workspace_sort_order(item.id, project_id, item.order)
            if not result_one then
                success_all = false
            end
        end
    end
    if not success_all then
        return false, "WORKSPACE_REORDER_FAILED"
    end
    return true, nil
end

---Mark all workspaces in a project as inactive.
---Returns true without touching the DB when no active workspaces are found.
---@param project_id any  Owning project ID
---@return boolean  True on success or when nothing needed to be deactivated
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

---Deactivate all workspaces in the project and then mark the specified workspace as active.
---@param workspace_id any  ID of the workspace to activate
---@param project_id any  Owning project ID
---@return boolean  True on success, false if params are invalid or deactivation fails
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

---Delete a workspace. Child tabs are removed via CASCADE DELETE.
---@param workspace_id any  ID of the workspace to remove
---@param project_id any  Owning project ID
---@return boolean  True on success, false if params are invalid
M.delete_workspace = function(workspace_id, project_id)
    if
        not validate_params({ workspace_id = workspace_id, project_id = project_id }, { "workspace_id", "project_id" })
    then
        return false
    end
    -- CASCADE DELETE on tabs handles child removal automatically.
    return db.remove("workspaces", { id = workspace_id, project_id = project_id })
end

---Persist a serialized tabs snapshot for a workspace.
---@param workspace_tabs_json string  JSON-encoded tabs data
---@param workspace_id any  Target workspace ID
---@return boolean  True on success, false if params are invalid
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

---Resolve and return the currently active tab for the given workspace/project pair.
---Falls back to global state values when parameters are nil.
---@param workspace_id_param any|nil  Workspace ID (falls back to state.workspace_id)
---@param project_id_param any|nil  Project ID (falls back to state.project_id)
---@return table|nil  Active tab record, or nil if it cannot be determined
M.find_current_tab = function(workspace_id_param, project_id_param)
    local ws_id = workspace_id_param or state.workspace_id
    local p_id = project_id_param or state.project_id
    if not ws_id or not p_id then
        return nil
    end
    local ws = M.find_workspace_by_id(ws_id, p_id)
    if ws and ws.tabs then
        local ok_decode, decoded_tabs = pcall(vim.fn.json_decode, ws.tabs)
        if ok_decode and decoded_tabs and decoded_tabs.tab_active then
            return M.find_tab_by_id(decoded_tabs.tab_active, ws_id)
        end
    end
    return nil
end

---Find a single tab by its ID within a specific workspace.
---@param tab_id any  Tab primary key
---@param workspace_id any  Owning workspace ID
---@return table|nil  Tab record, or nil if either ID is falsy or not found
M.find_tab_by_id = function(tab_id, workspace_id)
    if not tab_id or not workspace_id then
        return nil
    end
    local result = db.find("tabs", { id = tab_id, workspace_id = workspace_id })
    return result and result[1] or nil
end

---Return all tabs belonging to a workspace, ordered by sort_order ascending by default.
---@param workspace_id any  Owning workspace ID
---@param options table|nil  Optional db.find options
---@return table[]  List of tab records (empty table if workspace_id is falsy)
M.find_tabs = function(workspace_id, options)
    if not workspace_id then
        return {}
    end
    options = options or { sort_by = "sort_order", sort_order_dir = "ASC" }
    ---@diagnostic disable-next-line: return-type-mismatch
    return db.find("tabs", { workspace_id = workspace_id }, options)
end

---Check whether a tab with the given name exists in a workspace.
---@param tab_name string|nil  Name to look up
---@param workspace_id any  Owning workspace ID
---@return table|nil  Existing tab record, or nil if not found
M.is_tab_name_exist = function(tab_name, workspace_id)
    if not tab_name or not workspace_id then
        return nil
    end
    local result = db.find("tabs", { workspace_id = workspace_id, name = tab_name })
    return result and result[1] or nil
end

---Insert a new tab with the next available sort_order.
---@param tab_name string  Display name for the new tab
---@param tab_data_json string|nil  JSON-encoded buffer/file data snapshot (may be nil)
---@param workspace_id any  Owning workspace ID
---@return any  Inserted record ID on success, or `"ADD_FAILED"` if params are invalid
M.add_tab = function(tab_name, tab_data_json, workspace_id)
    if not validate_params({ tab_name = tab_name, workspace_id = workspace_id }, { "tab_name", "workspace_id" }) then
        return "ADD_FAILED"
    end
    local next_order = get_next_sort_order("tabs", { workspace_id = workspace_id })
    return db.insert("tabs", {
        workspace_id = workspace_id,
        name = tab_name,
        data = tab_data_json,
        sort_order = next_order,
    })
end

---Rename an existing tab.
---@param tab_id any  ID of the tab to update
---@param tab_new_name string  New display name
---@param workspace_id any  Owning workspace ID
---@return boolean  True on success, false if params are invalid
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

---Update the sort_order of a tab within a workspace.
---@param tab_id any  ID of the tab to update
---@param workspace_id any  Owning workspace ID
---@param new_order number  New sort position (must be a number)
---@return boolean  True on success, false if validation fails
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
        return false
    end
    return db.update("tabs", { id = tab_id, workspace_id = workspace_id }, { sort_order = new_order })
end

---Bulk-update sort_order for a list of tabs belonging to a workspace.
---@param workspace_id any  Owning workspace ID
---@param tab_order_table OrderItem[]  Array of `{id, order}` entries
---@return boolean ok  True if all updates succeeded
---@return string|nil err  Error key string on failure, nil on success
M.reorder_tabs = function(workspace_id, tab_order_table)
    if not validate_params({ workspace_id = workspace_id }, { "workspace_id" }) then
        return false, "TAB_REORDER_MISSING_PARAMS"
    end
    if not tab_order_table or type(tab_order_table) ~= "table" or #tab_order_table == 0 then
        return false, "TAB_REORDER_MISSING_PARAMS"
    end
    local success_all = true
    for _, item in ipairs(tab_order_table) do
        if not item or not item.id or not item.order then
            success_all = false
        else
            local result_one = M.update_tab_sort_order(item.id, workspace_id, item.order)
            if not result_one then
                success_all = false
            end
        end
    end
    if not success_all then
        return false, "TAB_REORDER_FAILED"
    end
    return true, nil
end

---Delete a tab record.
---@param tab_id any  ID of the tab to remove
---@param workspace_id any  Owning workspace ID
---@return boolean  True on success, false if params are invalid
M.delete_tab = function(tab_id, workspace_id)
    if not validate_params({ tab_id = tab_id, workspace_id = workspace_id }, { "tab_id", "workspace_id" }) then
        return false
    end
    return db.remove("tabs", { id = tab_id, workspace_id = workspace_id })
end

---Persist a serialized buffer/file snapshot for a tab.
---@param tab_id any  Target tab ID
---@param tab_data_json string  JSON-encoded tab data
---@param workspace_id any  Owning workspace ID
---@return boolean  True on success, false if params are invalid
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

---@class FileEntry
---@field id string  Equals the file path (used as a unique key)
---@field path string  Absolute path to the file
---@field name string  Filename component (tail of the path)
---@field bufnr_original integer|nil  Buffer number at the time the snapshot was taken
---@field tab_id any  Owning tab ID
---@field workspace_id any  Owning workspace ID

---Decode the JSON data blob stored for a tab and return a list of file entries derived
---from the recorded buffer list.
---@param tab_id_param any  Tab ID to read files from
---@param workspace_id_param any  Owning workspace ID
---@return FileEntry[]  List of file entries; empty table on any error or missing data
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
        return {}
    end
    if not tab_record.data then
        return {}
    end
    local ok, tab_data_json = pcall(vim.fn.json_decode, tab_record.data)
    if not ok then
        return {}
    end
    if not tab_data_json.buffers or type(tab_data_json.buffers) ~= "table" then
        return {}
    end
    local files_list = {}
    for _, buf_info in ipairs(tab_data_json.buffers) do
        if type(buf_info) == "table" and buf_info.filePath then
            table.insert(files_list, {
                id = buf_info.filePath,
                path = buf_info.filePath,
                name = vim.fn.fnamemodify(buf_info.filePath, ":t"),
                bufnr_original = buf_info.bufnr,
                tab_id = tab_id_param,
                workspace_id = workspace_id_param,
            })
        end
    end
    return files_list
end

---Remove all data associated with a project (alias for delete that is used in clear/reset flows).
---@param project_id any  ID of the project to remove
---@return boolean  True on success, false if id is falsy
M.clear_data_for_project = function(project_id)
    if not project_id then
        return false
    end
    return db.remove("projects", { id = project_id })
end

---Remove a workspace record (used in clear/reset flows).
---@param workspace_id any  ID of the workspace to remove
---@param project_id any  Owning project ID
---@return boolean  True on success, false if params are invalid
M.clear_data_for_workspace = function(workspace_id, project_id)
    if
        not validate_params({ workspace_id = workspace_id, project_id = project_id }, { "workspace_id", "project_id" })
    then
        return false
    end
    return db.remove("workspaces", { id = workspace_id, project_id = project_id })
end

return M
