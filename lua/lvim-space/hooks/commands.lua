--- Single :LvimSpace dispatcher with hierarchical subcommands.
--- All former :LvimSpace* commands are routed through :LvimSpace <sub> [args].

local state = require("lvim-space.api.state")
local notify = require("lvim-space.api.notify")

local M = {}

-- ---------------------------------------------------------------------------
-- Lazy loaders
-- ---------------------------------------------------------------------------

---@return table
local function get_session()
    return require("lvim-space.core.session")
end

---@return table
local function get_data()
    return require("lvim-space.api.data")
end

-- ---------------------------------------------------------------------------
-- UI open helper
-- ---------------------------------------------------------------------------

--- Open the appropriate lvim-space UI panel.
---@param target string|nil One of "projects"/"p", "workspaces"/"w", "tabs"/"t",
---                         "files"/"f", "search"/"s", or nil for auto-detect.
local function open_lvim_space(target)
    local projects   = require("lvim-space.ui.projects")
    local workspaces = require("lvim-space.ui.workspaces")
    local tabs       = require("lvim-space.ui.tabs")
    local files      = require("lvim-space.ui.files")

    if target == "projects" or target == "p" then
        projects.init()
    elseif target == "workspaces" or target == "w" then
        workspaces.init(nil, { select_workspace = false })
    elseif target == "tabs" or target == "t" then
        tabs.init()
    elseif target == "files" or target == "f" then
        files.init()
    elseif target == "search" or target == "s" then
        require("lvim-space.ui.search").init()
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

-- ---------------------------------------------------------------------------
-- Tab helpers
-- ---------------------------------------------------------------------------

---@param tabs_list table[]
---@return string
local function get_next_tab_name(tabs_list)
    local used = {}
    for _, tab in ipairs(tabs_list) do
        local num = string.match(tab.name or "", "^Tab (%d+)$")
        if num then used[tonumber(num)] = true end
    end
    local i = 1
    while used[i] do i = i + 1 end
    return "Tab " .. tostring(i)
end

local function open_empty_window()
    local keep = vim.api.nvim_get_current_win()
    local wins = vim.api.nvim_list_wins()
    if #wins > 1 then
        for _, win in ipairs(wins) do
            if win ~= keep and vim.api.nvim_win_is_valid(win) then
                vim.api.nvim_win_close(win, true)
            end
        end
    end
    vim.api.nvim_set_current_win(keep)
    vim.cmd("enew")
end

-- ---------------------------------------------------------------------------
-- Tab actions
-- ---------------------------------------------------------------------------

---@return { project_name: string, workspace_name: string, tabs: { id: integer, name: string, active: boolean }[] }
local function tab_get_info()
    local data = get_data()
    local ws   = data.find_workspace_by_id and data.find_workspace_by_id(state.workspace_id, state.project_id)
    local proj = data.find_project_by_id   and data.find_project_by_id(state.project_id)
    local tabs = data.find_tabs             and data.find_tabs(state.workspace_id) or {}
    local result = {
        project_name   = proj and proj.name or "Unknown",
        workspace_name = ws   and ws.name   or "Unknown",
        tabs           = {},
    }
    for _, tab in ipairs(tabs) do
        table.insert(result.tabs, {
            id     = tab.id,
            name   = tab.name,
            active = tostring(tab.id) == tostring(state.tab_active),
        })
    end
    return result
end

---@param offset integer
local function tab_navigate(offset)
    local data    = get_data()
    local session = get_session()
    local tabs    = data.find_tabs and data.find_tabs(state.workspace_id) or {}
    local idx
    for i, tab in ipairs(tabs) do
        if tostring(tab.id) == tostring(state.tab_active) then
            idx = i
            break
        end
    end
    if not idx then notify.warn("No active tab.") return end
    local target = tabs[((idx - 1 + offset) % #tabs) + 1]
    if target then
        session.switch_tab(target.id)
        notify.info("Switched to tab: " .. target.name)
    end
end

---@param tab_name string|nil
local function tab_new(tab_name)
    local data  = get_data()
    local ws_id = state.workspace_id
    if not ws_id then notify.warn("No active workspace.") return end
    local tabs = data.find_tabs and data.find_tabs(ws_id) or {}
    if not tab_name or vim.trim(tab_name) == "" then
        tab_name = get_next_tab_name(tabs)
    end
    local orig, try = tab_name, 0
    while data.is_tab_name_exist and data.is_tab_name_exist(tab_name, ws_id) do
        try = try + 1
        tab_name = orig .. "_" .. tostring(try)
    end
    local json  = vim.fn.json_encode({ buffers = {}, created_at = os.time(), modified_at = os.time() })
    local newid = data.add_tab(tab_name, json, ws_id)
    if not newid or type(newid) ~= "number" or newid <= 0 then
        notify.error("Failed to create tab.")
        return
    end
    state.tab_ids = state.tab_ids or {}
    table.insert(state.tab_ids, newid)
    data.update_workspace_tabs(
        vim.fn.json_encode({ tab_ids = state.tab_ids, tab_active = newid, updated_at = os.time() }),
        ws_id
    )
    state.tab_active = newid
    notify.info("Created new tab: " .. tab_name)
    open_empty_window()
end

---@param tab_id integer|nil
local function tab_close(tab_id)
    local data    = get_data()
    local session = get_session()
    tab_id = tab_id or state.tab_active
    if not tab_id then notify.warn("No tab to close.") return end
    data.delete_tab(tab_id, state.workspace_id)
    notify.info("Tab deleted: " .. tostring(tab_id))
    local remaining = data.find_tabs and data.find_tabs(state.workspace_id) or {}
    if #remaining > 0 then
        session.switch_tab(remaining[1].id)
    else
        notify.warn("No tabs left.")
    end
end

---@param offset integer
local function tab_move(offset)
    local data  = get_data()
    local tabs  = data.find_tabs and data.find_tabs(state.workspace_id) or {}
    local a_tab, a_idx, a_sort
    for i, tab in ipairs(tabs) do
        if tostring(tab.id) == tostring(state.tab_active) then
            a_tab, a_idx, a_sort = tab, i, tonumber(tab.sort_order)
            break
        end
    end
    if not a_tab or not a_sort then notify.warn("No active tab or sort_order not found.") return end
    local t_idx = a_idx + offset
    if t_idx < 1 then t_idx = #tabs elseif t_idx > #tabs then t_idx = 1 end
    local t_tab = tabs[t_idx]
    if not t_tab or not t_tab.sort_order then notify.warn("Target tab not found.") return end
    local t_sort = tonumber(t_tab.sort_order)
    local order  = {}
    for _, tab in ipairs(tabs) do
        local s = tonumber(tab.sort_order)
        if tab.id == a_tab.id then
            table.insert(order, { id = tab.id, order = t_sort })
        elseif tab.id == t_tab.id then
            table.insert(order, { id = tab.id, order = a_sort })
        else
            table.insert(order, { id = tab.id, order = s })
        end
    end
    local ok, err = data.reorder_tabs(state.workspace_id, order)
    if ok then
        notify.info("Tab moved.")
    else
        notify.error("Tab move failed: " .. tostring(err))
    end
end

---@param index integer|string
local function tab_goto(index)
    local data    = get_data()
    local session = get_session()
    local tabs    = data.find_tabs and data.find_tabs(state.workspace_id) or {}
    local entry   = tabs[tonumber(index)]
    if entry and entry.id then
        session.switch_tab(entry.id)
        notify.info("Switched to tab: " .. entry.name)
    else
        notify.warn("Tab with index " .. tostring(index) .. " not found.")
    end
end

---@param new_name string|nil
local function tab_rename(new_name)
    local data = get_data()
    if not state.tab_active or not state.workspace_id then
        notify.warn("No active tab or workspace.")
        return
    end
    if not new_name or vim.trim(new_name) == "" then
        notify.warn("Provide a valid tab name.")
        return
    end
    new_name = vim.trim(new_name)
    if data.is_tab_name_exist and data.is_tab_name_exist(new_name, state.workspace_id) then
        notify.warn("Tab with this name already exists.")
        return
    end
    if data.update_tab_name(state.tab_active, new_name, state.workspace_id) then
        notify.info("Tab renamed to: " .. new_name)
    else
        notify.error("Tab rename failed.")
    end
end

-- ---------------------------------------------------------------------------
-- Public tab API (used by pub.lua and user configs)
-- ---------------------------------------------------------------------------

M.tab = {
    info       = tab_get_info,
    next       = function() tab_navigate(1) end,
    prev       = function() tab_navigate(-1) end,
    new        = tab_new,
    close      = tab_close,
    move       = tab_move,
    goto_index = tab_goto,
    rename     = tab_rename,
}

-- ---------------------------------------------------------------------------
-- Dispatcher table
-- ---------------------------------------------------------------------------

---@alias SubcmdFn fun(args: string[])

---@class SubcmdDef
---@field impl      SubcmdFn           Handler (receives remaining args as a list)
---@field complete? fun():string[]     Optional completion list supplier

---@type table<string, SubcmdDef>
local COMMANDS = {
    -- :LvimSpace open [panel]
    open = {
        impl = function(args)
            open_lvim_space(args[1])
        end,
        complete = function()
            return { "projects", "workspaces", "tabs", "files", "search" }
        end,
    },

    -- :LvimSpace save
    save = {
        impl = function(_)
            if state.tab_active then
                local ok = pcall(get_session().save_current_state, state.tab_active, true)
                if ok then
                    notify.info("State saved successfully")
                else
                    notify.error("Failed to save state")
                end
            else
                notify.warn("No active tab to save")
            end
        end,
    },

    -- :LvimSpace tab <op> [args...]
    tab = {
        impl = function(args)
            local op  = args[1]
            local arg = args[2]
            if not op or op == "" then
                vim.print(tab_get_info())
                return
            end
            if op == "next"      then tab_navigate(1)
            elseif op == "prev"  then tab_navigate(-1)
            elseif op == "new"   then tab_new(arg)
            elseif op == "close" then tab_close(arg ~= nil and tonumber(arg) or nil)
            elseif op == "move-next" then tab_move(1)
            elseif op == "move-prev" then tab_move(-1)
            elseif op == "goto"  then
                if not arg then notify.warn("Provide a tab position (number).") return end
                local idx = tonumber(arg)
                if not idx then notify.warn("Tab index must be a number.") return end
                tab_goto(idx)
            elseif op == "rename" then
                tab_rename(arg)
            elseif op == "info"  then
                vim.print(tab_get_info())
            else
                notify.warn("Unknown tab operation: " .. op)
            end
        end,
        complete = function()
            return { "next", "prev", "new", "close", "move-next", "move-prev", "goto", "rename", "info" }
        end,
    },

    -- :LvimSpace metrics [live]
    metrics = {
        impl = function(args)
            local metrics = require("lvim-space.core.metrics")
            if args[1] == "live" then
                metrics.show_live()
            else
                metrics.show()
            end
        end,
        complete = function()
            return { "live" }
        end,
    },
}

-- ---------------------------------------------------------------------------
-- Completion helper
-- ---------------------------------------------------------------------------

--- Return items from `list` whose prefix matches `lead`.
---@param lead string
---@param list string[]
---@return string[]
local function filter_prefix(lead, list)
    if lead == "" then return list end
    local out = {}
    for _, item in ipairs(list) do
        if vim.startswith(item, lead) then
            table.insert(out, item)
        end
    end
    return out
end

-- ---------------------------------------------------------------------------
-- Registration
-- ---------------------------------------------------------------------------

--- Register the single :LvimSpace dispatcher command and the main keymap.
function M.init()
    local config = require("lvim-space.config")

    vim.api.nvim_create_user_command("LvimSpace", function(opts)
        local parts = vim.split(vim.trim(opts.args or ""), "%s+", { plain = false })
        local sub   = parts[1] or ""

        -- No subcommand → open panel (context-aware)
        if sub == "" then
            open_lvim_space(nil)
            return
        end

        local def = COMMANDS[sub]
        if not def then
            -- Legacy: bare panel names forwarded to open
            local panels = { projects = true, workspaces = true, tabs = true, files = true, search = true }
            if panels[sub] then
                open_lvim_space(sub)
            else
                notify.warn("Unknown LvimSpace subcommand: " .. sub)
            end
            return
        end

        -- Remove the subcommand name; pass remaining tokens to the handler
        local rest = {}
        for i = 2, #parts do
            if parts[i] ~= "" then
                table.insert(rest, parts[i])
            end
        end
        def.impl(rest)
    end, {
        nargs = "*",
        complete = function(lead, line, _)
            -- Tokenise what has been typed so far
            local parts = vim.split(vim.trim(line), "%s+", { plain = false })
            -- parts[1] is "LvimSpace", parts[2] is the subcommand, parts[3+] are sub-args

            local n = #parts

            -- Completing the subcommand itself
            if n <= 2 then
                local top = {}
                for name in pairs(COMMANDS) do table.insert(top, name) end
                -- Also expose bare panel names for convenience
                for _, p in ipairs({ "projects", "workspaces", "tabs", "files", "search" }) do
                    table.insert(top, p)
                end
                table.sort(top)
                return filter_prefix(lead, top)
            end

            -- Completing a sub-argument (e.g. tab op, open panel, metrics live)
            local sub = parts[2]
            local def = COMMANDS[sub]
            if def and def.complete then
                local items = def.complete()
                return filter_prefix(lead, items)
            end

            return {}
        end,
        desc = "LVIM Space – open panel or run subcommand",
    })

    -- Main keymap
    vim.keymap.set("n", config.keymappings.main, function()
        open_lvim_space(nil)
    end, { noremap = true, silent = true, nowait = true, desc = "Open LVIM Space" })
end

return M
