local state = require("lvim-space.api.state")
local db = require("lvim-space.persistence.db")

local M = {}

M.find_project_by_cwd = function()
    local cwd = vim.loop.cwd()
    if cwd ~= nil and not cwd:match("/$") then
        cwd = cwd .. "/"
    end
    local result = db.find("projects", { path = cwd })
    return result and result[1]
end

M.find_projects = function()
    return db.find("projects")
end

M.find_project_by_id = function(project_id)
    local result = db.find("projects", { id = project_id })
    return result and result[1] or nil
end

M.find_project_by_path = function(project_path)
    local result = db.find("projects", { path = project_path })
    return result and result[1] or nil
end

M.add_project = function(project_path, project_name)
    if vim.fn.strchars(project_name) < 3 then
        return "LEN_NAME"
    end
    local exist_name = M.is_project_name_exist(project_name)
    if exist_name then
        return "EXIST_NAME"
    end
    local exist_path = M.is_project_path_exist(project_path)
    if exist_path then
        return "EXIST_PATH"
    end
    return db.insert("projects", {
        name = project_name,
        path = project_path,
    })
end

M.is_project_name_exist = function(project_name)
    local result = db.find("projects", { name = project_name })
    return result and result[1] or nil
end

M.is_project_path_exist = function(project_path)
    local result = db.find("projects", { path = project_path })
    return result and result[1] or nil
end

M.update_project_name = function(project_id, project_new_name)
    if vim.fn.strchars(project_new_name) < 3 then
        return "LEN_NAME"
    end
    local exist = M.is_project_name_exist(project_new_name)
    if exist then
        return "EXIST_NAME"
    end
    return db.update("projects", {
        id = project_id,
    }, {
        name = project_new_name,
    })
end

M.delete_project = function(project_id)
    return db.remove("projects", { id = project_id })
end

M.find_current_workspace = function(project_id)
    local result = db.find("workspaces", {
        project_id = project_id,
        active = true,
    })
    return result and result[1] or nil
end

M.find_workspaces = function(project_id)
    local target_project_id = project_id or state.project_id
    if not target_project_id then
        return {}
    end
    return db.find("workspaces", {
        project_id = target_project_id,
    })
end

M.find_workspace_by_id = function(workspace_id, project_id)
    local result = db.find("workspaces", {
        id = workspace_id,
        project_id = project_id,
    })
    return result and result[1] or nil
end

M.is_workspace_name_exist = function(workspace_name, project_id)
    local result = db.find("workspaces", {
        project_id = project_id,
        name = workspace_name,
    })
    return result and result[1] or nil
end

M.add_workspace = function(workspace_name, workspace_tabs, project_id)
    if vim.fn.strchars(workspace_name) < 3 then
        return "LEN_NAME"
    end
    local exist_name = M.is_workspace_name_exist(workspace_name, project_id)
    if exist_name then
        return "EXIST_NAME"
    end
    if M.set_workspaces_inactive(project_id) then
        return db.insert("workspaces", {
            project_id = project_id,
            name = workspace_name,
            tabs = workspace_tabs,
            active = true,
        })
    end
    return false
end

M.update_workspace_name = function(workspace_id, workspace_new_name, project_id)
    if vim.fn.strchars(workspace_new_name) < 3 then
        return "LEN_NAME"
    end

    local exist = M.is_workspace_name_exist(workspace_new_name, project_id)
    if exist then
        return "EXIST_NAME"
    end
    return db.update("workspaces", {
        id = workspace_id,
        project_id = project_id,
    }, {
        name = workspace_new_name,
    })
end

M.set_workspaces_inactive = function(project_id)
    local found = db.find("workspaces", { project_id = project_id })
    if found == false then
        return false
    elseif found == nil then
        return true
    else
        return db.update("workspaces", {
            project_id = project_id,
        }, {
            active = false,
        })
    end
end

M.set_workspace_active = function(workspace_id, project_id)
    if M.set_workspaces_inactive(project_id) then
        return db.update("workspaces", {
            id = workspace_id,
            project_id = project_id,
        }, {
            active = true,
        })
    end
    return false
end

M.delete_workspace = function(workspace_id, project_id)
    return db.remove("workspaces", {
        id = workspace_id,
        project_id = project_id,
    })
end

M.find_current_tab = function(workspace_id)
    local result = db.find("tabs", {
        workspace_id = workspace_id,
    })
    return result and result[1] or nil
end

M.find_tab_by_id = function(tab_id, workspace_id)
    local result = db.find("tabs", {
        id = tab_id,
        workspace_id = workspace_id,
    })
    return result and result[1] or nil
end

M.find_tabs = function(workspace_id)
    local target_workspace_id = workspace_id or state.workspace_id
    if not target_workspace_id then
        return {}
    end
    return db.find("tabs", {
        workspace_id = target_workspace_id,
    })
end

M.is_tab_name_exist = function(tab_name, workspace_id)
    local result = db.find("tabs", {
        workspace_id = workspace_id,
        name = tab_name,
    })
    return result and result[1] or nil
end

M.add_tab = function(tab_name, tab_data, workspace_id)
    if vim.fn.strchars(tab_name) < 1 then
        return "LEN_NAME"
    end
    local exist_name = M.is_tab_name_exist(tab_name, workspace_id)
    if exist_name then
        return "EXIST_NAME"
    end
    return db.insert("tabs", {
        workspace_id = workspace_id,
        name = tab_name,
        data = tab_data,
    })
end

M.update_tab_name = function(tab_id, tab_new_name, workspace_id)
    if vim.fn.strchars(tab_new_name) < 1 then
        return "LEN_NAME"
    end

    local exist = M.is_tab_name_exist(tab_new_name, workspace_id)
    if exist then
        return "EXIST_NAME"
    end
    return db.update("tabs", {
        id = tab_id,
        workspace_id = workspace_id,
    }, {
        name = tab_new_name,
    })
end

M.delete_tab = function(tab_id, workspace_id)
    return db.remove("tabs", {
        id = tab_id,
        workspace_id = workspace_id,
    })
end

M.update_tab_data = function(tab_id, tab_data, workspace_id)
    if not tab_id or not tab_data or not workspace_id then
        return false
    end

    local result = db.update("tabs", {
        id = tab_id,
        workspace_id = workspace_id,
    }, {
        data = tab_data,
    })

    return result
end

M.update_workspace_tabs = function(workspace_tabs, workspace_id)
    return db.update("workspaces", {
        id = workspace_id,
    }, {
        tabs = workspace_tabs,
    })
end

M.find_files = function(workspace_id, tab_id)
    local tab = M.find_tab_by_id(tab_id, workspace_id)
    if not tab or not tab.data then
        return {}
    end

    local ok, tab_data = pcall(vim.fn.json_decode, tab.data)
    if not ok or not tab_data or not tab_data.buffers then
        return {}
    end

    local files = {}
    for _, buf in ipairs(tab_data.buffers) do
        if buf.bufnr and buf.filePath then
            table.insert(files, {
                id = buf.bufnr,
                path = buf.filePath,
            })
        end
    end
    return files
end

return M
