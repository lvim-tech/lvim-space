local config = require("lvim-space.config")
local notify = require("lvim-space.api.notify")
local log = require("lvim-space.api.log")
local state = require("lvim-space.api.state")
local sqlite = require("sqlite.db")
local tbl = require("sqlite.tbl")

local uri = config.save .. "/lvimspace.db"

local M = {}
M.db = nil

M.find = function(table_name, conditions, options)
    if not M.db or not M[table_name] then
        log.error(string.format("DB find error: Database or table '%s' not initialized.", table_name))
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
        log.error(
            string.format(
                "DB find error in table '%s' with query %s. Error: %s",
                table_name,
                vim.inspect(query_options),
                tostring(result_data)
            )
        )
        return false
    end

    if result_data == nil or (type(result_data) == "table" and not next(result_data)) then
        return nil
    end

    return result_data
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
        log.error(
            string.format(
                "DB insert error in table '%s' with values %s. Error: %s",
                table_name,
                vim.inspect(values),
                tostring(row_id)
            )
        )
        return false
    end
    return row_id
end

M.update = function(table_name, conditions, values)
    if not M.db or not M[table_name] then
        log.error(string.format("DB update error: Database or table '%s' not initialized.", table_name))
        return false
    end
    local ok, err = pcall(function()
        M[table_name]:update({ where = conditions, set = values })
    end)
    if not ok then
        log.error(
            string.format(
                "DB update error in table '%s' with conditions %s and values %s. Error: %s",
                table_name,
                vim.inspect(conditions),
                vim.inspect(values),
                tostring(err)
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
    local ok, err = pcall(function()
        M[table_name]:remove(conditions)
    end)
    if not ok then
        log.error(
            string.format(
                "DB remove error in table '%s' with conditions %s. Error: %s",
                table_name,
                vim.inspect(conditions),
                tostring(err)
            )
        )
        return false
    end
    return true
end

M.init = function()
    if vim.fn.isdirectory(config.save) == 0 then
        local mkdir_ok, mkdir_err = pcall(vim.fn.mkdir, config.save, "p")
        if not mkdir_ok then
            notify.error(
                (state.lang and state.lang.FAILED_TO_CREATE_SAVE_DIRECTORY)
                    or "Failed to create save directory for database."
            )
            log.error(
                string.format(
                    "DB init error: Failed to create save directory '%s'. Error: %s",
                    config.save,
                    tostring(mkdir_err)
                )
            )
            config.log = false
            return false
        end
    end

    local db_init_ok, db_init_err_msg = pcall(function()
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
        log.error(
            string.format(
                "DB init error: Failed to initialize database or define tables. Error: %s",
                tostring(db_init_err_msg)
            )
        )
        M.db = nil
        return false
    end
    log.info("lvim-space database initialized successfully at: " .. uri)
    return true
end

M.close_db_connection = function()
    if M.db then
        local ok, err = pcall(function()
            if M.db.close then
                M.db:close()
            end
        end)
        if ok then
            log.info("lvim-space database connection closed.")
            M.db = nil
        else
            log.error(string.format("DB close error: Failed to close database connection. Error: %s", tostring(err)))
        end
    end
end

M.exec = function(sql_query)
    if not M.db then
        log.error("DB exec error: Database not initialized.")
        return false
    end
    local ok, result = pcall(function()
        return M.db:exec(sql_query)
    end)
    if not ok then
        log.error(string.format("DB exec error with query '%s'. Error: %s", sql_query, tostring(result)))
        return false
    end
    return result
end

return M
