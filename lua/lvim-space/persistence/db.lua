local config = require("lvim-space.config")
local notify = require("lvim-space.api.notify")
local log = require("lvim-space.api.log")
local state = require("lvim-space.api.state")
local sqlite = require("sqlite.db")
local tbl = require("sqlite.tbl")

local uri = config.save .. "/lvimspace.db"

local M = {}
M.db = nil

M.find = function(table_name, conditions)
    if not M.db or not M[table_name] then
        log.error(string.format("DB find error: Database or table '%s' not initialized.", table_name))
        return false
    end
    local ok, result = pcall(function()
        return M[table_name]:get({ where = conditions })
    end)
    if not ok then
        log.error(string.format("DB find error in table '%s' with conditions %s.", table_name, vim.inspect(conditions)))
        return false
    end
    if result == nil or (type(result) == "table" and next(result) == nil) then
        return nil
    end
    return result
end

M.insert = function(table_name, values)
    if not M.db or not M[table_name] then
        log.error(string.format("DB insert error: Database or table '%s' not initialized.", table_name))
        return false
    end
    local ok, row_id = pcall(function()
        return M[table_name]:insert(values)
    end)
    if not ok then
        log.error(string.format("DB insert error in table '%s' with values %s.", table_name, vim.inspect(values)))
        return false
    end
    return row_id
end

M.update = function(table_name, conditions, values)
    if not M.db or not M[table_name] then
        log.error(string.format("DB update error: Database or table '%s' not initialized.", table_name))
        return false
    end
    local ok = pcall(function()
        M[table_name]:update({ where = conditions, set = values })
    end)
    if not ok then
        log.error(
            string.format(
                "DB update error in table '%s' with conditions %s and values %s.",
                table_name,
                vim.inspect(conditions),
                vim.inspect(values)
            )
        )
        return false
    end
    return true
end

M.remove = function(table_name, conditions)
    if not M.db or not M[table_name] then
        log.error(string.format("DB remove error: Database or table '%s' not initialized.", table_name))
        return false
    end
    local ok = pcall(function()
        M[table_name]:remove(conditions)
    end)
    if not ok then
        log.error(
            string.format("DB remove error in table '%s' with conditions %s.", table_name, vim.inspect(conditions))
        )
        return false
    end
    return true
end

M.init = function()
    if vim.fn.isdirectory(config.save) == 0 then
        local mkdir_ok = pcall(vim.fn.mkdir, config.save, "p")
        if not mkdir_ok then
            notify.error(state.lang.FAILED_TO_CREATE_SAVE_DIRECTORY)
            log.error(string.format("DB init error: Failed to create save directory '%s'.", config.save))
            config.log = false
            return false
        end
    end

    local db_init_ok = pcall(function()
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
        }, M.db)
    end)

    if not db_init_ok then
        notify.error(state.lang.FAILED_TO_CREATE_DB)
        log.error("DB init error: Failed to initialize database or define tables.")
        M.db = nil
        return false
    end
    return true
end

M.close_db_connection = function()
    if M.db then
        local ok = pcall(function()
            if M.db.close then
                M.db:close()
            end
        end)
        if ok then
            M.db = nil
        else
            log.error("DB close error: Failed to close database connection.")
        end
    end
end

return M
