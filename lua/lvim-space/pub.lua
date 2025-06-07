local M = {}

function M.get_tab_info()
    local data = require("lvim-space.api.data")
    local state = require("lvim-space.api.state")
    local workspace_id = state.workspace_id
    local tabs = data.find_tabs and data.find_tabs(workspace_id) or {}
    local active_id = state.tab_active

    local result = {}
    for _, tab in ipairs(tabs) do
        table.insert(result, {
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
