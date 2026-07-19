-- lvim-space.ui.workspaces: the workspaces panel for the active project — rendering, keymaps and CRUD for the
-- workspace list, workspace switching with session restore, and navigation to the sibling panels (projects /
-- tabs / files).
--
---@module "lvim-space.ui.workspaces"

local config = require("lvim-space.config")
local notify = require("lvim-space.api.notify")
local state = require("lvim-space.api.state")
local data = require("lvim-space.api.data")
local ui = require("lvim-space.ui")
local rows = require("lvim-space.ui.rows")
local utils = require("lvim-space.utils")
local common = require("lvim-space.ui.common")
local session = require("lvim-space.core.session")
local metrics = require("lvim-space.core.metrics")

local M = {}

---Safely decode a JSON string, returning `default` on malformed input or nil.
---@param str string|nil JSON string to decode
---@param default table Fallback value when decoding fails
---@return table
local function safe_json_decode(str, default)
    if not str then
        return default
    end
    local ok, result = pcall(vim.json.decode, str)
    return (ok and type(result) == "table") and result or default
end

--- Lazy-loads the files UI module to avoid circular require at startup.
---@return table files_ui The lvim-space.ui.files module
local function files_ui_module()
    return require("lvim-space.ui.files")
end

--- Lazy-loads the tabs UI module to avoid circular require at startup.
---@return table tabs_ui The lvim-space.ui.tabs module
local function tabs_ui_module()
    return require("lvim-space.ui.tabs")
end

---@class WorkspacesCache
---@field workspace_ids_map table<number, number> Map from visual line number to workspace DB id
---@field workspaces_from_db table[] Sorted list of workspace records fetched from the database
---@field ctx table|nil Active panel context returned by common.init_entity_list
---@field project_display_name string Display name of the currently active project
---@field last_cursor_position number Last known cursor row in the panel window
---@field cursor_scope any Project id the remembered cursor row belongs to (reset on scope change)

---@type WorkspacesCache
local cache = {
    workspace_ids_map = {},
    workspaces_from_db = {},
    ctx = nil,
    project_display_name = "",
    last_cursor_position = 1,
    cursor_scope = nil,
}

---@type number|nil Window handle of the last non-plugin editor window
local last_real_win = nil

local is_plugin_panel_win = ui.is_plugin_window

--- Returns the entity-type definition table for "workspace" from the common module.
---@return EntityTypeDef|nil entity_def Entity-type definition with error keys, icons, and labels
local function get_entity_def()
    return common.get_entity_type("workspace")
end

--- Returns the entity-type definition table for "project" from the common module.
---@return EntityTypeDef|nil entity_def Entity-type definition for projects
local function get_project_def()
    return common.get_entity_type("project")
end

--- Creates an empty workspace tabs structure with initialised timestamps.
---@return {tab_ids: table, tab_active: nil, created_at: number, updated_at: number} tabs_struct Default tabs object
local function create_empty_workspace_tabs()
    return { tab_ids = {}, tab_active = nil, created_at = os.time(), updated_at = os.time() }
end

--- Saves the current window as the last real (non-plugin) editor window.
local function save_window_context()
    local current_win = vim.api.nvim_get_current_win()
    if current_win and vim.api.nvim_win_is_valid(current_win) and not is_plugin_panel_win(current_win) then
        last_real_win = current_win
    end
end

--- Persists the current cursor row from the panel window into the cache.
local function save_cursor_position()
    if cache.ctx and cache.ctx.win and vim.api.nvim_win_is_valid(cache.ctx.win) then
        local cursor_pos = vim.api.nvim_win_get_cursor(cache.ctx.win)
        cache.last_cursor_position = cursor_pos[1]
    end
end

--- Registers a CursorMoved autocmd that keeps `cache.last_cursor_position` up to date.
---@param ctx table Panel context with `win` and `buf` fields
local function setup_cursor_tracking(ctx)
    if not ctx.win or not vim.api.nvim_win_is_valid(ctx.win) then
        return
    end

    vim.api.nvim_create_autocmd("CursorMoved", {
        buffer = ctx.buf,
        callback = function()
            if cache.ctx and cache.ctx.win and vim.api.nvim_win_is_valid(cache.ctx.win) then
                local cursor_pos = vim.api.nvim_win_get_cursor(cache.ctx.win)
                cache.last_cursor_position = cursor_pos[1]
            end
        end,
        group = vim.api.nvim_create_augroup("LvimSpaceWorkspacesCursor", { clear = true }),
    })
end

--- Re-renders the workspace list in the existing panel window without reopening it.
--- Falls back to `M.init` when the window or buffer is no longer valid.
M.refresh = function()
    if not cache.ctx or not cache.ctx.win or not vim.api.nvim_win_is_valid(cache.ctx.win) then
        return M.init()
    end

    if not cache.ctx.buf or not vim.api.nvim_buf_is_valid(cache.ctx.buf) then
        return M.init()
    end

    save_cursor_position()

    cache.workspaces_from_db = data.find_workspaces(state.project_id) or {}
    table.sort(cache.workspaces_from_db, function(a, b)
        local order_a = tonumber(a.sort_order) or math.huge
        local order_b = tonumber(b.sort_order) or math.huge
        if order_a == order_b then
            return (a.name or "") < (b.name or "")
        end
        return order_a < order_b
    end)
    cache.workspace_ids_map = {}

    -- Empty ↔ populated transition (either direction) needs the full re-init (footer buttons, `/` filter,
    -- empty-state row); the in-place path only handles a populated → populated refresh.
    if cache.ctx.is_empty ~= (#cache.workspaces_from_db == 0) then
        return M.init()
    end

    local function get_tab_count(workspace_entry)
        if not workspace_entry.tabs then
            return 0
        end
        local success, decoded_tabs = pcall(vim.json.decode, workspace_entry.tabs)
        if success and decoded_tabs and decoded_tabs.tab_ids then
            return #decoded_tabs.tab_ids
        end
        return 0
    end

    local new_lines, new_spans = {}, {}
    for i, workspace_entry in ipairs(cache.workspaces_from_db) do
        cache.workspace_ids_map[i] = workspace_entry.id
        local is_active = tostring(workspace_entry.id) == tostring(state.workspace_id)
        local tab_count = get_tab_count(workspace_entry)
        local tab_count_display = utils.string.to_superscript(tab_count)
        local display_text = (workspace_entry.name or "???") .. tab_count_display
        -- Through the ONE row renderer, like the first paint (`common.format_line`) — no second row format.
        new_lines[i], new_spans[i] = rows.line(display_text, "workspace", is_active, nil)
    end

    local success = pcall(function()
        local was_modifiable = vim.bo[cache.ctx.buf].modifiable
        if not was_modifiable then
            vim.bo[cache.ctx.buf].modifiable = true
        end

        vim.api.nvim_buf_set_lines(cache.ctx.buf, 0, -1, false, new_lines)

        if not was_modifiable then
            vim.bo[cache.ctx.buf].modifiable = false
        end
        -- Stripes / selection / icon colours are extmarks — `set_lines` wipes them, so every write repaints.
        ui.set_rows(cache.ctx.buf, new_spans)
    end)

    if not success then
        return M.init()
    end

    if #new_lines > 0 and cache.ctx.win and vim.api.nvim_win_is_valid(cache.ctx.win) then
        local max_line = #new_lines
        local target_line = math.min(cache.last_cursor_position, max_line)
        target_line = math.max(target_line, 1)
        pcall(vim.api.nvim_win_set_cursor, cache.ctx.win, { target_line, 0 })
    end

    local ws_def = get_entity_def()
    local base_ws_title = state.lang[(ws_def and ws_def.title) or "WORKSPACES"] or "Workspaces"
    local final_panel_title
    if
        cache.project_display_name
        and cache.project_display_name ~= "Unknown Project"
        and vim.trim(cache.project_display_name) ~= ""
    then
        final_panel_title = string.format("%s (%s)", base_ws_title, cache.project_display_name)
    else
        final_panel_title = base_ws_title
    end

    cache.ctx.is_empty = #new_lines == 0
    cache.ctx.entities = cache.workspaces_from_db
    cache.ctx.id_list_map = cache.workspace_ids_map

    ui.set_title(final_panel_title, #cache.workspaces_from_db)
end

--- Validates a workspace name for an add or rename operation.
--- Checks format/length via common validation and uniqueness within the project scope.
---@param workspace_name string The candidate workspace name to validate
---@param project_id_context number Project id used to scope uniqueness checks
---@param workspace_id_for_rename number|nil When renaming, the id of the workspace being renamed (allows keeping the same name)
---@return string|nil validated_name Trimmed valid name, or nil on failure
---@return string|nil err_code Error code such as "EXIST_NAME" or "LEN_NAME", or nil on success
local function validate_workspace_name_for_add_or_rename(workspace_name, project_id_context, workspace_id_for_rename)
    local ok, err_code = common.validate_entity_name("workspace", workspace_name)
    if not ok then
        return nil, err_code
    end
    local trimmed_name = vim.trim(workspace_name)
    local existing_workspace = data.is_workspace_name_exist(trimmed_name, project_id_context)
    if existing_workspace then
        if workspace_id_for_rename and tostring(existing_workspace.id) == tostring(workspace_id_for_rename) then
            return trimmed_name, nil
        else
            return nil, "EXIST_NAME"
        end
    end
    return trimmed_name, nil
end

--- Persists the current workspace activation and tab state to the database when
--- autosave is enabled. Marks the active workspace flag and encodes tab ids/active tab.
local function update_workspace_state_in_db()
    if not config.autosave or not state.project_id then
        return
    end
    if state.workspace_id then
        data.set_workspace_active(state.workspace_id, state.project_id)
        local ws = data.find_workspace_by_id(state.workspace_id, state.project_id)
        if ws then
            local tabs_json_obj = safe_json_decode(ws.tabs, create_empty_workspace_tabs())
            tabs_json_obj.tab_active = state.tab_active
            tabs_json_obj.tab_ids = state.tab_ids or {}
            tabs_json_obj.updated_at = os.time()
            data.update_workspace_tabs(vim.json.encode(tabs_json_obj), state.workspace_id)
        end
    else
        data.set_workspaces_inactive(state.project_id)
    end
end

--- Inserts a new workspace record into the database with an empty tabs JSON structure
--- and schedules a panel refresh on success.
---@param workspace_name string Display name for the new workspace
---@param project_id number Database id of the owning project
---@return number|string result New row id (number > 0) on success, or an error code string on failure
local function add_workspace_db(workspace_name, project_id)
    local ws_def = get_entity_def()
    local initial_tabs_structure = create_empty_workspace_tabs()
    local initial_tabs_json = vim.json.encode(initial_tabs_structure)
    local result = data.add_workspace(workspace_name, initial_tabs_json, project_id)
    if type(result) == "number" and result > 0 then
        vim.schedule(function()
            M.refresh()
        end)
        return result
    elseif type(result) == "string" then
        return result
    else
        return (ws_def and ws_def.add_failed) or "WORKSPACE_ADD_FAILED"
    end
end

--- Persists a new name for an existing workspace and schedules a panel re-init.
---@param workspace_id number Database id of the workspace to rename
---@param new_validated_name string Already-validated new name
---@param project_id number Database id of the owning project (passed through to the data layer)
---@param selected_line_num number|nil Visual line to restore cursor to after re-init
---@return boolean|string result true on success, false or an error code string on failure
local function rename_workspace_db(workspace_id, new_validated_name, project_id, selected_line_num)
    local status = data.update_workspace_name(workspace_id, new_validated_name, project_id)
    if status == true then
        if config.autosave then
            update_workspace_state_in_db()
        end
        vim.schedule(function()
            M.init(selected_line_num)
        end)
        return true
    elseif type(status) == "string" then
        return status
    end
    return false
end

--- Deletes a workspace from the database and resets active state if it was the current workspace.
---@param workspace_id number Database id of the workspace to delete
---@param project_id number Database id of the owning project
---@param selected_line_num number|nil Visual line to restore cursor to after re-init
---@return true|nil result true on success, nil on database failure
local function delete_workspace_db(workspace_id, project_id, selected_line_num)
    local status = data.delete_workspace(workspace_id, project_id)
    if not status then
        return nil
    end
    vim.schedule(function()
        local was_active_workspace = tostring(state.workspace_id) == tostring(workspace_id)
        if was_active_workspace then
            state.workspace_id = nil
            state.tab_ids = {}
            state.tab_active = nil
            state.file_active = nil
            session.clear_current_state()
        end
        if config.autosave then
            update_workspace_state_in_db()
        end
        M.init(selected_line_num)
    end)
    return true
end

--- Switches the active workspace in "space" mode: restores tab state, persists to DB,
--- and restores the last session. Refreshes the panel once the session autocmd fires
--- (or immediately if no active tab exists).
---@param workspace_id number Database id of the workspace to activate
---@param selected_line_in_ui number|nil Visual line in the workspaces panel to restore after reinit
local function space_load_session(workspace_id, selected_line_in_ui)
    if not cache.ctx or not cache.ctx.buf or not vim.api.nvim_buf_is_valid(cache.ctx.buf) then
        return
    end
    state.workspace_id = workspace_id
    local workspace = data.find_workspace_by_id(workspace_id, state.project_id)
    local workspace_tabs_obj = safe_json_decode(workspace and workspace.tabs, create_empty_workspace_tabs())

    state.tab_ids = workspace_tabs_obj.tab_ids or {}
    state.tab_active = workspace_tabs_obj.tab_active
    if config.autosave then
        update_workspace_state_in_db()
    end
    if not state.tab_active then
        local ws_def = get_entity_def()
        local switched_to_msg = (ws_def and ws_def.switched_to and state.lang[ws_def.switched_to])
            or "Switched to workspace: "
        local ws_name = workspace and workspace.name or "Unknown Workspace"
        notify.info(switched_to_msg .. ws_name)
        -- Empty target workspace (no active tab, nothing to restore): just refresh the marker in place — no
        -- surface rebuild, so the title/footer bar don't blink. Falls back to M.init if the panel is gone.
        M.refresh()
        return
    end
    local old_disable_auto_close = state.disable_auto_close
    state.disable_auto_close = true
    -- Drive the continuation off restore COMPLETION, not a one-shot BufEnter/WinEnter trap: that trap never
    -- fires when the restore produces no window event (same buffer / empty session), which left the panel to
    -- spontaneously reopen on a LATER unrelated event and `disable_auto_close` stuck true forever.
    -- Reopen the panel DIRECTLY in on_done (no inner `vim.schedule`): on_done fires inside restore_state's
    -- coalescing tick, so the restored layout and this reopened (dimmed) panel paint as ONE frame. An extra
    -- schedule pushed the reopen to a LATER tick — the restored bright editor painted first, then the panel
    -- popped back a frame later: the flicker on a workspace load.
    session.restore_state(state.tab_active, true, function()
        local ws_def = get_entity_def()
        local switched_to_msg = (ws_def and ws_def.switched_to and state.lang[ws_def.switched_to])
            or "Switched to workspace: "
        local ws_name_for_notify = (workspace and workspace.name) or "Selected Workspace"
        notify.info(switched_to_msg .. ws_name_for_notify)
        -- Refresh the SAME panel IN PLACE (only the active-workspace marker moves) rather than tearing the
        -- surface down and rebuilding it — recreating the float blinks the title and the footer button bar even
        -- when coalesced. M.refresh falls back to M.init if the panel window/buffer is gone.
        M.refresh()
        if state.ui and state.ui.content and vim.api.nvim_win_is_valid(state.ui.content.win) then
            local main_ui_win = state.ui.content.win
            vim.api.nvim_set_current_win(main_ui_win)
            if selected_line_in_ui then
                pcall(vim.api.nvim_win_set_cursor, main_ui_win, { selected_line_in_ui, 0 })
            end
        end
        state.disable_auto_close = old_disable_auto_close
    end)
end

--- Switches to a workspace in "enter" mode: closes all panels, restores session state,
--- increments the workspace-switch metric, and navigates to the files or tabs panel.
---@param workspace_id number Database id of the workspace to navigate into
local function enter_navigate_to_last_panel(workspace_id)
    state.workspace_id = workspace_id
    local workspace = data.find_workspace_by_id(workspace_id, state.project_id)
    local workspace_tabs_obj = safe_json_decode(workspace and workspace.tabs, create_empty_workspace_tabs())
    state.tab_ids = workspace_tabs_obj.tab_ids or {}
    state.tab_active = workspace_tabs_obj.tab_active
    if config.autosave then
        update_workspace_state_in_db()
    end
    ui.close_all()
    local ws_def = get_entity_def()
    local switched_to_msg = (ws_def and ws_def.switched_to and state.lang[ws_def.switched_to])
        or "Switched to workspace: "
    local ws_name_for_notify = (workspace and workspace.name) or "Selected Workspace"
    notify.info(switched_to_msg .. ws_name_for_notify)
    if metrics.stats then
        metrics.stats.session.workspace_switches = metrics.stats.session.workspace_switches + 1
    end
    if state.tab_active then
        session.restore_state(state.tab_active, true)
        vim.schedule(function()
            files_ui_module().init()
        end)
    else
        vim.schedule(function()
            tabs_ui_module().init()
        end)
    end
end

--- Moves the workspace under the cursor one position up or down in the sort order via the shared
--- in-place reorder helper: the held workspace is swapped with its visual neighbour, committed to the
--- DB synchronously, and re-rendered into the same panel buffer with the cursor following it — no
--- `M.init` rebuild, so a rapid `K`/`J` burst always carries the same workspace (see common.reorder_entity).
---@param ctx table Panel context with `win` field pointing to the workspaces window
---@param direction "up"|"down" Direction to move the workspace
local function handle_move_operation(ctx, direction)
    common.reorder_entity({
        ctx = ctx,
        type_name = "workspace",
        entities = cache.workspaces_from_db,
        id_map = cache.workspace_ids_map,
        direction = direction,
        active_id = state.workspace_id,
        persist = function(order_table)
            return data.reorder_workspaces(state.project_id, order_table)
        end,
        formatter = function(workspace_entry)
            local tabs_obj = safe_json_decode(workspace_entry.tabs, {})
            local tab_count = tabs_obj.tab_ids and #tabs_obj.tab_ids or 0
            return (workspace_entry.name or "???") .. utils.string.to_superscript(tab_count)
        end,
    })
end

--- Opens an input prompt to create a new workspace under the active project.
--- Validates the name and inserts the record, then refreshes the panel.
M.handle_workspace_add = function()
    local ws_def = get_entity_def()
    if not ws_def then
        notify.error("An unexpected error occurred while trying to add a workspace.")
        return
    end
    local default_name = "Workspace " .. tostring(#(data.find_workspaces(state.project_id) or {}) + 1)
    ui.create_input_field(state.lang.WORKSPACE_NAME or "Workspace Name:", default_name, function(input_workspace_name)
        if not input_workspace_name or vim.trim(input_workspace_name) == "" then
            notify.info(state.lang.OPERATION_CANCELLED or "Operation cancelled.")
            return
        end
        local trimmed_name = vim.trim(input_workspace_name)
        local validated_name, err_code = validate_workspace_name_for_add_or_rename(trimmed_name, state.project_id, nil)
        if not validated_name then
            local err_key_from_def
            if err_code == "LEN_NAME" then
                err_key_from_def = ws_def.name_len_error
            elseif err_code == "EXIST_NAME" then
                err_key_from_def = ws_def.name_exist_error
            else
                err_key_from_def = ws_def.add_failed
            end
            notify.error(state.lang[err_key_from_def] or ("Invalid workspace name: " .. (err_code or "unknown error")))
            return
        end
        local result_or_err_code = add_workspace_db(validated_name, state.project_id)
        if type(result_or_err_code) == "number" and result_or_err_code > 0 then
            notify.info(state.lang[ws_def.added_success] or "Workspace added successfully!")
        else
            local err_key_to_use = ws_def.add_failed
            if type(result_or_err_code) == "string" then
                if result_or_err_code == "EXIST_NAME" then
                    err_key_to_use = ws_def.name_exist_error
                elseif state.lang[result_or_err_code] then
                    err_key_to_use = result_or_err_code
                end
            end
            notify.error(state.lang[err_key_to_use] or "Failed to add workspace.")
        end
    end)
end

--- Opens a rename prompt for the workspace under the cursor in the panel.
---@param ctx table Panel context; used to read the current cursor line
M.handle_workspace_rename = function(ctx)
    local current_line_num = ctx
            and ctx.win
            and vim.api.nvim_win_is_valid(ctx.win)
            and vim.api.nvim_win_get_cursor(ctx.win)[1]
        or 1
    local workspace_id_to_rename = common.get_id_at_cursor(cache.workspace_ids_map)
    local current_name = ""
    if cache.workspaces_from_db then
        for _, ws_entry in ipairs(cache.workspaces_from_db) do
            if tostring(ws_entry.id) == tostring(workspace_id_to_rename) then
                current_name = ws_entry.name
                break
            end
        end
    end
    if not workspace_id_to_rename then
        return
    end
    common.rename_entity(
        "workspace",
        workspace_id_to_rename,
        current_name,
        state.project_id,
        function(id, new_name_from_input, project_id_context)
            local validated_name, err_code =
                validate_workspace_name_for_add_or_rename(new_name_from_input, project_id_context, id)
            if not validated_name then
                return err_code
            end
            return rename_workspace_db(id, validated_name, project_id_context, current_line_num)
        end
    )
end

--- Opens a confirmation/delete flow for the workspace under the cursor in the panel.
---@param ctx table Panel context; used to read the current cursor line
M.handle_workspace_delete = function(ctx)
    local current_line_num = ctx
            and ctx.win
            and vim.api.nvim_win_is_valid(ctx.win)
            and vim.api.nvim_win_get_cursor(ctx.win)[1]
        or 1
    local ws_id_to_delete = common.get_id_at_cursor(cache.workspace_ids_map)
    local entry_name = ""
    if cache.workspaces_from_db then
        for _, ws_entry in ipairs(cache.workspaces_from_db) do
            if tostring(ws_entry.id) == tostring(ws_id_to_delete) then
                entry_name = ws_entry.name
                break
            end
        end
    end
    if not ws_id_to_delete then
        return
    end
    common.delete_entity("workspace", ws_id_to_delete, entry_name, state.project_id, function(del_id, proj_id)
        return delete_workspace_db(del_id, proj_id, current_line_num)
    end)
end

--- Activates the workspace under the cursor according to the provided mode option.
--- `opts.space_mode` restores session inside the panel UI; `opts.enter_mode` closes panels
--- and navigates to the deepest available child panel. Default (no mode) selects the workspace
--- and opens the tabs panel.
---@param opts {space_mode: boolean|nil, enter_mode: boolean|nil, close_panel: boolean|nil, id: any}|nil Navigation mode flags
M.handle_workspace_go = function(opts)
    local ws_def = get_entity_def()
    local workspace_id_selected = opts and opts.id or common.get_id_at_cursor(cache.workspace_ids_map)
    if not workspace_id_selected then
        return
    end
    local selected_line_in_ui = cache.ctx
            and cache.ctx.win
            and vim.api.nvim_win_is_valid(cache.ctx.win)
            and vim.api.nvim_win_get_cursor(cache.ctx.win)[1]
        or nil
    if opts and opts.space_mode then
        space_load_session(workspace_id_selected, selected_line_in_ui)
        return
    end
    if opts and opts.enter_mode then
        enter_navigate_to_last_panel(workspace_id_selected)
        return
    end
    state.workspace_id = workspace_id_selected
    local workspace = data.find_workspace_by_id(state.workspace_id, state.project_id)
    local workspace_tabs_obj = safe_json_decode(workspace and workspace.tabs, create_empty_workspace_tabs())
    state.tab_ids = workspace_tabs_obj.tab_ids or {}
    state.tab_active = workspace_tabs_obj.tab_active
    if config.autosave then
        update_workspace_state_in_db()
    end
    local switched_to_msg = (ws_def and ws_def.switched_to and state.lang[ws_def.switched_to])
        or "Switched to workspace: "
    local ws_name_for_notify = (workspace and workspace.name) or "Selected Workspace"
    notify.info(switched_to_msg .. ws_name_for_notify)
    if opts and opts.close_panel then
        ui.close_all()
    end
    tabs_ui_module().init()
end

--- Moves the workspace under the cursor one position up in the sort order.
---@param ctx table Panel context with a valid `win` field
M.handle_move_up = function(ctx)
    handle_move_operation(ctx, "up")
end

--- Moves the workspace under the cursor one position down in the sort order.
---@param ctx table Panel context with a valid `win` field
M.handle_move_down = function(ctx)
    handle_move_operation(ctx, "down")
end

--- Closes the current panel and opens the projects panel.
M.navigate_to_projects = function()
    ui.close_all()
    require("lvim-space.ui.projects").init()
end

--- Closes the current panel and opens the tabs panel for the active workspace.
--- Shows an error state if no project, workspace, or active tab is set.
M.navigate_to_tabs = function()
    if not state.project_id then
        notify.info(state.lang.PROJECT_NOT_ACTIVE)
        local _err_buf = common.open_entity_error("tab", "PROJECT_NOT_ACTIVE")
        common.setup_error_navigation("PROJECT_NOT_ACTIVE", last_real_win, _err_buf)
        return
    end
    if not state.workspace_id then
        notify.info(state.lang.WORKSPACE_NOT_ACTIVE)
        local _err_buf = common.open_entity_error("tab", "WORKSPACE_NOT_ACTIVE")
        common.setup_error_navigation("WORKSPACE_NOT_ACTIVE", last_real_win, _err_buf)
        return
    end
    ui.close_all()
    tabs_ui_module().init()
end

--- Closes the current panel and opens the files panel for the active tab.
--- Shows an error state if no project, workspace, or active tab is set.
M.navigate_to_files = function()
    if not state.project_id then
        notify.info(state.lang.PROJECT_NOT_ACTIVE)
        local _err_buf = common.open_entity_error("file", "PROJECT_NOT_ACTIVE")
        common.setup_error_navigation("PROJECT_NOT_ACTIVE", last_real_win, _err_buf)
        return
    end
    if not state.workspace_id then
        notify.info(state.lang.WORKSPACE_NOT_ACTIVE)
        local _err_buf = common.open_entity_error("file", "WORKSPACE_NOT_ACTIVE")
        common.setup_error_navigation("WORKSPACE_NOT_ACTIVE", last_real_win, _err_buf)
        return
    end
    if not state.tab_active then
        notify.info(state.lang.TAB_NOT_ACTIVE)
        local _err_buf = common.open_entity_error("file", "TAB_NOT_ACTIVE")
        common.setup_error_navigation("TAB_NOT_ACTIVE", last_real_win, _err_buf)
        return
    end
    ui.close_all()
    files_ui_module().init()
end

--- Closes the current panel and opens the search panel for the active tab.
--- Shows an error state if no project, workspace, or active tab is set.
function M.navigate_to_search()
    if not state.project_id then
        notify.info(state.lang.PROJECT_NOT_ACTIVE)
        local _err_buf = common.open_entity_error("search", "PROJECT_NOT_ACTIVE")
        common.setup_error_navigation("PROJECT_NOT_ACTIVE", last_real_win, _err_buf)
        return
    end
    if not state.workspace_id then
        notify.info(state.lang.WORKSPACE_NOT_ACTIVE)
        local _err_buf = common.open_entity_error("search", "WORKSPACE_NOT_ACTIVE")
        common.setup_error_navigation("WORKSPACE_NOT_ACTIVE", last_real_win, _err_buf)
        return
    end
    if not state.tab_active then
        notify.info(state.lang.TAB_NOT_ACTIVE)
        local _err_buf = common.open_entity_error("search", "TAB_NOT_ACTIVE")
        common.setup_error_navigation("TAB_NOT_ACTIVE", last_real_win, _err_buf)
        return
    end
    -- Do NOT close here — search.init swaps this panel for the picker inside a single msgarea HANDOFF (one
    -- zone reflow, no flicker); closing first would collapse the zone before the picker reserves it.
    -- `on_back` re-opens THIS panel when the picker is dismissed (step back to where we came from).
    require("lvim-space.ui.search").init({ on_back = M.init })
end

--- Registers all buffer-local keymaps for the workspaces panel.
---@param ctx table Panel context containing `buf` and `entities` fields
local function setup_keymaps(ctx)
    local keymap_opts = { buffer = ctx.buf, noremap = true, silent = true, nowait = true }
    vim.keymap.set("n", config.keymappings.action.add, function()
        M.handle_workspace_add()
    end, keymap_opts)
    vim.keymap.set("n", config.keymappings.action.rename, function()
        if next(ctx.entities) ~= nil then
            M.handle_workspace_rename(ctx)
        end
    end, keymap_opts)
    vim.keymap.set("n", config.keymappings.action.delete, function()
        if next(ctx.entities) ~= nil then
            M.handle_workspace_delete(ctx)
        end
    end, keymap_opts)
    vim.keymap.set("n", config.keymappings.action.switch, function()
        if next(ctx.entities) ~= nil then
            M.handle_workspace_go({ space_mode = true })
        end
    end, keymap_opts)
    vim.keymap.set("n", config.keymappings.action.enter, function()
        if next(ctx.entities) ~= nil then
            M.handle_workspace_go({ enter_mode = true })
        end
    end, keymap_opts)
    vim.keymap.set("n", config.keymappings.action.move_up, function()
        if next(ctx.entities) ~= nil then
            M.handle_move_up(ctx)
        end
    end, keymap_opts)
    vim.keymap.set("n", config.keymappings.action.move_down, function()
        if next(ctx.entities) ~= nil then
            M.handle_move_down(ctx)
        end
    end, keymap_opts)
    vim.keymap.set("n", config.keymappings.global.projects, function()
        M.navigate_to_projects()
    end, keymap_opts)
    vim.keymap.set("n", config.keymappings.global.tabs, function()
        if next(ctx.entities) ~= nil then
            M.navigate_to_tabs()
        end
    end, keymap_opts)
    vim.keymap.set("n", config.keymappings.global.files, function()
        if next(ctx.entities) ~= nil then
            M.navigate_to_files()
        end
    end, keymap_opts)
    vim.keymap.set("n", config.keymappings.global.search, function()
        if next(ctx.entities) ~= nil then
            M.navigate_to_search()
        end
    end, keymap_opts)

    -- The navigable footer bar: each button reuses the same action functions the keymaps above fire.
    common.set_action_footer(ctx, {
        reorder = true,
        load = function()
            M.handle_workspace_go({ space_mode = true })
        end,
        enter = function()
            M.handle_workspace_go({ enter_mode = true })
        end,
        add = function()
            M.handle_workspace_add()
        end,
        rename = function()
            M.handle_workspace_rename(ctx)
        end,
        delete = function()
            M.handle_workspace_delete(ctx)
        end,
        panels = {
            {
                key = config.keymappings.global.projects,
                name = "projects",
                run = function()
                    M.navigate_to_projects()
                end,
            },
            {
                key = config.keymappings.global.tabs,
                name = "tabs",
                run = function()
                    M.navigate_to_tabs()
                end,
            },
            {
                key = config.keymappings.global.files,
                name = "files",
                run = function()
                    M.navigate_to_files()
                end,
            },
            {
                key = config.keymappings.global.search,
                name = "search",
                run = function()
                    M.navigate_to_search()
                end,
            },
        },
    })
end

--- Initialises (or re-initialises) the workspaces panel window for the active project.
--- Fetches and sorts workspaces, builds the panel via the common module, sets the panel
--- title (including the project name), and registers keymaps and cursor tracking.
---@param selected_line_num number|nil Visual line to place the cursor on after opening
---@param opts {select_workspace: boolean|nil}|nil Options table; set `select_workspace = false` to suppress active-workspace highlighting
M.init = function(selected_line_num, opts)
    save_window_context()

    local project_entity_def = get_project_def()
    if not state.project_id then
        notify.error(
            state.lang[(project_entity_def and project_entity_def.not_active) or "PROJECT_NOT_ACTIVE"]
                or "Project not active."
        )
        local _err_buf = common.open_entity_error(
            "workspace",
            (project_entity_def and project_entity_def.not_active) or "PROJECT_NOT_ACTIVE"
        )
        common.setup_error_navigation(
            (project_entity_def and project_entity_def.not_active) or "PROJECT_NOT_ACTIVE",
            last_real_win,
            _err_buf
        )
        return
    end

    cache.project_display_name = "Unknown Project"
    local proj_data_ok, project_obj = pcall(data.find_project_by_id, state.project_id)
    if proj_data_ok and project_obj and project_obj.name then
        cache.project_display_name = project_obj.name
    end

    opts = opts or {}
    local select_workspace_on_init = (opts.select_workspace ~= false)
    cache.workspaces_from_db = data.find_workspaces(state.project_id) or {}
    table.sort(cache.workspaces_from_db, function(a, b)
        local order_a = tonumber(a.sort_order) or math.huge
        local order_b = tonumber(b.sort_order) or math.huge
        if order_a == order_b then
            return (a.name or "") < (b.name or "")
        end
        return order_a < order_b
    end)
    cache.workspace_ids_map = {}

    local function get_tab_count(workspace_entry)
        if not workspace_entry.tabs then
            return 0
        end
        local success, decoded_tabs = pcall(vim.json.decode, workspace_entry.tabs)
        if success and decoded_tabs and decoded_tabs.tab_ids then
            return #decoded_tabs.tab_ids
        end
        return 0
    end

    -- The remembered cursor row belongs to the workspace list of a SPECIFIC project. When the project scope
    -- changes, forget it so a stale row from the previous project's list can't outrank the new project's
    -- active-workspace row.
    if cache.cursor_scope ~= state.project_id then
        cache.cursor_scope = state.project_id
        cache.last_cursor_position = 1
    end

    local active_id_for_list = select_workspace_on_init and state.workspace_id or nil
    local entity_selected_line = selected_line_num
    if not entity_selected_line and cache.last_cursor_position > 1 then
        entity_selected_line = cache.last_cursor_position
    end
    if not entity_selected_line and active_id_for_list then
        for idx, ws in ipairs(cache.workspaces_from_db) do
            if tostring(ws.id) == tostring(active_id_for_list) then
                entity_selected_line = idx
                break
            end
        end
    end

    local ctx_new = common.init_entity_list(
        "workspace",
        cache.workspaces_from_db,
        cache.workspace_ids_map,
        M.init,
        active_id_for_list,
        "id",
        entity_selected_line,
        function(workspace_entry)
            local tab_count = get_tab_count(workspace_entry)
            local tab_count_display = utils.string.to_superscript(tab_count)
            return (workspace_entry.name or "???") .. tab_count_display
        end,
        function(entity, active_id_in_list_param)
            if not select_workspace_on_init then
                return false
            end
            return active_id_in_list_param and tostring(entity.id) == tostring(active_id_in_list_param)
        end
    )
    if not ctx_new then
        return
    end
    cache.ctx = ctx_new

    if cache.ctx.win and vim.api.nvim_win_is_valid(cache.ctx.win) then
        local cursor_pos = vim.api.nvim_win_get_cursor(cache.ctx.win)
        cache.last_cursor_position = cursor_pos[1]

        local ws_def = get_entity_def()
        local base_ws_title = state.lang[(ws_def and ws_def.title) or "WORKSPACES"] or "Workspaces"
        local final_panel_title
        if
            cache.project_display_name
            and cache.project_display_name ~= "Unknown Project"
            and vim.trim(cache.project_display_name) ~= ""
        then
            final_panel_title = string.format("%s (%s)", base_ws_title, cache.project_display_name)
        else
            final_panel_title = base_ws_title
        end
        ui.set_title(final_panel_title, #cache.workspaces_from_db)
    end

    setup_keymaps(cache.ctx)
    setup_cursor_tracking(cache.ctx)
end

--- Finds a workspace by its display name within a project and activates it.
--- Updates `cache.workspace_ids_map` for panel consistency when possible;
--- falls back to a direct state mutation and session restore when the panel cache is stale.
---@param workspace_name string Exact display name of the workspace to switch to
---@param project_id_context number|nil Project scope to search in; defaults to the currently active project
---@return boolean success true if a matching workspace was found and activated, false otherwise
M.switch_to_workspace_by_name = function(workspace_name, project_id_context)
    local target_project_id = project_id_context or state.project_id
    if not target_project_id then
        return false
    end
    local workspaces_in_project = data.find_workspaces(target_project_id) or {}
    local found_workspace = nil
    for _, ws in ipairs(workspaces_in_project) do
        if ws.name == workspace_name then
            found_workspace = ws
            break
        end
    end
    local ws_def = get_entity_def()
    if found_workspace then
        if not cache.ctx or not cache.ctx.is_empty then
            M.init(nil, { select_workspace = false })
        end
        if found_workspace.id then
            M.handle_workspace_go({ space_mode = true, close_panel = false, id = found_workspace.id })
            return true
        else
            state.workspace_id = found_workspace.id
            local workspace_tabs_obj = safe_json_decode(found_workspace.tabs, create_empty_workspace_tabs())
            state.tab_ids = workspace_tabs_obj.tab_ids or {}
            state.tab_active = workspace_tabs_obj.tab_active
            if config.autosave then
                update_workspace_state_in_db()
            end
            ui.close_all()
            if state.tab_active then
                session.restore_state(state.tab_active, true)
                files_ui_module().init()
            else
                tabs_ui_module().init()
            end
            return true
        end
    else
        notify.error(state.lang[(ws_def and ws_def.not_found) or "WORKSPACE_NOT_FOUND"] or "Workspace not found.")
    end
    return false
end

return M
