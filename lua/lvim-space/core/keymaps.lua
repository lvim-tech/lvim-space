local config = require("lvim-space.config")
local state = require("lvim-space.api.state")
local projects = require("lvim-space.ui.projects")
local workspaces = require("lvim-space.ui.workspaces")
local tabs = require("lvim-space.ui.tabs")
local files = require("lvim-space.ui.files")

local M = {}

local function open_lvim_space(target)
    if target == "projects" or target == "p" then
        projects.init()
    elseif target == "workspaces" or target == "w" then
        workspaces.init(nil, { select_workspace = false })
    elseif target == "tabs" or target == "t" then
        tabs.init()
    elseif target == "files" or target == "f" then
        files.init()
    else
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
    end
end

function M.init()
    vim.keymap.set("n", config.keymappings.main, function()
        open_lvim_space()
    end, {
        noremap = true,
        silent = true,
        nowait = true,
        desc = "Open LVIM Space",
    })

    vim.api.nvim_create_user_command("LvimSpace", function(opts)
        local args = vim.split(opts.args or "", "%s+")
        local target = args[1]
        open_lvim_space(target)
    end, {
        nargs = "?",
        complete = function(ArgLead, _, _)
            local options = { "projects", "workspaces", "tabs", "files" }
            if ArgLead == "" then
                return options
            end

            local matches = {}
            for _, option in ipairs(options) do
                if option:find("^" .. ArgLead) then
                    table.insert(matches, option)
                end
            end
            return matches
        end,
        desc = "Open LVIM Space interface",
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

M.open = function(target)
    open_lvim_space(target)
end

return M
