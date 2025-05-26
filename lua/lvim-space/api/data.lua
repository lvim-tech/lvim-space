-- State management
local state = require("lvim-space.api.state")

-- Database module
local db = require("lvim-space.persistence.db")

local M = {}

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

M.find_project_by_id = function(id)
	return db.find("projects", { id = id })
end

M.find_project_by_path = function(path)
	return db.find("projects", { path = path })
end

M.add_project = function(path, name)
	if vim.fn.strchars(name) < 3 then
		return "LEN"
	end
	local exist_name = M.is_project_name_exist(name)
	if exist_name then
		return "EXIST_NAME"
	end
	local exist_path = M.is_project_path_exist(path)
	if exist_path then
		return "EXIST_PATH"
	end
	return db.insert("projects", {
		name = name,
		path = path,
	})
end

M.is_project_name_exist = function(name)
	return db.find("projects", { name = name })
end

M.is_project_path_exist = function(path)
	return db.find("projects", { path = path })
end

M.update_project_name = function(name, new_name)
	if vim.fn.strchars(new_name) < 3 then
		return "LEN_NAME"
	end
	local exist = M.is_project_name_exist(new_name)
	if exist then
		return "EXIST_NAME"
	end
	return db.update("projects", {
		name = name,
	}, {
		name = new_name,
	})
end

M.remove_project = function(name)
	return db.remove("projects", { name = name })
end

M.find_current_workspace = function()
	return db.find("workspaces", {
		project_id = state.project_id,
	})
end

return M
