local state = require("lvim-space.api.state")
local db = require("lvim-space.persistence.db")

local M = {}

-- PROJECTS

M.find_current_project = function()
	local cwd = vim.loop.cwd()
	if cwd ~= nil and not cwd:match("/$") then
		cwd = cwd .. "/"
	end
	return db.find("projects", { path = cwd })
end

M.find_projects = function()
	return db.find("projects")
end

M.find_project_by_id = function(project_id)
	return db.find("projects", { id = project_id })
end

M.find_project_by_path = function(project_path)
	return db.find("projects", { path = project_path })
end

M.add_project = function(project_path, project_name)
	if vim.fn.strchars(project_name) < 3 then
		return "LEN"
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
	return db.find("projects", { name = project_name })
end

M.is_project_path_exist = function(project_path)
	return db.find("projects", { path = project_path })
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

-- WORKSPACES

M.find_project_workspaces = function()
	return db.find("workspaces", {
		project_id = state.project_id,
	})
end

M.find_workspace_by_id = function(workspace_id, project_id)
	return db.find("workspaces", {
		id = workspace_id,
		project_id = project_id,
	})
end

M.is_workspace_name_exist = function(workspace_name, project_id)
	return db.find("workspaces", {
		project_id = project_id,
		name = workspace_name,
	})
end

M.add_workspace = function(workspace_name, workspace_tabs, project_id)
	if vim.fn.strchars(workspace_name) < 3 then
		return "LEN"
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
	local exist = M.is_workspace_name_exist(workspace_new_name)
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
	return db.update("workspaces", {
		project_id = project_id,
	}, {
		active = false,
	})
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

M.get_workspace_active_id = function (project_id)
	return db.find("workspaces", {
		project_id = project_id,
		active = true,
	})
end

M.delete_workspace = function(workspace_id, project_id)
	return db.remove("workspaces", {
		id = workspace_id,
		project_id = project_id,
	})
end

return M

-- vim: foldmethod=indent foldlevel=0
