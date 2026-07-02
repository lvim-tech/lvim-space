-- lvim-space.ui.common: shared UI helpers for every entity panel — the entity-type definitions, list
-- rendering, icon caching and error-navigation flows. Factored out so projects / workspaces / tabs / files
-- render their lists and badges identically instead of each panel re-implementing the layout.
--
---@module "lvim-space.ui.common"

local config = require("lvim-space.config")
local notify = require("lvim-space.api.notify")
local state = require("lvim-space.api.state")
local ui = require("lvim-space.ui")
local picker = require("lvim-utils.picker")

local M = {}

---@class EntityTypeDef
---@field name string  Singular entity identifier used in key lookups (e.g. "project")
---@field table string  Database table name
---@field state_id string|nil  Key in the global state table that holds the active ID
---@field empty_message string  Lang key shown when the list is empty
---@field info_empty string  Lang key for the actions bar when the list is empty
---@field info string  Lang key for the actions bar when the list is populated
---@field title string  Lang key for the panel title
---@field min_name_len number  Minimum accepted name length
---@field name_len_error string  Lang key for the name-too-short error
---@field name_exist_error string  Lang key for the name-already-exists error
---@field add_failed string  Lang key for an insert failure
---@field added_success string  Lang key shown after a successful insert
---@field rename_prompt string|nil  Lang key for the rename input prompt (pre-filled with the current name)
---@field rename_failed string|nil  Lang key for a rename failure
---@field renamed_success string|nil  Lang key shown after a successful rename
---@field delete_confirm string|nil  Lang key for the deletion confirmation prompt
---@field delete_failed string|nil  Lang key for a deletion failure
---@field deleted_success string|nil  Lang key shown after a successful deletion
---@field not_active string|nil  Lang key shown when no entity of this type is active
---@field error_message string  Generic error lang key for this entity type
---@field switched_to string  Lang key shown after switching to this entity
---@field switch_failed string  Lang key for a switch failure
---@field id_field string|nil  Field name used as the record identifier (defaults to "id" at runtime)
---@field ui_cache_error string|nil  Lang key for a UI cache inconsistency error (reorder flows)
---@field reorder_failed_error string|nil  Lang key for a generic reorder failure
---@field reorder_missing_params_error string|nil  Lang key when reorder params are missing
---@field already_at_top string|nil  Lang key shown when the entity is already first in the list
---@field already_at_bottom string|nil  Lang key shown when the entity is already last in the list
---@field not_found string|nil  Lang key for an entity-not-found error

---Registry of all supported entity types and their associated UI/lang keys.
---@type table<string, EntityTypeDef>
M.entity_types = {
    project = {
        name = "project",
        table = "projects",
        state_id = "project_id",
        empty_message = "PROJECTS_EMPTY",
        info_empty = "INFO_LINE_PROJECTS_EMPTY",
        info = "INFO_LINE_PROJECTS",
        title = "PROJECTS",
        min_name_len = 3,
        name_len_error = "PROJECT_NAME_LEN",
        name_exist_error = "PROJECT_NAME_EXIST",
        add_failed = "PROJECT_ADD_FAILED",
        added_success = "PROJECT_ADDED_SUCCESS",
        rename_prompt = "PROJECT_NEW_NAME",
        rename_failed = "PROJECT_RENAME_FAILED",
        renamed_success = "PROJECT_RENAMED_SUCCESS",
        delete_confirm = "PROJECT_DELETE",
        delete_failed = "PROJECT_DELETE_FAILED",
        deleted_success = "PROJECT_DELETED_SUCCESS",
        not_active = "PROJECT_NOT_ACTIVE",
        error_message = "PROJECT_ERROR",
        switched_to = "PROJECT_SWITCHED_TO",
        switch_failed = "PROJECT_SWITCH_FAILED",
        reorder_invalid_order_error = "PROJECT_INVALID_NEW_ORDER",
        reorder_failed_error = "PROJECT_REORDER_FAILED",
        reorder_missing_params_error = "PROJECT_REORDER_MISSING_PARAMS",
        ui_cache_error = "PROJECT_UI_CACHE_ERROR",
        already_at_top = "PROJECT_ALREADY_AT_TOP",
        already_at_bottom = "PROJECT_ALREADY_AT_BOTTOM",
    },
    workspace = {
        name = "workspace",
        table = "workspaces",
        state_id = "workspace_id",
        empty_message = "WORKSPACES_EMPTY",
        info_empty = "INFO_LINE_WORKSPACES_EMPTY",
        info = "INFO_LINE_WORKSPACES",
        title = "WORKSPACES",
        min_name_len = 3,
        name_len_error = "WORKSPACE_NAME_LEN",
        name_exist_error = "WORKSPACE_NAME_EXIST",
        add_failed = "WORKSPACE_ADD_FAILED",
        added_success = "WORKSPACE_ADDED_SUCCESS",
        rename_prompt = "WORKSPACE_NEW_NAME",
        rename_failed = "WORKSPACE_RENAME_FAILED",
        renamed_success = "WORKSPACE_RENAMED_SUCCESS",
        delete_confirm = "WORKSPACE_DELETE",
        delete_failed = "WORKSPACE_DELETE_FAILED",
        deleted_success = "WORKSPACE_DELETED_SUCCESS",
        not_active = "WORKSPACE_NOT_ACTIVE",
        error_message = "WORKSPACE_ERROR",
        switched_to = "WORKSPACE_SWITCHED_TO",
        switch_failed = "WORKSPACE_SWITCH_FAILED",
        reorder_invalid_order_error = "WORKSPACE_INVALID_NEW_ORDER",
        reorder_failed_error = "WORKSPACE_REORDER_FAILED",
        reorder_missing_params_error = "WORKSPACE_REORDER_MISSING_PARAMS",
        ui_cache_error = "WORKSPACE_UI_CACHE_ERROR",
        already_at_top = "WORKSPACE_ALREADY_AT_TOP",
        already_at_bottom = "WORKSPACE_ALREADY_AT_BOTTOM",
    },
    tab = {
        name = "tab",
        table = "tabs",
        state_id = "tab_active",
        empty_message = "TABS_EMPTY",
        info_empty = "INFO_LINE_TABS_EMPTY",
        info = "INFO_LINE_TABS",
        title = "TABS",
        min_name_len = 1,
        name_len_error = "TAB_NAME_LEN",
        name_exist_error = "TAB_NAME_EXIST",
        add_failed = "TAB_ADD_FAILED",
        added_success = "TAB_ADDED_SUCCESS",
        rename_prompt = "TAB_NEW_NAME",
        rename_failed = "TAB_RENAME_FAILED",
        renamed_success = "TAB_RENAMED_SUCCESS",
        delete_confirm = "TAB_DELETE",
        delete_failed = "TAB_DELETE_FAILED",
        deleted_success = "TAB_DELETED_SUCCESS",
        not_active = "TAB_NOT_ACTIVE",
        error_message = "TAB_ERROR",
        switched_to = "TAB_SWITCHED_TO",
        switch_failed = "TAB_SWITCH_FAILED",
        reorder_invalid_order_error = "TAB_INVALID_NEW_ORDER",
        reorder_failed_error = "TAB_REORDER_FAILED",
        reorder_missing_params_error = "TAB_REORDER_MISSING_PARAMS",
        ui_cache_error = "TAB_UI_CACHE_ERROR",
        already_at_top = "TAB_ALREADY_AT_TOP",
        already_at_bottom = "TAB_ALREADY_AT_BOTTOM",
    },
    file = {
        name = "file",
        table = "files",
        state_id = "file_active",
        empty_message = "FILES_EMPTY",
        info_empty = "INFO_LINE_FILES_EMPTY",
        info = "INFO_LINE_FILES",
        title = "FILES",
        min_name_len = 1,
        name_len_error = "FILE_NAME_LEN",
        name_exist_error = "FILE_NAME_EXIST",
        add_failed = "FILE_ADD_FAILED",
        added_success = "FILE_ADDED_SUCCESS",
        rename_prompt = "FILES_NEW_NAME",
        rename_failed = "FILE_RENAME_FAILED",
        renamed_success = "FILE_RENAMED_SUCCESS",
        delete_confirm = "FILE_DELETE",
        delete_failed = "FILE_DELETE_FAILED",
        deleted_success = "FILE_DELETED_SUCCESS",
        not_active = "FILE_NOT_ACTIVE",
        error_message = "FILE_ERROR",
        switched_to = "FILE_SWITCHED_TO",
        switch_failed = "FILE_SWITCH_FAILED",
    },
    search = {
        name = "search",
        table = "search_results",
        state_id = nil,
        empty_message = "SEARCH_EMPTY",
        info_empty = "INFO_LINE_SEARCH_EMPTY",
        info = "INFO_LINE_SEARCH",
        title = "SEARCH",
        min_name_len = 0,
        name_len_error = "SEARCH_QUERY_LEN",
        name_exist_error = "SEARCH_QUERY_EXIST",
        add_failed = "SEARCH_FAILED",
        added_success = "SEARCH_SUCCESS",
        error_message = "SEARCH_ERROR",
        switched_to = "SEARCH_FILE_OPENED",
        switch_failed = "SEARCH_FILE_OPEN_FAILED",
    },
}

---@type table<string, string>
local icon_cache = {}

---Return the icon string for an entity type, consulting a module-level cache to avoid
---repeated config lookups for the same combination of arguments.
---@param type_name string  Entity type name (e.g. "project", "workspace", "tab", "file")
---@param active boolean  Whether the item is currently active
---@param empty boolean  Whether the list slot represents an "empty" placeholder
---@return string  Icon string (may include trailing space as part of the glyph)
M.get_entity_icon = function(type_name, active, empty)
    local key = type_name .. "_" .. tostring(active) .. "_" .. tostring(empty)
    if icon_cache[key] then
        return icon_cache[key]
    end

    local icons_config = config.ui.icons or {}
    local icon

    if empty then
        icon = icons_config.empty or "󰇘 "
    else
        if active then
            icon = icons_config[type_name .. "_active"] or icons_config[type_name] or icons_config.default_active or " "
        else
            icon = icons_config[type_name] or icons_config.default_inactive or " "
        end
    end

    icon_cache[key] = icon
    return icon
end

---Determine whether a given entity record should be considered active.
---Delegates to `custom_active_check` when provided; otherwise uses the workspace `active`
---flag or compares the entity's ID field against `active_id`.
---@param type_def EntityTypeDef  Entity type definition that describes this entity
---@param ent table  The entity record to evaluate
---@param active_id any  The ID of the currently active entity (may be nil)
---@param custom_active_check (fun(ent: table, active_id: any): boolean)|nil  Optional override predicate
---@return boolean  True when the entity should be rendered as active
local function determine_active(type_def, ent, active_id, custom_active_check)
    if custom_active_check then
        return custom_active_check(ent, active_id)
    end
    if type_def.name == "workspace" and ent.active ~= nil then
        return ent.active == true or ent.active == 1 or tostring(ent.active) == "true"
    end
    local id_field_to_check = type_def.id_field or "id"
    if ent[id_field_to_check] and active_id then
        return tostring(ent[id_field_to_check]) == tostring(active_id)
    end
    return false
end

---Build the display string for one entity list row, stripping any pre-existing leading
---icon/prefix characters before prepending the canonical icon for the current state.
---@param ent table  The entity record to format
---@param type_name string  Entity type name passed to `get_entity_icon`
---@param active boolean  Whether this entity is currently active
---@param custom_formatter (fun(ent: table): string)|nil  Optional override for the text portion
---@return string  Fully formatted display line (icon + trimmed text)
local function format_line(ent, type_name, active, custom_formatter)
    local display_text
    if custom_formatter then
        display_text = custom_formatter(ent)
    else
        display_text = ent.name or ent.path or "???"
    end
    display_text = display_text:gsub("^[>%s▶󰋜󰉋󰏘󰉌󰓩󰎃󰈙󰈚]*", "")
    display_text = vim.trim(display_text)
    -- 1 space of breathing room at BOTH ends of every list row: a leading space BEFORE the icon (the icon glyph
    -- would otherwise hug column 0) and a trailing space after the text.
    return " " .. M.get_entity_icon(type_name, active, false) .. display_text .. " "
end

---Safely read the cursor position of a window, returning (1, 0) when the window is
---invalid or the API call fails.
---@param win integer|nil  Window handle to query
---@return integer row  1-based cursor row
---@return integer col  0-based cursor column
local function safe_get_cursor(win)
    if not win or not vim.api.nvim_win_is_valid(win) then
        return 1, 0
    end
    local ok, cur = pcall(vim.api.nvim_win_get_cursor, win)
    return ok and cur[1] or 1, ok and cur[2] or 0
end

---Prepend the configured empty/error icon to a message string.
---@param message string  Human-readable error description to decorate
---@return string  Icon-prefixed error message
local function format_error_message(message)
    local error_icon = (config.ui and config.ui.icons and config.ui.icons.empty) or "󰇘 "
    return error_icon .. message
end

---Return the entity ID mapped to the current cursor line in the content window.
---@param id_list_map table<integer, any>  Map of 1-based line numbers to entity IDs
---@return any|nil  Entity ID at the cursor line, or nil if the map is invalid
M.get_id_at_cursor = function(id_list_map)
    if type(id_list_map) ~= "table" then
        return nil
    end
    local current_win = state.ui and state.ui.content and state.ui.content.win or 0
    local line_num, _ = safe_get_cursor(current_win)
    return id_list_map[line_num]
end

---@class EntityListState
---@field buf integer  Buffer handle for the entity list
---@field win integer  Window handle for the entity list
---@field is_empty boolean  True when no entities were provided
---@field entities table[]  The original entities array
---@field id_list_map table<integer, any>  Maps 1-based line numbers to entity IDs
---@field entity_type_def EntityTypeDef  The resolved entity type definition
---@field refresh_function function|nil  Callback to re-render the list

---Render an entity list into the main UI panel. Builds display lines (with icons), populates
---`id_to_line_map`, positions the cursor, and opens the actions bar with the appropriate info line.
---@param type_name string  Entity type key (must exist in `M.entity_types`)
---@param entities_list table[]|nil  Ordered list of entity records to display
---@param id_to_line_map table<integer, any>  Mutable map that will be populated (line → entity ID)
---@param refresh_fn function|nil  Callback stored in the returned state for external callers
---@param active_entity_id any  ID of the entity that should appear highlighted/active
---@param id_field_name string|nil  Field name on each record used as the ID key (defaults to "id")
---@param preferred_selected_line integer|nil  Line number to position the cursor on (overrides active-item logic)
---@param line_formatter_fn (fun(ent: table): string)|nil  Optional custom text formatter for each row
---@param custom_active_check_fn (fun(ent: table, active_id: any): boolean)|nil  Optional active-state predicate
---@return EntityListState|nil  Populated state table, or nil if the entity type is unknown or the UI fails
M.init_entity_list = function(
    type_name,
    entities_list,
    id_to_line_map,
    refresh_fn,
    active_entity_id,
    id_field_name,
    preferred_selected_line,
    line_formatter_fn,
    custom_active_check_fn
)
    local entity_def = M.entity_types[type_name]
    if not entity_def then
        notify.error(state.lang.UNKNOWN_ENTITY_TYPE or "Unknown entity type.")
        return nil
    end

    entities_list = entities_list or {}
    id_to_line_map = id_to_line_map or {}

    local is_list_empty = #entities_list == 0
    local display_lines = {}
    local actual_cursor_line = 1
    local active_item_found = false
    local active_item_line = nil

    entity_def.id_field = id_field_name or "id"

    for _, entity_data in ipairs(entities_list) do
        local is_active = determine_active(entity_def, entity_data, active_entity_id, custom_active_check_fn)
        local formatted_line = format_line(entity_data, entity_def.name, is_active, line_formatter_fn)
        if formatted_line then
            table.insert(display_lines, formatted_line)
            id_to_line_map[#display_lines] = entity_data[entity_def.id_field]
            if is_active then
                active_item_line = #display_lines
                active_item_found = true
            end
        end
    end

    if is_list_empty then
        table.insert(
            display_lines,
            M.get_entity_icon(entity_def.name, false, true)
                .. (state.lang[entity_def.empty_message] or "List is empty.")
        )
    elseif not active_item_found and entity_def.state_id then
        state[entity_def.state_id] = nil
    end

    if preferred_selected_line and preferred_selected_line >= 1 and preferred_selected_line <= #display_lines then
        actual_cursor_line = preferred_selected_line
    elseif active_item_line then
        actual_cursor_line = active_item_line
    elseif not is_list_empty then
        actual_cursor_line = 1
    end

    actual_cursor_line = math.max(1, math.min(actual_cursor_line, #display_lines))

    -- The header counter shows the REAL entity total (0 on the empty-state placeholder row), not #display_lines.
    local buf_handle, win_handle =
        ui.open_main(display_lines, state.lang[entity_def.title] or entity_def.name, actual_cursor_line, #entities_list)
    if not buf_handle or not win_handle then
        notify.error(state.lang.FAILED_TO_CREATE_UI or "Failed to create UI.")
        return nil
    end

    vim.wo[win_handle].signcolumn = "no"
    vim.bo[buf_handle].modifiable = false
    vim.bo[buf_handle].buftype = "nofile"

    -- The footer is the NAVIGABLE action bar now (built per panel by `M.set_action_footer` right after this
    -- returns, in each panel's `setup_keymaps`) — not a plain hint string here. The old `entity_def.info` /
    -- `info_empty` lang lines are kept only for reference / error guidance.

    -- Embedded filter: `/` opens the shared lvim-utils picker over the CURRENT list (same dock zone as the
    -- panel), so every entity panel gains fuzzy filtering. Confirming a row jumps the panel cursor to that
    -- entity and fires the panel's own switch action (whatever each panel bound to `action.switch`) — so the
    -- filter REUSES the existing select flow rather than reimplementing it. `/` is free across the panels
    -- (not a navigation/action key, not in key_control). No-op for an empty list.
    if not is_list_empty then
        local switch_key = (config.keymappings.action and config.keymappings.action.switch) or "<Space>"
        vim.keymap.set("n", "/", function()
            local items = {}
            for _, ent in ipairs(entities_list) do
                local text = (line_formatter_fn and line_formatter_fn(ent)) or ent.name or ent.path or "???"
                local item = { text = text, _id = ent[entity_def.id_field] }
                if entity_def.name == "file" then
                    item.path = ent.path or ent.filePath or ent.id
                end
                items[#items + 1] = item
            end
            picker.open({
                title = "Filter " .. (state.lang[entity_def.title] or entity_def.name),
                layout = config.ui.mode,
                items = items,
                on_confirm = function(it)
                    if not it or it._id == nil then
                        return
                    end
                    local target_line
                    for line_no, id in pairs(id_to_line_map) do
                        if tostring(id) == tostring(it._id) then
                            target_line = line_no
                            break
                        end
                    end
                    local win = state.ui and state.ui.content and state.ui.content.win
                    if win and vim.api.nvim_win_is_valid(win) then
                        vim.api.nvim_set_current_win(win)
                        if target_line then
                            pcall(vim.api.nvim_win_set_cursor, win, { target_line, 0 })
                        end
                        vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(switch_key, true, false, true), "m", false)
                    end
                end,
            })
        end, { buffer = buf_handle, noremap = true, silent = true, nowait = true })
    end

    return {
        buf = buf_handle,
        win = win_handle,
        is_empty = is_list_empty,
        entities = entities_list,
        id_list_map = id_to_line_map,
        entity_type_def = entity_def,
        refresh_function = refresh_fn,
    }
end

---Re-render an entity list into its EXISTING panel buffer (no window teardown): rebuild every display
---line from `entities` and refill `id_map` (line → id) IN PLACE, toggling `modifiable` around the write.
---This is the rendering half of the in-place reorder — it keeps the same buffer/window the panel keymaps
---are bound to, so a rapid `K`/`J` burst never crosses a window rebuild.
---@param buf integer  Target list buffer handle
---@param entities table[]  Ordered entity records (already in their new order)
---@param id_map table<integer, any>  Line → id map; cleared and refilled in place (same table reference)
---@param type_def EntityTypeDef  Resolved entity type definition (provides `name` / `id_field`)
---@param active_id any  ID of the entity that should render with its active icon
---@param formatter (fun(ent: table): string)|nil  Optional custom text formatter (matches the panel's own)
---@param active_check (fun(ent: table, active_id: any): boolean)|nil  Optional active-state predicate
---@return boolean ok  True when the buffer lines were written successfully
local function render_entity_buffer(buf, entities, id_map, type_def, active_id, formatter, active_check)
    if not buf or not vim.api.nvim_buf_is_valid(buf) then
        return false
    end
    for line_no in pairs(id_map) do
        id_map[line_no] = nil
    end
    local id_field = type_def.id_field or "id"
    local lines = {}
    for index, ent in ipairs(entities) do
        local is_active = determine_active(type_def, ent, active_id, active_check)
        lines[index] = format_line(ent, type_def.name, is_active, formatter)
        id_map[index] = ent[id_field]
    end
    local was_modifiable = vim.bo[buf].modifiable
    if not was_modifiable then
        vim.bo[buf].modifiable = true
    end
    local ok = pcall(vim.api.nvim_buf_set_lines, buf, 0, -1, false, lines)
    if not was_modifiable then
        vim.bo[buf].modifiable = false
    end
    return ok
end

---@class ReorderEntityOpts
---@field ctx EntityListState  The LIVE panel context (its `buf`/`win` stay in place across the move)
---@field type_name string  Entity type key (must exist in `M.entity_types`)
---@field entities table[]  The panel's sorted in-memory list; the two swapped rows are reordered in place
---@field id_map table<integer, any>  The panel's line → id map; rebuilt in place to match the new order
---@field direction "up"|"down"  Move the held entity one row up or down
---@field active_id any  ID of the active entity (kept highlighted across the move)
---@field persist fun(order: OrderItem[]): boolean, string|nil  Synchronous DB reorder call (`data.reorder_*`)
---@field formatter (fun(ent: table): string)|nil  Optional custom row formatter (the panel's own)
---@field active_check (fun(ent: table, active_id: any): boolean)|nil  Optional active-state predicate

---Move the entity under the cursor one position up/down, RACE-FREE: the held entity is identified by the
---cursor line, its `sort_order` is swapped with the visual neighbour and committed synchronously to the DB,
---then the same swap is reflected in the in-memory list + id-map and the list is re-rendered into the SAME
---buffer with the cursor placed on the moved entity's NEW line — all synchronously, with no `M.init`
---rebuild and no deferred cursor set. Because the panel buffer/window and the cache the next keypress reads
---are never torn down between keystrokes, a rapid `K`/`J` burst always carries the SAME entity. Bounds
---(top/bottom) no-op with the entity type's "already at top/bottom" notice, leaving the cache untouched.
---@param opts ReorderEntityOpts  Per-panel reorder description
M.reorder_entity = function(opts)
    local ctx = opts.ctx
    if not ctx or not ctx.win or not vim.api.nvim_win_is_valid(ctx.win) then
        return
    end
    local type_def = M.entity_types[opts.type_name]
    if not type_def then
        notify.error(state.lang.UNKNOWN_ENTITY_TYPE or "Unknown entity type.")
        return
    end
    local entities = opts.entities or {}
    local count = #entities
    if count == 0 then
        return
    end
    local line = vim.api.nvim_win_get_cursor(ctx.win)[1]
    if line < 1 or line > count then
        return
    end
    if opts.direction == "up" and line <= 1 then
        notify.info(state.lang[type_def.already_at_top] or "Already at the top.")
        return
    elseif opts.direction == "down" and line >= count then
        notify.info(state.lang[type_def.already_at_bottom] or "Already at the bottom.")
        return
    end
    local target = opts.direction == "up" and (line - 1) or (line + 1)
    local moved, neighbour = entities[line], entities[target]
    local moved_order = tonumber(moved.sort_order)
    local neighbour_order = tonumber(neighbour.sort_order)
    if not moved_order or not neighbour_order then
        notify.error(state.lang[type_def.reorder_failed_error] or "Failed to reorder.")
        return
    end
    -- Swap the two adjacent rows' sort_order values and commit synchronously BEFORE the cache/cursor reflect
    -- it, so a re-read mid-burst is never needed (the persisted order already matches the in-memory swap).
    local ok, err_code = opts.persist({
        { id = moved.id, order = neighbour_order },
        { id = neighbour.id, order = moved_order },
    })
    if not ok then
        local err_key = type_def.reorder_failed_error
        if err_code == type_def.reorder_missing_params_error then
            err_key = type_def.reorder_missing_params_error
        end
        notify.error(state.lang[err_key] or "Failed to reorder.")
        return
    end
    moved.sort_order, neighbour.sort_order = neighbour_order, moved_order
    entities[line], entities[target] = neighbour, moved
    render_entity_buffer(ctx.buf, entities, opts.id_map, type_def, opts.active_id, opts.formatter, opts.active_check)
    pcall(vim.api.nvim_win_set_cursor, ctx.win, { target, 0 })
end

---Humanise a raw keymap LHS into a compact footer key badge: the Space / Enter actions become their Nerd
---glyphs (matching the look of the legacy hint line); a chord like `<C-v>` drops its angle brackets; a plain
---letter passes through unchanged.
---@param key string|nil  Raw keymap LHS (e.g. "<Space>", "<CR>", "a", "<C-v>")
---@return string badge  The display string shown in the footer key box
local function key_badge(key)
    if not key or key == "" then
        return ""
    end
    if key == "<Space>" then
        return "󱁐"
    elseif key == "<CR>" then
        return "󰌑"
    end
    return (key:gsub("^<(.+)>$", "%1"))
end

---Build and apply the panel's NAVIGABLE footer bar (replacing the old plain hint string). The buttons are
---grouped by the red-dot (`●`) separator — `move ● load/enter ● add[/rename]/delete[/splits] ● panels` — and
---fed to the surface footer via `ui.open_actions({ groups = … })`, which renders them as a centred
---`lvim-utils.ui.bar` with `❮`/`❯` overflow chevrons (modelled on the lvim-utils `ui.tabs` footer).
---
---Each button's `run` REUSES the panel's own action function, so a focused footer button does exactly what
---its hotkey does. Selection-dependent actions (move / load / enter / rename / delete / splits) are omitted on
---an empty list, mirroring the per-panel keymap guards; `add` and the panel-nav buttons always show.
---@param ctx EntityListState  The open list context (`is_empty` decides which buttons appear)
---@param handlers table  `{ load, enter, add, rename, delete, split_v, split_h, reorder, panels }`; any nil entry is skipped, `panels` is a ready list of `{ key, name, run }`
M.set_action_footer = function(ctx, handlers)
    handlers = handlers or {}
    local akeys = (config.keymappings and config.keymappings.action) or {}
    local has_items = ctx and not ctx.is_empty
    local groups = {}

    -- Cursor + reorder are DISPLAY chips (`no_hotkey` so they are never mapped — a multi-char "j/k" label
    -- would otherwise become a `j` mapping prefix). `j`/`k` already move the list cursor; on panels that
    -- support reordering, `K`/`J` (config `move_up`/`move_down`) move the selected entity — the chip mirrors
    -- the live config keys so the legend stays accurate if the user rebinds them.
    if has_items then
        local nav = { { key = "j/k", name = "move", no_hotkey = true } }
        if handlers.reorder then
            local reorder_label = key_badge(akeys.move_up) .. "/" .. key_badge(akeys.move_down)
            nav[#nav + 1] = { key = reorder_label, name = "reorder", no_hotkey = true }
        end
        groups[#groups + 1] = nav
    end

    local activate = {}
    if has_items and handlers.load then
        activate[#activate + 1] = { key = key_badge(akeys.switch), name = "load", run = handlers.load }
    end
    if has_items and handlers.enter then
        activate[#activate + 1] = { key = key_badge(akeys.enter), name = "enter", run = handlers.enter }
    end
    groups[#groups + 1] = activate

    local crud = {}
    if handlers.add then
        crud[#crud + 1] = { key = key_badge(akeys.add), name = "add", run = handlers.add }
    end
    if has_items and handlers.rename then
        crud[#crud + 1] = { key = key_badge(akeys.rename), name = "rename", run = handlers.rename }
    end
    if has_items and handlers.delete then
        crud[#crud + 1] = { key = key_badge(akeys.delete), name = "delete", run = handlers.delete }
    end
    groups[#groups + 1] = crud

    local splits = {}
    if has_items and handlers.split_v then
        splits[#splits + 1] = { key = key_badge(akeys.split_v), name = "vsplit", run = handlers.split_v }
    end
    if has_items and handlers.split_h then
        splits[#splits + 1] = { key = key_badge(akeys.split_h), name = "hsplit", run = handlers.split_h }
    end
    groups[#groups + 1] = splits

    if handlers.panels then
        groups[#groups + 1] = handlers.panels
    end

    ui.open_actions({ groups = groups })
end

---Open the main panel displaying a single formatted error message line.
---@param type_name string  Entity type key used to derive the panel title
---@param error_key string|nil  Lang key (or raw string) for the error message
---@return integer|nil buf  Buffer handle, or nil on failure
---@return integer|nil win  Window handle, or nil on failure
M.open_entity_error = function(type_name, error_key)
    local entity_def = M.entity_types[type_name]
    local title_text = "Error"
    if entity_def and entity_def.title and state.lang[entity_def.title] then
        title_text = state.lang[entity_def.title]
    elseif entity_def then
        title_text = entity_def.name
    end

    local error_message_text = (error_key and state.lang[error_key]) or error_key or "An unknown error occurred."
    local formatted_display_message = format_error_message(error_message_text)

    local buf_handle, win_handle = ui.open_main({ formatted_display_message }, title_text, 1)
    if buf_handle then
        vim.bo[buf_handle].buftype = "nofile"
        vim.bo[buf_handle].modifiable = false
    end
    return buf_handle, win_handle
end

---Validate that a proposed entity name is non-empty and meets the minimum length requirement
---defined by the entity type.
---@param type_name string  Entity type key (must exist in `M.entity_types`)
---@param name_to_validate string|nil  The candidate name string
---@return boolean ok  True when the name passes all checks
---@return string|nil err  Error key ("UNKNOWN_ENTITY_TYPE" or "LEN_NAME"), or nil on success
M.validate_entity_name = function(type_name, name_to_validate)
    local entity_def = M.entity_types[type_name]
    if not entity_def then
        return false, "UNKNOWN_ENTITY_TYPE"
    end
    if not name_to_validate or vim.trim(name_to_validate) == "" then
        return false, "LEN_NAME"
    end
    if #vim.trim(name_to_validate) < (entity_def.min_name_len or 1) then
        return false, "LEN_NAME"
    end
    return true, nil
end

---Look up and return the entity type definition for `type_name`.
---@param type_name string  Entity type key
---@return EntityTypeDef|nil  The definition table, or nil if the type is not registered
M.get_entity_type = function(type_name)
    return M.entity_types[type_name]
end

---Open the in-zone rename prompt for an entity and apply the new name on confirm.
---`on_rename` does the validation + DB write (and its own panel refresh on success) and
---returns one of: an error-code string when validation fails ("LEN_NAME"/"EXIST_NAME"/…),
---a truthy value on success, or nil/false on a DB failure — this helper maps that result
---to the matching notification. Pressing `<Esc>` cancels (the callback never fires).
---@param type_name string  Entity type key (must exist in `M.entity_types`)
---@param id any  ID of the entity to rename
---@param current_name string|nil  Existing name, pre-filled into the prompt
---@param parent_context any  Parent scope id forwarded to `on_rename` (e.g. workspace/project id)
---@param on_rename fun(id: any, new_name: string, parent_context: any): string|boolean|nil
M.rename_entity = function(type_name, id, current_name, parent_context, on_rename)
    local entity_def = M.entity_types[type_name]
    if not entity_def or not id then
        return
    end
    local prompt = (entity_def.rename_prompt and state.lang[entity_def.rename_prompt])
        or state.lang[type_name:upper() .. "_NEW_NAME"]
        or "New name"
    ui.create_input_field(prompt, current_name or "", function(value)
        if not value or vim.trim(value) == "" then
            notify.info(state.lang.OPERATION_CANCELLED or "Operation cancelled")
            return
        end
        local result = on_rename(id, vim.trim(value), parent_context)
        if result == true then
            notify.info(state.lang[entity_def.renamed_success] or "Renamed successfully.")
        elseif type(result) == "string" then
            local err_key = entity_def.rename_failed
            if result == "LEN_NAME" then
                err_key = entity_def.name_len_error
            elseif result == "EXIST_NAME" then
                err_key = entity_def.name_exist_error
            end
            notify.error(state.lang[err_key] or state.lang[result] or "Failed to rename.")
        else
            notify.error(state.lang[entity_def.rename_failed] or "Failed to rename.")
        end
    end)
end

---Confirm and delete an entity through the in-zone y/n prompt (`delete_confirm`, interpolated
---with `name`). On a "y"/"yes" answer `on_delete` performs the DB delete + its own panel refresh
---and returns truthy on success / nil-false on failure; any other answer (or `<Esc>`) cancels.
---@param type_name string  Entity type key (must exist in `M.entity_types`)
---@param id any  ID of the entity to delete
---@param name string|nil  Entity name, interpolated into the confirmation prompt
---@param parent_context any  Parent scope id forwarded to `on_delete`
---@param on_delete fun(id: any, parent_context: any): boolean|nil
M.delete_entity = function(type_name, id, name, parent_context, on_delete)
    local entity_def = M.entity_types[type_name]
    if not entity_def or not id then
        return
    end
    local prompt_tpl = state.lang[entity_def.delete_confirm] or "➤ Delete '%s'? (y/n)"
    local prompt = string.format(prompt_tpl, name or "")
    ui.create_input_field(prompt, "", function(value)
        local answer = value and vim.trim(value):lower() or ""
        if answer ~= "y" and answer ~= "yes" then
            notify.info(state.lang.OPERATION_CANCELLED or "Operation cancelled")
            return
        end
        local result = on_delete(id, parent_context)
        if result then
            notify.info(state.lang[entity_def.deleted_success] or "Deleted successfully.")
        else
            notify.error(state.lang[entity_def.delete_failed] or "Failed to delete.")
        end
    end)
end

---Call `func_to_call` inside a protected call. On error, emit a formatted error notification
---that includes `operation_name`; on success, return the function's result.
---@param operation_name string  Human-readable label used in the error notification
---@param func_to_call function  The UI function to invoke
---@param ... any  Additional arguments forwarded to `func_to_call`
---@return any  Return value of `func_to_call`, or nil if it raised an error
M.safe_ui_operation = function(operation_name, func_to_call, ...)
    local ok, result = pcall(func_to_call, ...)
    if not ok then
        local error_msg_format = state.lang.UI_OPERATION_FAILED_FOR or "UI operation '%s' failed."
        notify.error(string.format(error_msg_format, operation_name))
    end
    return result
end

---Re-render the icon prefix for every line in an entity list buffer without changing the
---underlying data. Useful after an active-entity switch where only icons need to update.
---@param buf_handle integer  Target buffer handle
---@param entities_data table[]  Current ordered list of entity records
---@param type_name string  Entity type key used for icon resolution
---@param active_entity_id any  ID of the entity that should now appear active
---@param custom_active_check_fn (fun(ent: table, active_id: any): boolean)|nil  Optional active predicate
---@param line_formatter_fn (fun(ent: table): string)|nil  Optional custom text formatter
---@return boolean  True when the buffer was successfully updated, false on invalid buffer or unknown type
M.refresh_entity_icons = function(
    buf_handle,
    entities_data,
    type_name,
    active_entity_id,
    custom_active_check_fn,
    line_formatter_fn
)
    if not buf_handle or not vim.api.nvim_buf_is_valid(buf_handle) then
        return false
    end
    local entity_def = M.entity_types[type_name]
    if not entity_def then
        return false
    end
    local display_lines = {}
    for _, entity_item in ipairs(entities_data) do
        local is_active = determine_active(entity_def, entity_item, active_entity_id, custom_active_check_fn)
        table.insert(display_lines, format_line(entity_item, entity_def.name, is_active, line_formatter_fn))
    end
    vim.bo[buf_handle].modifiable = true
    vim.api.nvim_buf_set_lines(buf_handle, 0, -1, false, display_lines)
    vim.bo[buf_handle].modifiable = false
    return true
end

---Invalidate the icon cache so that subsequent calls to `get_entity_icon` re-read from config.
---Call this after the user changes icon configuration at runtime.
M.clear_icon_cache = function()
    icon_cache = {}
end

---@class ErrorContext
---@field win integer  Window handle of the error panel
---@field buf integer  Buffer handle of the error panel
---@field error_state_key string  The error type key that triggered this panel
---@field last_real_win integer|nil  Window handle to restore focus to on close

---Register buffer-local keymaps that let the user close the error panel or navigate to the
---appropriate entity UI depending on which precondition failed.
---@param error_context ErrorContext  Context describing the error panel state
---@param error_type_key string  One of "PROJECT_NOT_ACTIVE", "WORKSPACE_NOT_ACTIVE", "TAB_NOT_ACTIVE", etc.
local function setup_error_navigation_keymaps(error_context, error_type_key)
    local buf = error_context.buf
    local keymap_opts = { buffer = buf, silent = true, nowait = true }

    local function close_and_restore_focus()
        require("lvim-space.ui").close_all()
        if error_context.last_real_win and vim.api.nvim_win_is_valid(error_context.last_real_win) then
            vim.api.nvim_set_current_win(error_context.last_real_win)
        end
    end

    vim.keymap.set("n", "q", close_and_restore_focus, keymap_opts)
    vim.keymap.set("n", "<Esc>", close_and_restore_focus, keymap_opts)

    local keymappings = config.keymappings or {}
    local global_keys = keymappings.global or {}

    if error_type_key == "PROJECT_NOT_ACTIVE" then
        vim.keymap.set("n", global_keys.projects or "p", function()
            require("lvim-space.ui.projects").init()
        end, keymap_opts)
    elseif error_type_key == "WORKSPACE_NOT_ACTIVE" then
        vim.keymap.set("n", global_keys.projects or "p", function()
            require("lvim-space.ui.projects").init()
        end, keymap_opts)
        if state.project_id then
            vim.keymap.set("n", global_keys.workspaces or "w", function()
                require("lvim-space.ui.workspaces").init()
            end, keymap_opts)
        end
    elseif error_type_key == "TAB_NOT_ACTIVE" then
        vim.keymap.set("n", global_keys.projects or "p", function()
            require("lvim-space.ui.projects").init()
        end, keymap_opts)
        if state.project_id then
            vim.keymap.set("n", global_keys.workspaces or "w", function()
                require("lvim-space.ui.workspaces").init()
            end, keymap_opts)
        end
        if state.project_id and state.workspace_id then
            vim.keymap.set("n", global_keys.tabs or "t", function()
                require("lvim-space.ui.tabs").init()
            end, keymap_opts)
        end
    end
end

---Return the localized info-bar string that guides the user out of an error state.
---The message adapts based on how much of the project/workspace/tab hierarchy is established
---in the global state.
---@param error_type_key string  Error category key (e.g. "PROJECT_NOT_ACTIVE")
---@return string  Localized instruction string for the actions bar
local function get_error_info_line(error_type_key)
    local lang_keys = state.lang or {}
    if error_type_key == "PROJECT_NOT_ACTIVE" then
        return lang_keys.INFO_LINE_PROJECT_ERROR or "Project not active. Press 'p' for projects."
    elseif error_type_key == "WORKSPACE_NOT_ACTIVE" then
        if state.project_id then
            return lang_keys.INFO_LINE_WORKSPACE_ERROR or "Workspace not active. Press 'w' for workspaces."
        else
            return lang_keys.INFO_LINE_PROJECT_ERROR or "Project not active. Press 'p' for projects."
        end
    elseif error_type_key == "TAB_NOT_ACTIVE" then
        if state.project_id and state.workspace_id then
            return lang_keys.INFO_LINE_TAB_ERROR or "Tab not active. Press 't' for tabs."
        elseif state.project_id then
            return lang_keys.INFO_LINE_WORKSPACE_ERROR or "Workspace not active. Press 'w' for workspaces."
        else
            return lang_keys.INFO_LINE_PROJECT_ERROR or "Project not active. Press 'p' for projects."
        end
    end
    return lang_keys.INFO_LINE_GENERIC_QUIT or "Press 'q' to quit."
end

---Attach error-navigation keymaps to the currently focused window/buffer and open the
---actions bar with contextual guidance for the given error state.
---@param error_type_key string  Error category key (e.g. "PROJECT_NOT_ACTIVE", "TAB_NOT_ACTIVE")
---@param last_real_win_handle integer|nil  Window to restore focus to when the user closes the panel
M.setup_error_navigation = function(error_type_key, last_real_win_handle)
    local current_win = vim.api.nvim_get_current_win()
    local current_buf = vim.api.nvim_get_current_buf()
    local error_context_data = {
        win = current_win,
        buf = current_buf,
        error_state_key = error_type_key,
        last_real_win = last_real_win_handle,
    }
    setup_error_navigation_keymaps(error_context_data, error_type_key)
    ui.open_actions(get_error_info_line(error_type_key))
end

return M
