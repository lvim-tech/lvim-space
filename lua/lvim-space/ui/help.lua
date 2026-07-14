-- lvim-space.ui.help: the panel keymap CHEATSHEET (`g?`) — the rows every entity panel (projects /
-- workspaces / tabs / files) shares, built from the LIVE `config.keymappings` so a rebind is reflected and
-- an unset key drops its row. The window itself — the rows, the column alignment, the odd/even striping,
-- the hidden cursor and the colours — belongs to the shared `lvim-ui.help` component; nothing is laid out
-- or themed here.
--
---@module "lvim-space.ui.help"

local config = require("lvim-space.config")

local M = {}

-- ACTION keys (`config.keymappings.action`) → description, in display order.
---@type { [1]: string, [2]: string }[]
local ACTIONS = {
    { "switch", "load the entity (stay in the panel)" },
    { "enter", "enter the entity (close the panels)" },
    { "add", "add" },
    { "rename", "rename" },
    { "delete", "delete" },
    { "split_v", "open in a vertical split (files)" },
    { "split_h", "open in a horizontal split (files)" },
    { "move_up", "move the entity up (reorder)" },
    { "move_down", "move the entity down (reorder)" },
}

-- PANEL keys (`config.keymappings.global`) → description, in display order.
---@type { [1]: string, [2]: string }[]
local PANELS = {
    { "projects", "go to the Projects panel" },
    { "workspaces", "go to the Workspaces panel" },
    { "tabs", "go to the Tabs panel" },
    { "files", "go to the Files panel" },
    { "search", "search (the fuzzy picker)" },
}

--- Open the panel keymap cheatsheet. Only the LIVE, SET keys appear.
function M.show()
    local km = config.keymappings or {}
    local action = km.action or {}
    local global = km.global or {}
    local items = {}
    ---@param lhs string|nil
    ---@param desc string
    local function add(lhs, desc)
        if type(lhs) == "string" and lhs ~= "" then
            items[#items + 1] = { lhs, desc }
        end
    end
    for _, e in ipairs(ACTIONS) do
        add(action[e[1]], e[2])
    end
    for _, e in ipairs(PANELS) do
        add(global[e[1]], e[2])
    end
    add(action.help, "this help")
    require("lvim-ui").help({
        title = "Space keymaps",
        items = items,
        close_keys = { "q", "<Esc>", action.help or "g?" },
    })
end

return M
