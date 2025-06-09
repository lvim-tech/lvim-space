local M = {}

function M.run()
    local config_ok, config = pcall(require, "lvim-space.config")
    if not config_ok then
        print("Migration Error: Could not load lvim-space.config")
        return false
    end

    local config_path = vim.fn.expand(config.save)
    local db_uri = config_path .. "/lvimspace.db"

    if vim.fn.isdirectory(config_path) == 0 then
        print("Migration Error: Database directory does not exist: " .. config_path)
        return false
    end

    if vim.fn.filereadable(db_uri) == 0 then
        print("Migration Error: Database file does not exist: " .. db_uri)
        return false
    end

    print("Migration: Starting schema migration...")
    print("Migration: Database path: " .. db_uri)

    local exec_function = function(sql_query)
        local temp_sql_file = vim.fn.tempname() .. ".sql"

        local file = io.open(temp_sql_file, "w")
        if not file then
            error("Could not create temporary SQL file")
        end
        file:write(sql_query)
        file:close()

        local cmd = string.format('sqlite3 -header -separator "|" "%s" < "%s"', db_uri, temp_sql_file)
        local handle = io.popen(cmd)
        if not handle then
            os.remove(temp_sql_file)
            error("Could not execute sqlite3 command")
        end

        local output = handle:read("*all")
        local success = handle:close()

        os.remove(temp_sql_file)

        if not success then
            error("sqlite3 command failed")
        end

        if output and output:trim() ~= "" then
            local results = {}
            local lines = vim.split(output:trim(), "\n")

            if sql_query:upper():match("^%s*SELECT") or sql_query:upper():match("^%s*PRAGMA") then
                local headers = nil

                for i, line in ipairs(lines) do
                    if line and line:trim() ~= "" then
                        local parts = vim.split(line, "|")

                        if
                            i == 1
                            and (
                                sql_query:upper():match("PRAGMA")
                                or sql_query:upper():match("SELECT.*FROM.*sqlite_master")
                            )
                        then
                            headers = {}
                            for _, part in ipairs(parts) do
                                table.insert(headers, part:trim())
                            end
                        elseif headers then
                            local row = {}
                            for j, part in ipairs(parts) do
                                if headers[j] then
                                    local value = part:trim()

                                    local num_value = tonumber(value)
                                    if num_value then
                                        row[headers[j]] = num_value
                                    else
                                        row[headers[j]] = value ~= "" and value or nil
                                    end
                                end
                            end
                            table.insert(results, row)
                        else
                            local row = {}

                            if sql_query:match("SELECT name FROM sqlite_master") then
                                row.name = parts[1] and parts[1]:trim()
                            elseif sql_query:match("SELECT id FROM") then
                                local id_val = parts[1] and parts[1]:trim()
                                row.id = tonumber(id_val)
                            elseif sql_query:match("SELECT DISTINCT project_id FROM") then
                                local pid_val = parts[1] and parts[1]:trim()
                                row.project_id = tonumber(pid_val)
                            elseif sql_query:match("SELECT DISTINCT workspace_id FROM") then
                                local wid_val = parts[1] and parts[1]:trim()
                                row.workspace_id = tonumber(wid_val)
                            end

                            if next(row) then
                                table.insert(results, row)
                            end
                        end
                    end
                end
            end

            return results
        end

        return {}
    end

    local test_ok, test_result = pcall(exec_function, "SELECT 1 as test;")
    if not test_ok then
        print("Migration Error: Could not use sqlite3 command: " .. tostring(test_result))
        return false
    end

    print("Migration: Successfully using sqlite3 command line tool")

    print("Migration: Checking existing tables...")
    local tables = M.list_all_tables(exec_function)

    local migration_successful = true
    local tables_to_migrate = { "projects", "workspaces", "tabs" }

    for _, table_name in ipairs(tables_to_migrate) do
        if not M.migrate_table(exec_function, table_name, tables) then
            migration_successful = false
        end
    end

    if migration_successful then
        print("Migration: Schema migration completed successfully.")
        print("Migration: All tables now have sort_order columns and are ready for sorting!")
    else
        print("Migration: Schema migration completed with errors.")
    end

    return migration_successful
end

function M.list_all_tables(exec_function)
    local sql = "SELECT name FROM sqlite_master WHERE type='table';"

    local ok, result = pcall(exec_function, sql)

    if not ok then
        print("Migration: Could not list tables: " .. tostring(result))
        return {}
    end

    if not result or type(result) ~= "table" or #result == 0 then
        print("Migration: No tables found in database")
        return {}
    end

    local table_names = {}
    for _, row in ipairs(result) do
        if row.name and row.name ~= "name" then
            table.insert(table_names, row.name)
        end
    end

    print("Migration: Found tables: " .. table.concat(table_names, ", "))
    return table_names
end

function M.migrate_table(exec_function, table_name, existing_tables)
    print(string.format("Migration: Processing table '%s'", table_name))

    local table_exists = false
    for _, existing_table in ipairs(existing_tables) do
        if existing_table == table_name then
            table_exists = true
            break
        end
    end

    if not table_exists then
        print(string.format("Migration: Table '%s' does not exist yet.", table_name))
        return true
    end

    print(string.format("Migration: Table '%s' exists", table_name))

    local has_sort_order = M.check_sort_order_column_exists(exec_function, table_name)

    if has_sort_order then
        print(string.format("Migration: Table '%s' already has 'sort_order' column.", table_name))
        return true
    end

    if not M.add_sort_order_column(exec_function, table_name) then
        return false
    end

    if not M.populate_initial_sort_order(exec_function, table_name) then
        print(string.format("Migration: Failed to populate 'sort_order' for table '%s'.", table_name))
        return false
    end

    print(string.format("Migration: Table '%s' migrated successfully.", table_name))
    return true
end

function M.check_sort_order_column_exists(exec_function, table_name)
    local sql = string.format("SELECT sql FROM sqlite_master WHERE type='table' AND name='%s';", table_name)

    local ok, result = pcall(exec_function, sql)

    if not ok or not result or #result == 0 then
        print(string.format("Migration: Could not check columns for table '%s'", table_name))
        return false
    end

    for _, row in ipairs(result) do
        if row.sql and row.sql:match("sort_order") then
            return true
        end
    end

    return false
end

function M.add_sort_order_column(exec_function, table_name)
    print(string.format("Migration: Adding 'sort_order' column to table '%s'", table_name))

    local sql = string.format("ALTER TABLE %s ADD COLUMN sort_order INTEGER DEFAULT 0;", table_name)

    local ok, err = pcall(exec_function, sql)

    if not ok then
        if tostring(err):match("duplicate column name") then
            print(string.format("Migration: Column 'sort_order' already exists in table '%s'", table_name))
            return true
        end

        print(string.format("Migration Error: Failed to add 'sort_order' to table '%s': %s", table_name, tostring(err)))
        return false
    end

    print(string.format("Migration: 'sort_order' column added to table '%s'", table_name))
    return true
end

function M.populate_initial_sort_order(exec_function, table_name)
    print(string.format("Migration: Populating initial 'sort_order' for table '%s'", table_name))

    if table_name == "projects" then
        return M.populate_projects_sort_order(exec_function)
    elseif table_name == "workspaces" then
        return M.populate_workspaces_sort_order(exec_function)
    elseif table_name == "tabs" then
        return M.populate_tabs_sort_order(exec_function)
    else
        print(string.format("Migration: Unknown table '%s' for sort_order population", table_name))
        return false
    end
end

function M.populate_projects_sort_order(exec_function)
    local sql = "SELECT id FROM projects WHERE sort_order IS NULL OR sort_order = 0 ORDER BY id;"

    local ok, projects = pcall(exec_function, sql)

    if not ok then
        print("Migration: Could not fetch projects: " .. tostring(projects))
        return false
    end

    if not projects or #projects == 0 then
        print("Migration: No projects need sort_order update")
        return true
    end

    local success = true
    for i, project in ipairs(projects) do
        if project.id then
            local update_sql = string.format("UPDATE projects SET sort_order = %d WHERE id = %d;", i, project.id)

            local update_ok, err = pcall(exec_function, update_sql)

            if not update_ok then
                print(string.format("Migration: Failed to update project ID %d: %s", project.id, tostring(err)))
                success = false
            end
        end
    end

    print(string.format("Migration: Updated sort_order for %d projects", #projects))
    return success
end

function M.populate_workspaces_sort_order(exec_function)
    local sql = "SELECT DISTINCT project_id FROM workspaces WHERE project_id IS NOT NULL;"

    local ok, project_ids = pcall(exec_function, sql)

    if not ok then
        print("Migration: Could not fetch project_ids for workspaces: " .. tostring(project_ids))
        return false
    end

    if not project_ids or #project_ids == 0 then
        print("Migration: No workspaces need sort_order update")
        return true
    end

    local success = true
    local total_updated = 0

    for _, proj_row in ipairs(project_ids) do
        if proj_row.project_id then
            local project_id = proj_row.project_id

            local ws_sql = string.format(
                "SELECT id FROM workspaces WHERE project_id = %d AND (sort_order IS NULL OR sort_order = 0) ORDER BY id;",
                project_id
            )

            local ws_ok, workspaces = pcall(exec_function, ws_sql)

            if not ws_ok then
                print(
                    string.format(
                        "Migration: Could not fetch workspaces for project_id %d: %s",
                        project_id,
                        tostring(workspaces)
                    )
                )
                success = false
            elseif workspaces and #workspaces > 0 then
                for i, workspace in ipairs(workspaces) do
                    if workspace.id then
                        local update_sql =
                            string.format("UPDATE workspaces SET sort_order = %d WHERE id = %d;", i, workspace.id)

                        local update_ok, err = pcall(exec_function, update_sql)

                        if not update_ok then
                            print(
                                string.format(
                                    "Migration: Failed to update workspace ID %d: %s",
                                    workspace.id,
                                    tostring(err)
                                )
                            )
                            success = false
                        else
                            total_updated = total_updated + 1
                        end
                    end
                end
            end
        end
    end

    print(string.format("Migration: Updated sort_order for %d workspaces", total_updated))
    return success
end

function M.populate_tabs_sort_order(exec_function)
    local sql = "SELECT DISTINCT workspace_id FROM tabs WHERE workspace_id IS NOT NULL;"

    local ok, workspace_ids = pcall(exec_function, sql)

    if not ok then
        print("Migration: Could not fetch workspace_ids for tabs: " .. tostring(workspace_ids))
        return false
    end

    if not workspace_ids or #workspace_ids == 0 then
        print("Migration: No tabs need sort_order update")
        return true
    end

    local success = true
    local total_updated = 0

    for _, ws_row in ipairs(workspace_ids) do
        if ws_row.workspace_id then
            local workspace_id = ws_row.workspace_id

            local tabs_sql = string.format(
                "SELECT id FROM tabs WHERE workspace_id = %d AND (sort_order IS NULL OR sort_order = 0) ORDER BY id;",
                workspace_id
            )

            local tabs_ok, tabs = pcall(exec_function, tabs_sql)

            if not tabs_ok then
                print(
                    string.format(
                        "Migration: Could not fetch tabs for workspace_id %d: %s",
                        workspace_id,
                        tostring(tabs)
                    )
                )
                success = false
            elseif tabs and #tabs > 0 then
                for i, tab in ipairs(tabs) do
                    if tab.id then
                        local update_sql = string.format("UPDATE tabs SET sort_order = %d WHERE id = %d;", i, tab.id)

                        local update_ok, err = pcall(exec_function, update_sql)

                        if not update_ok then
                            print(string.format("Migration: Failed to update tab ID %d: %s", tab.id, tostring(err)))
                            success = false
                        else
                            total_updated = total_updated + 1
                        end
                    end
                end
            end
        end
    end

    print(string.format("Migration: Updated sort_order for %d tabs", total_updated))
    return success
end

if not string.trim then
    string.trim = function(s)
        return s:gsub("^%s*(.-)%s*$", "%1")
    end
end

if ... == nil then
    M.run()
end

return M
