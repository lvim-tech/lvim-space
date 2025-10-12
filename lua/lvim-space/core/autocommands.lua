local config = require("lvim-space.config")
local api = vim.api
local db = require("lvim-space.persistence.db")
local session = require("lvim-space.core.session")
local state = require("lvim-space.api.state")
local data = require("lvim-space.api.data")
local notify = require("lvim-space.api.notify")

local M = {}

local cache = {
    initialized = false,
    is_saving = false,
    save_timer = nil,
}

local function load_context()
    state.project_id = nil
    state.workspace_id = nil
    state.tab_active = nil
    state.tab_ids = {}
    if config.autorestore then
        local current_project = data.find_project_by_cwd()
        if current_project then
            state.project_id = current_project.id
            local active_ws = data.find_current_workspace(current_project.id)
            if active_ws then
                state.workspace_id = active_ws.id
                local active_tab = data.find_current_tab(active_ws.id, current_project.id)
                if active_tab then
                    state.tab_active = active_tab.id
                    for _, t in ipairs(active_tab.all_tabs or {}) do
                        table.insert(state.tab_ids, t.id)
                    end
                    vim.schedule(function()
                        local ok, err = pcall(session.force_restore, active_tab.id)
                        if not ok then
                            vim.notify("LVIM Space restore skipped: " .. tostring(err), vim.log.levels.WARN)
                        end
                    end)
                end
            end
        end
    end
end

local function save_session()
    if cache.is_saving or not state.tab_active then
        return
    end
    cache.is_saving = true
    if cache.save_timer then
        vim.fn.timer_stop(cache.save_timer)
    end
    cache.save_timer = vim.fn.timer_start(200, function()
        cache.save_timer = nil
        pcall(session.save_current_state, state.tab_active, true)
        cache.is_saving = false
    end)
end

local function initialize()
    if cache.initialized then
        return
    end
    if not db.init() then
        notify.error("Failed to initialize database")
        return
    end
    load_context()
    pcall(session.init)
    cache.initialized = true
end

local function cleanup()
    if cache.save_timer then
        vim.fn.timer_stop(cache.save_timer)
    end
    if state.tab_active then
        pcall(session.save_current_state, state.tab_active, true)
    end
    pcall(db.close_db_connection)
end

M.init = function()
    local augroup = api.nvim_create_augroup("LvimSpaceAutocommands", { clear = true })
    api.nvim_create_autocmd("VimEnter", {
        group = augroup,
        callback = function()
            vim.schedule(initialize)
        end,
        desc = "LVIM Space: Initialize on VimEnter",
    })
    api.nvim_create_autocmd("VimLeavePre", {
        group = augroup,
        callback = cleanup,
        desc = "LVIM Space: Cleanup on VimLeavePre",
    })
    api.nvim_create_autocmd({ "FocusLost", "CursorHold" }, {
        group = augroup,
        callback = save_session,
        desc = "LVIM Space: Auto-save session",
    })
    api.nvim_create_autocmd("DirChanged", {
        group = augroup,
        callback = load_context,
        desc = "LVIM Space: Reload context on directory change",
    })
    api.nvim_create_user_command("LvimSpaceSave", function()
        if state.tab_active then
            local success = pcall(session.save_current_state, state.tab_active, true)
            if success then
                notify.info("State saved successfully")
            else
                notify.error("Failed to save state")
            end
        else
            notify.warn("No active tab to save")
        end
    end, { desc = "Manually save LVIM Space state" })
end

M.force_save = function()
    if state.tab_active then
        return pcall(session.save_current_state, state.tab_active, true)
    end
    return false
end

M.reload_context = load_context

M.is_initialized = function()
    return cache.initialized
end

M.get_stats = function()
    return {
        initialized = cache.initialized,
        is_saving = cache.is_saving,
        project_id = state.project_id,
        workspace_id = state.workspace_id,
        tab_active = state.tab_active,
    }
end

return M
