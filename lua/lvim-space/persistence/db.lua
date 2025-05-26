local config = require("lvim-space.config")
local notify = require("lvim-space.api.notify")
local log = require("lvim-space.api.log")
local state = require("lvim-space.api.state")

local sqlite = require("sqlite.db")
local tbl = require("sqlite.tbl")

local uri = config.save .. "/lvimspace.db"

local M = {}

M.find = function(table, conditions)
	local ok, result = pcall(function()
		return M[table]:get({ where = conditions })
	end)
	if not ok then
		log.logger(result)
		return false
	elseif result == nil or (type(result) == "table" and next(result) == nil) then
		return nil
	end
	return result
end

M.insert = function(table, values)
	local status, error = pcall(function()
		M[table]:insert(values)
	end)
	if error then
		log.logger(error)
	end

	return status
end

M.update = function(table, conditions, values)
	local status, error = pcall(function()
		M[table]:update({ where = conditions, set = values })
	end)

	if error then
		log.logger(error)
	end

	return status
end

M.remove = function(table, conditions)
	local status, error = pcall(function()
		M[table]:remove(conditions)
	end)

	if error then
		log.logger(error)
	end

	return status
end

M.init = function()
	if vim.fn.isdirectory(config.save) == 0 then
		local ok = vim.fn.mkdir(config.save, "p")
		if ok == 0 then
			notify.error(state.lang.FAILED_TO_CREATE_SAVE_DIRECTORY)
			config.log = false
			return false
		end
	end

	local ok, error = pcall(function()
		M.db = sqlite({
			uri = uri,
			opts = {},
		})

		M.projects = tbl("projects", {
			id = { "integer", primary = true },
			name = { "text", required = true, unique = true },
			path = { "text", required = true, unique = true },
		}, M.db)

		M.workspaces = tbl("workspaces", {
			id = { "integer", primary = true },
			project_id = {
				type = "integer",
				required = true,
				reference = "projects.id",
				on_delete = "cascade",
			},
			name = { "text", required = true },
			tabs = { "text", serialize = "json" },
			active = { "boolean" },
		}, M.db)

		M.tabs = tbl("tabs", {
			id = { "integer", primary = true },
			workspace_id = {
				type = "integer",
				required = true,
				reference = "workspaces.id",
				on_delete = "cascade",
			},
			data = { "text", required = true },
			timestamp = { "real", default = "julianday('now')" },
		}, M.db)

		-- M.insert("projects", {
		-- 	{
		-- 		name = "Project1",
		-- 		path = "/home/biserstoilov",
		-- 	},
		-- 	{
		-- 		name = "Project2",
		-- 		path = "/home/biserstoilov/.3T",
		-- 	},
		-- 	{
		-- 		name = "Project3",
		-- 		path = "/home/biserstoilov/.local/share/nvim/lazy/lvim-space",
		-- 	},
		-- 	{
		-- 		name = "Project4",
		-- 		path = "/home/biserstoilov/.config",
		-- 	},
		-- })
		-- local fruits = { "apple", "orange" }
		-- local fruits2 = { "apple2", "orange2" }
		--
		-- -- Сериализация до JSON низ
		-- local json_fruits = vim.fn.json_encode(fruits)
		-- local json_fruits2 = vim.fn.json_encode(fruits2)
		-- M.insert("workspaces", {
		-- 	{
		-- 		project_id = 2,
		-- 		name = "Project1",
		-- 		tabs = json_fruits,
		-- 		active = true,
		-- 	},
		-- 	{
		-- 		project_id = 2,
		-- 		name = "Project1",
		-- 		tabs = json_fruits2,
		-- 	},
		-- })
	end)

	if not ok then
		notify.error(state.lang.FAILED_TO_CREATE_DB)
		log.logger(error)
		return false
	end

	return true
end

return M
