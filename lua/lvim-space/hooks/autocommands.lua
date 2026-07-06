-- lvim-space.hooks.autocommands: the plugin's global autocommands — VimEnter initialisation, VimLeavePre
-- cleanup, periodic session autosaves and DirChanged context reloading. Kept in one place so the lifecycle
-- ordering (init before autosave, save before leave) is obvious and the debounced timers share one cache.
--
---@module "lvim-space.hooks.autocommands"

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

---@type AutocmdCache
local cache = {
    initialized = false,
}

-- ---------------------------------------------------------------------------
-- Load context from the database for the current working directory.
-- ---------------------------------------------------------------------------

--- Whether `cwd` lies inside `project_path` (same directory or a descendant). Both are absolutised and
--- given a trailing slash first, so a prefix test can never match a sibling like `/foo-bar` against `/foo`.
---@param project_path string|nil Absolute project root path.
---@param cwd string|nil Current working directory.
---@return boolean inside True when `cwd` is `project_path` or a subdirectory of it.
local function cwd_within_project(project_path, cwd)
    if not project_path or not cwd then
        return false
    end
    local proj = vim.fn.fnamemodify(project_path, ":p")
    local here = vim.fn.fnamemodify(cwd, ":p")
    if not proj:match("/$") then
        proj = proj .. "/"
    end
    if not here:match("/$") then
        here = here .. "/"
    end
    return vim.startswith(here, proj)
end

--- Resolve and load the project/workspace/tab context for the current working directory.
--- Populates `state.project_id`, `state.workspace_id`, `state.tab_active`, and `state.tab_ids`. Triggers a
--- session restore when `config.autorestore` is true and a valid tab is found. The active tab is saved
--- BEFORE any state is wiped, and the context is left untouched when the new cwd resolves to the SAME
--- project or is merely a subdirectory of it (so `:cd src/` never detaches the session).
local function load_context()
    -- Persist the current layout before a directory change can wipe it.
    if config.autosave and state.tab_active then
        pcall(session.save_current_state, state.tab_active, true)
    end

    if not config.autorestore then
        state.project_id = nil
        state.workspace_id = nil
        state.tab_active = nil
        state.tab_ids = {}
        return
    end

    local current_project = data.find_project_by_cwd()

    -- Descended into a subdir of the already-active project (exact cwd lookup misses it): stay attached.
    if not current_project and state.project_id then
        local active = data.find_project_by_id(state.project_id)
        if active and cwd_within_project(active.path, (vim.uv or vim.loop).cwd()) then
            return
        end
    end

    -- Resolved to the project that is already loaded: nothing to reset.
    if current_project and tostring(current_project.id) == tostring(state.project_id) then
        return
    end

    -- A genuinely different (or no) project: reset, then load the resolved one.
    state.project_id = nil
    state.workspace_id = nil
    state.tab_active = nil
    state.tab_ids = {}

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
        local ok, tabs_obj = pcall(vim.json.decode, active_ws.tabs)
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

--- Force-save the active tab, then close the database. This is the SINGLE VimLeavePre owner: the save must
--- happen before the DB handle is closed, so session.lua deliberately does not also register VimLeavePre.
--- Invoked by the VimLeavePre autocommand.
local function cleanup()
    if state.tab_active then
        pcall(session.save_current_state, state.tab_active, true)
    end
    pcall(db.close_db_connection)
end

-- ---------------------------------------------------------------------------
-- Public
-- ---------------------------------------------------------------------------

--- Register all global lvim-space autocommands (VimEnter, VimLeavePre, DirChanged). Must be called once
--- during plugin setup. The autosave triggers (BufEnter/WinEnter/FocusGained/FocusLost/CursorHold) are owned
--- solely by `session.setup_autocmds` — registering them here too double-saved on every CursorHold.
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
    api.nvim_create_autocmd("DirChanged", {
        group = augroup,
        pattern = "global",
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
---@field project_id integer|nil Active project ID from state.
---@field workspace_id integer|nil Active workspace ID from state.
---@field tab_active integer|nil Active tab ID from state.

--- Return a snapshot of the autocommand module's runtime state.
---@return AutocmdStats stats Current state values.
M.get_stats = function()
    return {
        initialized = cache.initialized,
        project_id = state.project_id,
        workspace_id = state.workspace_id,
        tab_active = state.tab_active,
    }
end

return M
