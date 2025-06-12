local config = require("lvim-space.config")
local notify = require("lvim-space.api.notify")
local state = require("lvim-space.api.state")
local sqlite = require("sqlite.db")
local tbl = require("sqlite.tbl")

local uri = config.save .. "/lvimspace.db"

local M = {}

M.db = nil

M.find = function(table_name, conditions, options)
    if not M.db or not M[table_name] then
        return false
    end
    local query_options = options or {}
    if not query_options.order_by then
        query_options.order_by = { asc = "sort_order" }
    end
    if conditions and next(conditions) ~= nil then
        query_options.where = conditions
    end
    local ok, result_data = pcall(function()
        return M[table_name]:get(query_options)
    end)
    if not ok then
        return false
    end
    if result_data == nil or (type(result_data) == "table" and not next(result_data)) then
        return nil
    end
    return result_data
end

M.insert = function(table_name, values)
    if not M.db or not M[table_name] then
        return false
    end
    local ok, row_id = pcall(function()
        return M[table_name]:insert(values)
    end)
    if not ok then
        return false
    end
    return row_id
end

M.update = function(table_name, conditions, values)
    if not M.db or not M[table_name] then
        return false
    end
    local ok, _ = pcall(function()
        M[table_name]:update({ where = conditions, set = values })
    end)
    if not ok then
        return false
    end
    return true
end

M.remove = function(table_name, conditions)
    if not M.db or not M[table_name] then
        return false
    end
    local ok, _ = pcall(function()
        M[table_name]:remove(conditions)
    end)
    if not ok then
        return false
    end
    return true
end

M.init = function()
    if vim.fn.isdirectory(config.save) == 0 then
        local mkdir_ok, _ = pcall(vim.fn.mkdir, config.save, "p")
        if not mkdir_ok then
            notify.error(
                (state.lang and state.lang.FAILED_TO_CREATE_SAVE_DIRECTORY)
                    or "Failed to create save directory for database."
            )
            config.log = false
            return false
        end
    end
    local db_init_ok, _ = pcall(function()
        M.db = sqlite({
            uri = uri,
            opts = {
                foreign_keys = "ON",
            },
        })
        if not M.db then
            error("sqlite constructor for M.db returned nil")
        end
        M.projects = tbl("projects", {
            id = { "integer", primary = true, autoincrement = true },
            name = { "text", required = true, unique = true },
            path = { "text", required = true, unique = true },
            sort_order = { "integer", default_value = 1 },
        }, M.db)
        M.workspaces = tbl("workspaces", {
            id = { "integer", primary = true, autoincrement = true },
            project_id = {
                type = "integer",
                required = true,
                reference = "projects.id",
                on_delete = "cascade",
            },
            name = { "text", required = true },
            tabs = { "text" },
            active = { "boolean", default_value = false },
            sort_order = { "integer", default_value = 1 },
        }, M.db)
        M.tabs = tbl("tabs", {
            id = { "integer", primary = true, autoincrement = true },
            workspace_id = {
                type = "integer",
                required = true,
                reference = "workspaces.id",
                on_delete = "cascade",
            },
            name = { "text", required = true },
            data = { "text" },
            sort_order = { "integer", default_value = 1 },
        }, M.db)
    end)
    if not db_init_ok then
        notify.error((state.lang and state.lang.FAILED_TO_CREATE_DB) or "Failed to initialize database.")
        M.db = nil
        return false
    end
    return true
end

M.close_db_connection = function()
    if M.db then
        local ok, _ = pcall(function()
            if M.db.close then
                M.db:close()
            end
        end)
        if ok then
            M.db = nil
        end
    end
end

M.exec = function(sql_query)
    if not M.db then
        return false
    end
    local ok, result = pcall(function()
        return M.db:exec(sql_query)
    end)
    if not ok then
        return false
    end
    return result
end

return M
