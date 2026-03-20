-- lua/lvim-space/ui/init.lua
-- Core UI module: window creation, management, input fields, and state
-- persistence for the lvim-space floating panel system.

local config      = require("lvim-space.config")
local state       = require("lvim-space.api.state")
local lvim_cursor = require("lvim-utils.cursor")

local M = {}

local api = vim.api
local cmd = vim.cmd

local ns_syntax     = api.nvim_create_namespace("lvim_space_syntax")
local ns_cursorline = api.nvim_create_namespace("lvim_space_cursorline")

---@class LvimSpaceSavedState
---@field main string[]|nil Lines saved from the main content window
---@field actions string|nil Content saved from the status-line/actions window
---@field input_line integer|nil Cursor row that was active when an input was opened

---@type LvimSpaceSavedState
local saved_state = {
    main = nil,
    actions = nil,
    input_line = nil,
}

---@param win integer Window handle to check
---@return boolean is_valid True when the handle is non-nil and refers to a valid window
local function is_valid_win(win)
    return win and api.nvim_win_is_valid(win)
end

---@param buf integer Buffer handle to check
---@return boolean is_valid True when the handle is non-nil and refers to a valid buffer
local function is_valid_buf(buf)
    return buf and api.nvim_buf_is_valid(buf)
end

---Close a window safely, ignoring errors if the window is already gone.
---@param win integer Window handle
local function safe_close_win(win)
    if is_valid_win(win) then
        pcall(api.nvim_win_close, win, true)
    end
end

---Delete a buffer safely, ignoring errors if the buffer is already gone.
---@param buf integer Buffer handle
local function safe_delete_buf(buf)
    if is_valid_buf(buf) then
        pcall(api.nvim_buf_delete, buf, { force = true })
    end
end

---Determine which line in a project list should be selected on open.
---Prefers the previously-saved input line, then falls back to the currently
---active project, and finally defaults to line 1.
---@param projects table[] List of project records (each must have an `id` field)
---@return integer line 1-based line index to position the cursor on
local function get_target_line(projects)
    if saved_state.input_line and projects[saved_state.input_line] then
        return saved_state.input_line
    end

    if state.project_id then
        for idx, project in ipairs(projects) do
            if tostring(project.id) == tostring(state.project_id) then
                return idx
            end
        end
    end

    return 1
end

---Move Neovim focus back to the main content window and position the cursor
---on the previously selected project line.
local function restore_main_window_focus()
    if not (state.ui and state.ui.content and is_valid_win(state.ui.content.win)) then
        return
    end

    local ok, data = pcall(require, "lvim-space.api.data")
    local projects = ok and data.find_projects and data.find_projects() or {}

    local target_line = get_target_line(projects)
    if is_valid_win(state.ui.content.win) then
        pcall(api.nvim_win_set_cursor, state.ui.content.win, { target_line, 0 })
        api.nvim_set_current_win(state.ui.content.win)
    end
end

---Build the 8-element border character table expected by `nvim_open_win`.
---The resulting array follows the Neovim convention:
---  { top, top-right, right, bottom-right, bottom, bottom-left, left, top-left }
---@param border_config table Border configuration with optional `left` and `right` boolean fields
---@param border_type string One of `"main"`, `"info"`, or any other value for the default style
---@return string[] border Eight-element array of border characters
local function build_border(border_config, border_type)
    local border_sign = config.ui.border.sign or ""
    local border

    if border_type == "main" then
        border = { " ", " ", " ", "", "", "", "", "" }
        if border_config.left then
            border[8] = border_sign
        end
        if border_config.right then
            border[4] = border_sign
        end
    elseif border_type == "info" then
        border = { "", "", "", "", "", "", "", "" }
        if border_config.left then
            border[8] = border_sign
        end
        if border_config.right then
            border[4] = border_sign
        end
    else
        border = {
            "",
            "",
            "",
            border_config.right and border_sign or "",
            "",
            "",
            "",
            border_config.left and border_sign or "",
        }
    end

    return border
end

---Validate that a floating-window configuration has sensible geometry values.
---@param win_config table The window config table (must contain `width`, `height`, `row`, `col`)
---@return boolean valid True when all required geometry fields are present and in range
local function validate_window_config(win_config)
    if not win_config.width or win_config.width < 1 then
        return false
    end
    if not win_config.height or win_config.height < 1 then
        return false
    end
    if win_config.row < 0 or win_config.col < 0 then
        return false
    end
    return true
end

---Attach a lightweight cursorline highlight to `buf` / `win` using extmarks.
---Neovim's built-in `cursorline` option is disabled for plugin windows; this
---function re-implements the visual effect via the `LvimSpaceCursorLine` hl
---group so that the appearance can be controlled precisely.
---@param buf integer Buffer handle
---@param win integer Window handle
local function setup_custom_cursorline(buf, win)
    if not is_valid_buf(buf) or not is_valid_win(win) then
        return
    end

    local ns = ns_cursorline

    local function update_cursor_highlight()
        if not is_valid_buf(buf) or not is_valid_win(win) then
            return
        end

        api.nvim_buf_clear_namespace(buf, ns, 0, -1)

        local cursor_pos = api.nvim_win_get_cursor(win)
        local line = cursor_pos[1] - 1
        local total_lines = api.nvim_buf_line_count(buf)

        if line >= 0 and line < total_lines then
            api.nvim_buf_set_extmark(buf, ns, line, 0, {
                end_line = line + 1,
                hl_group = "LvimSpaceCursorLine",
                hl_eol = true,
                priority = 50,
            })
        end
    end

    local cursor_group = api.nvim_create_augroup("LvimSpaceCursorLine_" .. buf, { clear = true })

    api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
        group = cursor_group,
        buffer = buf,
        callback = update_cursor_highlight,
    })

    api.nvim_create_autocmd("BufDelete", {
        group = cursor_group,
        buffer = buf,
        callback = function()
            pcall(api.nvim_del_augroup_by_id, cursor_group)
        end,
        once = true,
    })

    vim.schedule(update_cursor_highlight)
end

---Apply a highlight group to a byte range on a single buffer line via extmarks.
---@param buf integer Buffer handle
---@param line integer 0-based line index
---@param start_col integer 0-based start byte column (inclusive)
---@param end_col integer 0-based end byte column (exclusive)
---@param hl_group string Name of the highlight group to apply
M.add_highlight = function(buf, line, start_col, end_col, hl_group)
    if not is_valid_buf(buf) then
        return
    end

    api.nvim_buf_set_extmark(buf, ns_syntax, line, start_col, {
        end_col = end_col,
        hl_group = hl_group,
        priority = 200,
    })
end

---Remove all extmark-based highlights previously set by `M.add_highlight`.
---@param buf integer Buffer handle
M.clear_highlights = function(buf)
    if not is_valid_buf(buf) then
        return
    end

    api.nvim_buf_clear_namespace(buf, ns_syntax, 0, -1)
end

---@class LvimSpaceWindowOptions
---@field content string|string[]|nil Initial buffer content (string or list of lines)
---@field filetype string|nil Filetype to set on the new buffer
---@field row integer|nil Top edge of the floating window (editor-relative)
---@field col integer|nil Left edge of the floating window (editor-relative)
---@field width integer|nil Window width in columns
---@field height integer|nil Window height in lines
---@field focus boolean|nil Whether to focus the window immediately
---@field focusable boolean|nil Whether the window can receive focus (default true)
---@field zindex integer|nil Stacking z-index for the floating window
---@field border string[]|nil 8-element border character array
---@field title string|nil Title shown in the window border
---@field title_position string|nil Horizontal alignment of the title (`"left"`, `"center"`, `"right"`)
---@field winhighlight string|nil Comma-separated `WinhighlightOption` string
---@field cursorline boolean|nil When non-nil, forces `cursorline` off for this window
---@field store_in string|nil When set, stores `{ win, buf }` under `state.ui[store_in]`
---@field on_create fun(win: integer, buf: integer)|nil Callback invoked after the window is created

---Create a new floating window backed by a scratch buffer.
---@param options LvimSpaceWindowOptions Configuration for the new window
---@return integer|nil buf Buffer handle, or nil on failure
---@return integer|nil win Window handle, or nil on failure
M.create_window = function(options)
    local buf = api.nvim_create_buf(false, true)
    if not is_valid_buf(buf) then
        return nil, nil
    end

    vim.bo[buf].filetype = options.filetype or config.filetype or "lvim-space-panel"

    if options.content then
        local content = type(options.content) == "table" and options.content or { tostring(options.content) }
        api.nvim_buf_set_lines(buf, 0, -1, false, content)
    end

    local win_config = {
        relative = "editor",
        row = options.row or 0,
        col = options.col or 0,
        width = options.width or vim.o.columns,
        height = options.height or 1,
        style = "minimal",
        border = options.border or { "", "", "", "", "", "", "", "" },
        zindex = options.zindex,
        focusable = options.focusable ~= false,
    }

    if options.title then
        win_config.title = " " .. options.title .. " "
        win_config.title_pos = options.title_position or "center"
    end

    if not validate_window_config(win_config) then
        safe_delete_buf(buf)
        return nil, nil
    end

    local ok, win = pcall(api.nvim_open_win, buf, options.focus or false, win_config)
    if not ok or not is_valid_win(win) then
        safe_delete_buf(buf)
        return nil, nil
    end

    if options.winhighlight and is_valid_win(win) then
        vim.wo[win].winhighlight = options.winhighlight
    end

    if options.cursorline ~= nil and is_valid_win(win) then
        vim.wo[win].cursorline = false
    end

    if options.store_in then
        state.ui = state.ui or {}
        state.ui[options.store_in] = { win = win, buf = buf }
    end

    if options.on_create and is_valid_win(win) and is_valid_buf(buf) then
        options.on_create(win, buf)
    end

    return buf, win
end

---Close a managed plugin window and release its buffer.
---Removes the entry from `state.ui` when done.
---@param window_type string Key used in `state.ui` (e.g. `"content"`, `"status_line"`)
M.close_window = function(window_type)
    if not state.ui or not state.ui[window_type] then
        return
    end

    local win_info = state.ui[window_type]
    safe_close_win(win_info.win)
    safe_delete_buf(win_info.buf)
    state.ui[window_type] = nil
end

---Check whether a window handle belongs to one of the plugin's managed windows.
---Used by the auto-close autocmd to decide when to tear down the UI.
---@param win integer Window handle to test
---@return boolean is_plugin_window True when `win` is owned by lvim-space
M.is_plugin_window = function(win)
    if not state.ui then
        return false
    end

    for _, win_type in ipairs({ "content", "status_line", "prompt_window", "input_window" }) do
        local win_info = state.ui[win_type]
        if win_info and win_info.win == win then
            return true
        end
    end

    return false
end

---Initialise the UI subsystem.
---Sets up cursor management and registers the auto-close `WinEnter` autocmd
---that tears down the panel whenever focus moves to a non-plugin window.
M.init = function()
    state.disable_auto_close = false
    lvim_cursor.setup({
        ft = {
            config.filetype or "lvim-space",
            "lvim-space-panel",
            "lvim-space-prompt",
        },
    })
    local auto_close_group = api.nvim_create_augroup("LvimSpaceAutoClose", { clear = true })
    api.nvim_create_autocmd("WinEnter", {
        group = auto_close_group,
        callback = function()
            if state.disable_auto_close then
                return
            end
            local current_win = api.nvim_get_current_win()
            if not M.is_plugin_window(current_win) then
                M.close_all()
            end
        end,
    })
end

---Open (or reopen) the primary content panel showing a list of items.
---Saves the previous main-window state, closes the existing content window,
---then creates a new floating window at the bottom of the editor.
---@param lines string[] Lines to display in the panel
---@param name string|nil Title shown in the window border (defaults to config value)
---@param selected_line integer|nil 1-based line to position the cursor on initially
---@return integer|nil buf Buffer handle of the new window
---@return integer|nil win Window handle of the new window
M.open_main = function(lines, name, selected_line)
    M.save_state("main")
    M.close_window("content")

    local status_space = config.ui.spacing or 2
    local content_height = #lines
    local win_height = math.min(math.max(content_height, 1), config.max_height or 10)
    local main_border = build_border(config.ui.border.main or {}, "main")

    if not selected_line then
        selected_line = (saved_state.input_line and saved_state.input_line <= #lines) and saved_state.input_line or 1
    end
    selected_line = math.max(1, math.min(selected_line, #lines))

    local buf, win = M.create_window({
        content = lines,
        title = name or config.title or "LVIM SPACE",
        title_position = config.title_position or "center",
        row = vim.o.lines - win_height - status_space,
        col = 0,
        width = vim.o.columns,
        height = win_height,
        focus = true,
        store_in = "content",
        cursorline = true,
        winhighlight = table.concat({
            "Normal:LvimSpaceNormal",
            "NormalNC:LvimSpaceNormal",
            "CursorLine:LvimSpaceCursorLine",
            "FloatTitle:LvimSpaceTitle",
            "FloatBorder:LvimSpaceNormal",
        }, ","),
        border = main_border,
        on_create = function(win, buf)
            if not is_valid_win(win) or not is_valid_buf(buf) then
                return
            end

            setup_custom_cursorline(buf, win)

            api.nvim_create_autocmd("BufWipeout", {
                buffer = buf,
                once = true,
                callback = function()
                    if not state.disable_auto_close then
                        M.close_actions()
                    end
                end,
            })

            local keymaps = require("lvim-space.core.keymaps")
            keymaps.disable_all_maps(buf)
            keymaps.enable_base_maps(buf)

            local function handle_resize()
                if not is_valid_win(win) or not is_valid_buf(buf) then
                    return
                end

                local new_content = api.nvim_buf_get_lines(buf, 0, -1, false)
                local new_height = math.min(math.max(#new_content, 1), config.max_height or 10)
                local current_config = api.nvim_win_get_config(win)

                local new_config = vim.tbl_extend("force", current_config, {
                    row = vim.o.lines - new_height - status_space,
                    col = 0,
                    height = new_height,
                    width = vim.o.columns,
                })

                pcall(api.nvim_win_set_config, win, new_config)
            end

            api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "VimResized" }, {
                buffer = buf,
                callback = handle_resize,
            })

            vim.schedule(function()
                if is_valid_win(win) then
                    pcall(api.nvim_win_set_cursor, win, { selected_line, 0 })
                end
            end)
        end,
    })

    return buf, win
end

---Open the status-line / actions bar at the very bottom of the editor.
---This is a non-focusable, single-line floating window.
---@param line string|string[] Text content to display in the actions bar
---@return integer|nil buf Buffer handle
---@return integer|nil win Window handle
M.open_actions = function(line)
    M.save_state("actions")
    M.close_window("status_line")

    local info_border = build_border(config.ui.border.info or {}, "info")

    return M.create_window({
        content = line,
        row = vim.o.lines - 1,
        col = 0,
        width = vim.o.columns,
        height = 1,
        zindex = 50,
        focusable = false,
        store_in = "status_line",
        winhighlight = "Normal:LvimSpaceInfo,NormalNC:LvimSpaceInfo,FloatBorder:LvimSpaceInfo",
        border = info_border,
    })
end

---@class LvimSpaceInputDimensions
---@field prompt_text string The full prompt string including the configured separator
---@field prompt_width integer Display width of `prompt_text` in columns
---@field prompt_total_width integer `prompt_width` plus any border columns for the prompt window
---@field input_col integer Column at which the input window should start
---@field input_width integer Width available for the input field content
---@field prompt_border string[] 8-element border array for the prompt window
---@field input_border string[] 8-element border array for the input window

---Calculate geometry for the prompt label and the adjacent input field.
---@param prompt string The label text shown to the left of the input field
---@return LvimSpaceInputDimensions dims Computed layout information
local function calculate_input_dimensions(prompt)
    local total_width = vim.o.columns
    local prompt_separator = config.ui.border.prompt.separate or ": "
    local prompt_text = prompt .. prompt_separator
    local prompt_width = vim.fn.strdisplaywidth(prompt_text)

    local prompt_border_config = config.ui.border.prompt or {}
    local input_border_config = config.ui.border.input or {}

    local prompt_border_width = (prompt_border_config.left and 1 or 0) + (prompt_border_config.right and 1 or 0)
    local input_border_width = (input_border_config.left and 1 or 0) + (input_border_config.right and 1 or 0)

    local prompt_total_width = prompt_width + prompt_border_width
    local input_col = prompt_total_width
    local min_input_width = 20
    local input_content_width = math.max(min_input_width, total_width - input_col - input_border_width)

    return {
        prompt_text = prompt_text,
        prompt_width = prompt_width,
        prompt_total_width = prompt_total_width,
        input_col = input_col,
        input_width = input_content_width,
        prompt_border = build_border(prompt_border_config, "prompt"),
        input_border = build_border(input_border_config, "input"),
    }
end

---Open an inline input field composed of a read-only prompt window and an
---editable input window positioned side-by-side at the bottom of the editor.
---Pressing `<CR>` calls `callback` with the entered value; `<Esc>` cancels.
---@param prompt string Label displayed to the left of the input field
---@param default_value string|nil Pre-filled text for the input field
---@param callback fun(value: string, input_line: integer|nil) Function called on submit with the entered text and saved cursor line
---@param options table|nil Optional overrides (supports `prompt_filetype` and `input_filetype`)
---@return integer|nil buf Buffer handle of the input window
---@return integer|nil win Window handle of the input window
function M.create_input_field(prompt, default_value, callback, options)
    options = options or {}

    state.disable_auto_close = true

    if state.ui and state.ui.content and is_valid_win(state.ui.content.win) then
        saved_state.input_line = api.nvim_win_get_cursor(state.ui.content.win)[1]
    end

    M.save_state("actions")
    M.close_window("status_line")

    local dims = calculate_input_dimensions(prompt)

    local prompt_buf, prompt_win = M.create_window({
        content = dims.prompt_text,
        row = vim.o.lines - 1,
        col = 0,
        width = dims.prompt_width,
        height = 1,
        zindex = 50,
        focusable = false,
        winhighlight = "Normal:LvimSpacePrompt,NormalNC:LvimSpacePrompt,FloatBorder:LvimSpacePrompt",
        border = dims.prompt_border,
        filetype = options.prompt_filetype or "lvim-space-prompt",
    })

    local input_buf, input_win = M.create_window({
        content = default_value or "",
        row = vim.o.lines - 1,
        col = dims.input_col,
        width = dims.input_width,
        height = 1,
        zindex = 50,
        focusable = true,
        focus = true,
        store_in = "input_window",
        winhighlight = "Normal:LvimSpaceInput,NormalNC:LvimSpaceInput,FloatBorder:LvimSpaceInput",
        border = dims.input_border,
        filetype = options.input_filetype or "lvim-space-input",
        on_create = function(win, buf)
            if not is_valid_win(win) or not is_valid_buf(buf) then
                return
            end

            -- Exempt this buffer from cursor hiding (user types here).
            lvim_cursor.mark_input_buffer(buf, true)

            api.nvim_buf_set_var(buf, "input_callback", callback)
            api.nvim_buf_set_var(buf, "input_default", default_value or "")

            local function map(mode, lhs, rhs)
                vim.keymap.set(mode, lhs, rhs, { buffer = buf, noremap = true, silent = true, nowait = true })
            end

            map("i", "<Esc>", M.cancel_input)
            map("i", "<CR>", M.submit_input)

            local input_group = api.nvim_create_augroup("LvimSpaceInputHandling", { clear = true })

            api.nvim_create_autocmd("FocusLost", {
                buffer = buf,
                group = input_group,
                callback = function()
                    vim.schedule(function()
                        if not is_valid_buf(buf) then
                            return
                        end
                        local current_win = api.nvim_get_current_win()
                        if current_win == prompt_win and is_valid_win(win) then
                            api.nvim_set_current_win(win)
                            cmd("startinsert!")
                        elseif current_win ~= win then
                            M.cancel_input()
                        end
                    end)
                end,
            })

            api.nvim_create_autocmd("WinEnter", {
                group = input_group,
                callback = function()
                    local current_win = api.nvim_get_current_win()
                    if current_win == prompt_win and is_valid_win(win) then
                        api.nvim_set_current_win(win)
                        cmd("startinsert!")
                    end
                end,
            })

            vim.defer_fn(function()
                if is_valid_win(win) then
                    pcall(api.nvim_win_set_cursor, win, { 1, #(default_value or "") })
                    api.nvim_set_current_win(win)
                    cmd("startinsert!")
                end
            end, 10)
        end,
    })

    if not input_buf or not input_win then
        M.close_window("prompt_window")
        if prompt_win then safe_close_win(prompt_win) end
        return nil, nil
    end

    state.ui.prompt_window = { win = prompt_win, buf = prompt_buf }
    return input_buf, input_win
end

---Cancel an active input field without invoking the submit callback.
---Closes both the prompt and input windows, restores the actions bar state,
---and returns focus to the main content window.
function M.cancel_input()
    local mode = api.nvim_get_mode().mode
    if mode:match("i") then
        cmd("stopinsert")
    end

    M.close_window("prompt_window")
    M.close_window("input_window")
    state.disable_auto_close = false
    M.close_window("status_line")
    M.restore_state("actions")
    restore_main_window_focus()
end

---Submit the currently active input field.
---Reads the first line of the input buffer, closes the input UI, and
---schedules the stored callback with the entered value.
function M.submit_input()
    local buf = api.nvim_get_current_buf()
    cmd("stopinsert")

    local input_value, callback
    if is_valid_buf(buf) then
        input_value = api.nvim_buf_get_lines(buf, 0, 1, false)[1]
        local success, cb = pcall(api.nvim_buf_get_var, buf, "input_callback")
        callback = success and cb or nil
    end

    M.close_window("prompt_window")
    M.close_window("input_window")
    state.disable_auto_close = false
    M.close_window("status_line")
    M.restore_state("actions")
    restore_main_window_focus()

    if type(callback) == "function" then
        vim.schedule(function()
            callback(input_value, saved_state.input_line)
        end)
    end
end

---Snapshot the current content of a managed window into `saved_state`.
---@param type string Which window to snapshot: `"main"` or `"actions"`
M.save_state = function(type)
    if type == "main" and state.ui and state.ui.content and is_valid_buf(state.ui.content.buf) then
        saved_state.main = api.nvim_buf_get_lines(state.ui.content.buf, 0, -1, false)
    elseif type == "actions" and state.ui and state.ui.status_line and is_valid_buf(state.ui.status_line.buf) then
        saved_state.actions = api.nvim_buf_get_lines(state.ui.status_line.buf, 0, -1, false)
    end
end

---Restore a previously snapshotted window from `saved_state`.
---@param type string Which window to restore: `"main"` or `"actions"`
M.restore_state = function(type)
    if type == "main" and saved_state.main and #saved_state.main > 0 then
        M.close_window("content")
        M.open_main(saved_state.main)
    elseif type == "actions" and saved_state.actions and #saved_state.actions > 0 then
        M.close_window("status_line")
        M.open_actions(saved_state.actions[1])
    end
end

---Close the main content window and the actions/status-line bar.
M.close_content = function()
    M.close_window("content")
    M.close_actions()
end

---Close the status-line / actions bar window.
M.close_actions = function()
    M.close_window("status_line")
end

---Close every window managed by the plugin (input, prompt, actions, content).
M.close_all = function()
    for _, win_type in ipairs({ "prompt_window", "input_window", "status_line", "content" }) do
        M.close_window(win_type)
    end
end

return M
