local M = {}

function M.get_tab_info()
    local data = require("lvim-space.api.data")
    local state = require("lvim-space.api.state")
    local workspace_id = state.workspace_id
    local tabs = data.find_tabs and data.find_tabs(workspace_id) or {}
    local active_id = state.tab_active
    local workspace = data.find_workspace_by_id and data.find_workspace_by_id(workspace_id, state.project_id)
    local workspace_name = workspace and workspace.name or "Unknown"
    local project = data.find_project_by_id and data.find_project_by_id(state.project_id)
    local project_name = project and project.name or "Unknown"
    local result = {
        project_name = project_name,
        workspace_name = workspace_name,
        tabs = {},
    }
    for _, tab in ipairs(tabs) do
        table.insert(result.tabs, {
            id = tab.id,
            name = tab.name,
            active = tostring(tab.id) == tostring(active_id),
        })
    end
    return result
end

function M.next_tab()
    local data = require("lvim-space.api.data")
    local state = require("lvim-space.api.state")
    local session = require("lvim-space.core.session")
    local workspace_id = state.workspace_id
    local tabs = data.find_tabs and data.find_tabs(workspace_id) or {}
    local active_id = state.tab_active
    local active_index = nil
    for i, tab in ipairs(tabs) do
        if tostring(tab.id) == tostring(active_id) then
            active_index = i
            break
        end
    end
    if not active_index then
        print("No active tab.")
        return
    end
    local next_index = active_index + 1
    if next_index > #tabs then
        next_index = 1
    end
    local next_tab = tabs[next_index]
    if next_tab then
        session.switch_tab(next_tab.id)
        print("Switched to tab: " .. next_tab.name)
    end
end

function M.prev_tab()
    local data = require("lvim-space.api.data")
    local state = require("lvim-space.api.state")
    local session = require("lvim-space.core.session")
    local workspace_id = state.workspace_id
    local tabs = data.find_tabs and data.find_tabs(workspace_id) or {}
    local active_id = state.tab_active
    local active_index = nil
    for i, tab in ipairs(tabs) do
        if tostring(tab.id) == tostring(active_id) then
            active_index = i
            break
        end
    end
    if not active_index then
        print("No active tab.")
        return
    end
    local prev_index = active_index - 1
    if prev_index < 1 then
        prev_index = #tabs
    end
    local prev_tab = tabs[prev_index]
    if prev_tab then
        session.switch_tab(prev_tab.id)
        print("Switched to tab: " .. prev_tab.name)
    end
end

local function get_next_tab_name(tabs)
    local used = {}
    for _, tab in ipairs(tabs) do
        local num = string.match(tab.name or "", "^Tab (%d+)$")
        if num then
            used[tonumber(num)] = true
        end
    end
    local i = 1
    while used[i] do
        i = i + 1
    end
    return "Tab " .. tostring(i)
end

function M.new_tab(tab_name)
    local data = require("lvim-space.api.data")
    local state = require("lvim-space.api.state")
    local workspace_id = state.workspace_id
    if not workspace_id then
        print("No active workspace.")
        return
    end
    local tabs = data.find_tabs and data.find_tabs(workspace_id) or {}
    if not tab_name or vim.trim(tab_name) == "" then
        tab_name = get_next_tab_name(tabs)
    end
    if data.is_tab_name_exist and data.is_tab_name_exist(tab_name, workspace_id) then
        print("Tab with this name already exists.")
        return
    end
    local tab_data_obj = { buffers = {}, created_at = os.time(), modified_at = os.time() }
    local tab_data_json_str = vim.fn.json_encode(tab_data_obj)
    local new_tab_id = data.add_tab(tab_name, tab_data_json_str, workspace_id)
    if not new_tab_id or type(new_tab_id) ~= "number" or new_tab_id <= 0 then
        print("Failed to create tab.")
        return
    end
    table.insert(state.tab_ids, new_tab_id)
    if data.update_workspace_tabs then
        local ws_tabs = {
            tab_ids = state.tab_ids,
            tab_active = new_tab_id,
            updated_at = os.time(),
        }
        data.update_workspace_tabs(vim.fn.json_encode(ws_tabs), workspace_id)
    end
    state.tab_active = new_tab_id
    print("Created new tab: " .. tab_name)
end

function M.close_tab(tab_id)
    local data = require("lvim-space.api.data")
    local state = require("lvim-space.api.state")
    local session = require("lvim-space.core.session")
    local workspace_id = state.workspace_id
    tab_id = tab_id or state.tab_active
    if not tab_id then
        print("No tab id to close.")
        return
    end
    if data.delete_tab then
        data.delete_tab(tab_id, workspace_id)
        print("Tab deleted: " .. tostring(tab_id))
    else
        print("No delete_tab API implemented!")
        return
    end
    local tabs = data.find_tabs and data.find_tabs(workspace_id) or {}
    if #tabs > 0 then
        session.switch_tab(tabs[1].id)
    else
        print("No tabs left.")
    end
end

function M.move_tab(offset)
    local data = require("lvim-space.api.data")
    local state = require("lvim-space.api.state")
    local workspace_id = state.workspace_id
    local tabs = data.find_tabs and data.find_tabs(workspace_id) or {}
    local active_id = state.tab_active
    local active_tab, active_index, active_sort
    for i, tab in ipairs(tabs) do
        if tostring(tab.id) == tostring(active_id) then
            active_tab = tab
            active_index = i
            active_sort = tonumber(tab.sort_order)
            break
        end
    end
    if not active_tab or not active_sort then
        print("No active tab or sort_order not found.")
        return
    end
    local num_tabs = #tabs
    local target_index = active_index + offset
    if target_index < 1 then
        target_index = num_tabs
    elseif target_index > num_tabs then
        target_index = 1
    end
    local target_tab = tabs[target_index]
    if not target_tab or not target_tab.sort_order then
        print("Target tab not found.")
        return
    end
    local target_sort = tonumber(target_tab.sort_order)
    local new_order_table = {}
    for _, tab in ipairs(tabs) do
        if tab.id == active_tab.id then
            table.insert(new_order_table, { id = tab.id, order = target_sort })
        elseif tab.id == target_tab.id then
            table.insert(new_order_table, { id = tab.id, order = active_sort })
        else
            table.insert(new_order_table, { id = tab.id, order = tonumber(tab.sort_order) })
        end
    end
    local success, err = data.reorder_tabs(workspace_id, new_order_table)
    if success then
        print("Tab moved.")
    else
        print("Tab move failed: " .. tostring(err))
    end
end

function M.goto_tab_by_index(index)
    local data = require("lvim-space.api.data")
    local state = require("lvim-space.api.state")
    local session = require("lvim-space.core.session")
    local workspace_id = state.workspace_id
    local tabs = data.find_tabs and data.find_tabs(workspace_id) or {}
    local tab_entry = tabs[tonumber(index)]
    if tab_entry and tab_entry.id then
        session.switch_tab(tab_entry.id)
        print("Switched to tab: " .. tab_entry.name)
    else
        print("Tab with index " .. tostring(index) .. " not found.")
    end
end

function M.rename_active_tab(new_name)
    local data = require("lvim-space.api.data")
    local state = require("lvim-space.api.state")
    local workspace_id = state.workspace_id
    local tab_id = state.tab_active

    if not tab_id or not workspace_id then
        print("No active tab or workspace.")
        return
    end

    if not new_name or vim.trim(new_name) == "" then
        print("Please provide a valid tab name.")
        return
    end

    -- Провери дали вече има таб с това име (ако имаш такава функция)
    if data.is_tab_name_exist and data.is_tab_name_exist(vim.trim(new_name), workspace_id) then
        print("Tab with this name already exists.")
        return
    end

    local success = data.update_tab_name(tab_id, new_name, workspace_id)
    if success then
        print("Tab renamed to: " .. new_name)
    else
        print("Tab rename failed.")
    end
end

vim.api.nvim_create_user_command("LvimSpaceTabs", function()
    local tabs = M.get_tab_info()
    print(vim.inspect(tabs))
end, {})

vim.api.nvim_create_user_command("LvimSpaceTabNext", function()
    M.next_tab()
end, {})

vim.api.nvim_create_user_command("LvimSpaceTabPrev", function()
    M.prev_tab()
end, {})

vim.api.nvim_create_user_command("LvimSpaceTabNew", function(opts)
    local name = opts.args
    M.new_tab(name)
end, { nargs = "?" })

vim.api.nvim_create_user_command("LvimSpaceTabClose", function(opts)
    M.close_tab(opts.args ~= "" and opts.args or nil)
end, { nargs = "?" })

vim.api.nvim_create_user_command("LvimSpaceTabMoveNext", function()
    M.move_tab(1)
end, {})

vim.api.nvim_create_user_command("LvimSpaceTabMovePrev", function()
    M.move_tab(-1)
end, {})

vim.api.nvim_create_user_command("LvimSpaceTab", function(opts)
    local index = tonumber(opts.args)
    if not index then
        print("Please provide a tab position (number).")
        return
    end
    M.goto_tab_by_index(index)
end, { nargs = 1 })

vim.api.nvim_create_user_command("LvimSpaceTabRename", function(opts)
    local new_name = opts.args
    M.rename_active_tab(new_name)
end, { nargs = 1 })

return M
