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

vim.api.nvim_create_user_command("LvimSpaceTabs", function()
    local tabs = M.get_tab_info()
    print(vim.inspect(tabs))
end, {})

vim.api.nvim_create_user_command("LvimSpaceNextTab", function()
    M.next_tab()
end, {})

vim.api.nvim_create_user_command("LvimSpacePrevTab", function()
    M.prev_tab()
end, {})

vim.api.nvim_create_user_command("LvimSpaceCloseTab", function(opts)
    M.close_tab(opts.args ~= "" and opts.args or nil)
end, { nargs = "?" })

return M
