--- Global autocommands for lvim-space.
--- Handles VimEnter initialization, VimLeavePre cleanup, periodic session saves,
--- and directory-change context reloading.

local config = require("lvim-space.config")
local api = vim.api
local db = require("lvim-space.persistence.db")
local session = require("lvim-space.core.session")
local state = require("lvim-space.api.state")
local data = require("lvim-space.api.data")
local notify = require("lvim-space.api.notify")

local M = {}

---@class AutocmdCache
---@field initialized boolean True after `initialize()` has run successfully.
---@field is_saving boolean True while a debounced save timer is pending.
---@field save_timer integer|nil Handle for the active debounce timer, or nil.

---@type AutocmdCache
local cache = {
    initialized = false,
    is_saving = false,
    save_timer = nil,
}

-- ---------------------------------------------------------------------------
-- Load context from the database for the current working directory.
-- ---------------------------------------------------------------------------

--- Resolve and load the project/workspace/tab context for the current working directory.
--- Populates `state.project_id`, `state.workspace_id`, `state.tab_active`, and
--- `state.tab_ids`. Triggers a session restore when `config.autorestore` is true
--- and a valid tab is found.
local function load_context()
    state.project_id = nil
    state.workspace_id = nil
    state.tab_active = nil
    state.tab_ids = {}

    if not config.autorestore then
        return
    end

    local current_project = data.find_project_by_cwd()
    if not current_project then
        return
    end

    state.project_id = current_project.id

    local active_ws = data.find_current_workspace(current_project.id)
    if not active_ws then
        return
    end

    state.workspace_id = active_ws.id

    -- Decode the workspace tabs JSON to restore tab state.
    if active_ws.tabs then
        local ok, tabs_obj = pcall(vim.fn.json_decode, active_ws.tabs)
        if ok and tabs_obj then
            state.tab_active = tabs_obj.tab_active
            state.tab_ids = tabs_obj.tab_ids or {}
        end
    end

    if state.tab_active then
        vim.schedule(function()
            local ok, err = pcall(session.force_restore, state.tab_active)
            if not ok then
                notify.warn("LVIM Space restore skipped: " .. tostring(err))
            end
        end)
    end
end

-- ---------------------------------------------------------------------------
-- Debounced session save.
-- ---------------------------------------------------------------------------

--- Debounced session save: waits 200 ms after the last trigger before writing.
--- Does nothing when a save is already pending or no tab is active.
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

-- ---------------------------------------------------------------------------
-- One-time initialization (called on VimEnter).
-- ---------------------------------------------------------------------------

--- One-time plugin initialization called on VimEnter.
--- Initialises the database, loads the context, and sets up session autocommands.
--- Subsequent calls are no-ops (guarded by `cache.initialized`).
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

-- ---------------------------------------------------------------------------
-- Cleanup on exit.
-- ---------------------------------------------------------------------------

--- Cancel any pending save timer, force-save the active tab, and close the database.
--- Invoked by the VimLeavePre autocommand.
local function cleanup()
    if cache.save_timer then
        vim.fn.timer_stop(cache.save_timer)
    end
    if state.tab_active then
        pcall(session.save_current_state, state.tab_active, true)
    end
    pcall(db.close_db_connection)
end

-- ---------------------------------------------------------------------------
-- Public
-- ---------------------------------------------------------------------------

--- Register all global lvim-space autocommands (VimEnter, VimLeavePre, FocusLost,
--- CursorHold, DirChanged). Must be called once during plugin setup.
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
end

--- Force-save the active tab session immediately (no debounce).
---@return boolean success True when the pcall succeeded; false when no tab is active.
M.force_save = function()
    if state.tab_active then
        return pcall(session.save_current_state, state.tab_active, true)
    end
    return false
end
--- Re-run context loading for the current working directory.
--- Alias for the internal `load_context` function.
M.reload_context = load_context

--- Return whether the plugin has completed its one-time initialization.
---@return boolean initialized True after `initialize()` has succeeded.
M.is_initialized = function()
    return cache.initialized
end

---@class AutocmdStats
---@field initialized boolean Whether the plugin is initialized.
---@field is_saving boolean Whether a debounced save is currently pending.
---@field project_id integer|nil Active project ID from state.
---@field workspace_id integer|nil Active workspace ID from state.
---@field tab_active integer|nil Active tab ID from state.

--- Return a snapshot of the autocommand module's runtime state.
---@return AutocmdStats stats Current state values.
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
