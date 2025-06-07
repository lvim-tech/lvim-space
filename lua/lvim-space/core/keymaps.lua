local config = require("lvim-space.config")
local state = require("lvim-space.api.state")
local projects = require("lvim-space.ui.projects")
local workspaces = require("lvim-space.ui.workspaces")
local tabs = require("lvim-space.ui.tabs")
local files = require("lvim-space.ui.files")

local M = {}

function M.init()
    vim.keymap.set("n", config.keymappings.main, function()
        if not state.project_id then
            projects.init()
            return
        end

        if not state.workspace_id then
            workspaces.init(nil, { select_workspace = false })
            return
        end

        if not state.tab_active then
            tabs.init()
            return
        end

        files.init()
    end, {
        noremap = true,
        silent = true,
        nowait = true,
    })
end

function M.enable_base_maps(buf)
    vim.api.nvim_buf_set_keymap(buf, "n", "<Esc>", "", {
        nowait = true,
        noremap = true,
        silent = true,
        callback = function()
            require("lvim-space.ui").close_all()
        end,
    })
end

M.disable_all_maps = function(buf)
    local letters = {}
    for c = string.byte("a"), string.byte("z") do
        local ch = string.char(c)
        if ch ~= "j" and ch ~= "k" then
            table.insert(letters, ch)
        end
    end
    for c = string.byte("A"), string.byte("Z") do
        table.insert(letters, string.char(c))
    end
    for d = 0, 9 do
        table.insert(letters, tostring(d))
    end
    local keys = { "$", "gg", "G", "<C-d>", "<C-u>", "<Left>", "<Right>", "<Up>", "<Down>", "<Space>", "BS" }
    for _, k in ipairs(letters) do
        table.insert(keys, k)
    end
    for _, key in ipairs(keys) do
        vim.keymap.set("n", key, "<nop>", { buffer = buf })
    end
end

return M
