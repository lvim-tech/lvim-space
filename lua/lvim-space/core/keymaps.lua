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
            local options = { "projects", "workspaces", "tabs", "files", "search" }
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
    local key_conf = config.key_control or {}
    local allowed_keys_map = {}
    for _, k_allowed in ipairs(key_conf.allowed or {}) do
        allowed_keys_map[k_allowed] = true
    end
    local keys_to_potentially_disable = {}
    local categories = key_conf.disable_categories
        or {
            lowercase_letters = true,
            uppercase_letters = true,
            digits = true,
        }
    if categories.lowercase_letters then
        for c = string.byte("a"), string.byte("z") do
            table.insert(keys_to_potentially_disable, string.char(c))
        end
    end
    if categories.uppercase_letters then
        for c = string.byte("A"), string.byte("Z") do
            table.insert(keys_to_potentially_disable, string.char(c))
        end
    end
    if categories.digits then
        for d = 0, 9 do
            table.insert(keys_to_potentially_disable, tostring(d))
        end
    end
    for _, k_disabled in ipairs(key_conf.explicitly_disabled or {}) do
        local found = false
        for _, k_existing in ipairs(keys_to_potentially_disable) do
            if k_existing == k_disabled then
                found = true
                break
            end
        end
        if not found then
            table.insert(keys_to_potentially_disable, k_disabled)
        end
    end
    for _, key_to_check in ipairs(keys_to_potentially_disable) do
        if not allowed_keys_map[key_to_check] then
            vim.keymap.set("n", key_to_check, "<nop>", { buffer = buf, nowait = true, silent = true })
        end
    end
end

M.open = function(target)
    open_lvim_space(target)
end

return M
