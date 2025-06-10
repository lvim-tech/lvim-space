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

vim.api.nvim_create_user_command("LvimSpaceTabs", function()
    local tabs = M.get_tab_info()
    print(vim.inspect(tabs))
end, {})

return M
