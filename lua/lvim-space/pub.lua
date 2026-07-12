-- lvim-space.pub: the STABLE public API for external integrations (statuslines, dashboards, other plugins).
-- Every function is safe to require and call at any time — before setup(), before a session exists — returning
-- empty/safe defaults rather than erroring, so consumers never have to guard the plugin's init order.
--
---@module "lvim-space.pub"

local M = {}

---True when the current working directory has a saved lvim-space project — i.e. a startup WILL auto-load it.
---Opens the DB first (idempotent), so it is safe to call EARLY, before the plugin's own VimEnter init has run
---— e.g. from the start dashboard's `should_open` predicate, so the dashboard does not flash before lvim-space
---takes over the screen.
---@return boolean
function M.has_project_for_cwd()
    local ok_db, db = pcall(require, "lvim-space.persistence.db")
    local ok_data, data = pcall(require, "lvim-space.api.data")
    if not (ok_db and ok_data) then
        return false
    end
    if not db.init() then
        return false
    end
    local ok, project = pcall(data.find_project_by_cwd)
    return ok and project ~= nil
end

---Return a summary of the current project / workspace / tab state.
---Designed for statusline integrations (lualine, tabby, etc.).
---@return { project_name: string, workspace_name: string, tabs: { id: integer, name: string, active: boolean }[] }
function M.get_tab_info()
    local ok, commands = pcall(require, "lvim-space.hooks.commands")
    if ok and commands and commands.tab and commands.tab.info then
        return commands.tab.info()
    end
    -- Fallback: query state and data directly
    local ok_state, state = pcall(require, "lvim-space.api.state")
    local ok_data, data = pcall(require, "lvim-space.api.data")
    if not ok_state or not ok_data then
        return { project_name = "Unknown", workspace_name = "Unknown", tabs = {} }
    end
    local ws = ok_data and data.find_workspace_by_id and data.find_workspace_by_id(state.workspace_id, state.project_id)
    local proj = ok_data and data.find_project_by_id and data.find_project_by_id(state.project_id)
    local tabs = ok_data and data.find_tabs and data.find_tabs(state.workspace_id) or {}
    local result = {
        project_name = (proj and proj.name) or "Unknown",
        workspace_name = (ws and ws.name) or "Unknown",
        tabs = {},
    }
    for _, tab in ipairs(tabs) do
        table.insert(result.tabs, {
            id = tab.id,
            name = tab.name,
            active = tostring(tab.id) == tostring(state.tab_active),
        })
    end
    return result
end

---Return the name and active-flag for the currently active tab, or nil when
---no tab is active. Convenient one-liner for simple statusline components.
---@return { name: string, id: integer }|nil
function M.get_active_tab()
    local info = M.get_tab_info()
    for _, tab in ipairs(info.tabs) do
        if tab.active then
            return { name = tab.name, id = tab.id }
        end
    end
    return nil
end

---Return the name of the active workspace, or nil when none is active.
---@return string|nil
function M.get_workspace_name()
    return M.get_tab_info().workspace_name
end

---Return the name of the active project, or nil when none is active.
---@return string|nil
function M.get_project_name()
    return M.get_tab_info().project_name
end

---Switch to the tab with the given ID within the active workspace — the same
---operation the tab panel performs when a tab is selected (saves the current
---tab's window/buffer state, activates the target, restores its state, and
---persists the change). Intended for external integrations that render the
---lvim-space tabs and want them clickable (a tabline click). Safe to call at any
---time: returns false (no error) when no session/tab context exists yet or the
---switch fails, so consumers never have to guard the plugin's init order.
---@param tab_id integer The tab ID (as returned by |M.get_tab_info|'s `tabs[].id`).
---@return boolean success True when the switch completed successfully.
function M.switch_tab(tab_id)
    if not tab_id then
        return false
    end
    local ok_session, session = pcall(require, "lvim-space.core.session")
    if not (ok_session and session and session.switch_tab) then
        return false
    end
    local ok, result = pcall(session.switch_tab, tab_id)
    return ok and result == true
end

return M
