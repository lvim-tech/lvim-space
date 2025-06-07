local config = require("lvim-space.config")
local state = require("lvim-space.api.state")

local M = {}

local api = vim.api
local cmd = vim.cmd

local saved_state = {
    main = nil,
    actions = nil,
    input_line = nil,
}

state.disable_auto_close = false
vim.opt.guicursor = "n-v-c:block-Cursor/lCursor,i-ci-ve:ver25-Cursor/lCursor,r-cr:hor20,o:hor50"

local function is_valid_win(win)
    return win and api.nvim_win_is_valid(win)
end

local function is_valid_buf(buf)
    return buf and api.nvim_buf_is_valid(buf)
end

local function safe_close_win(win)
    if is_valid_win(win) then
        pcall(api.nvim_win_close, win, true)
    end
end

local function safe_delete_buf(buf)
    if is_valid_buf(buf) then
        pcall(api.nvim_buf_delete, buf, { force = true })
    end
end

local function set_cursor_blend(blend)
    blend = tonumber(blend) or 0
    cmd("hi Cursor blend=" .. blend)
end

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
        vim.wo[win].cursorline = options.cursorline
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

M.close_window = function(window_type)
    if not state.ui or not state.ui[window_type] then
        return
    end

    local win_info = state.ui[window_type]
    safe_close_win(win_info.win)
    safe_delete_buf(win_info.buf)
    state.ui[window_type] = nil
end

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

M.open_main = function(lines, name, selected_line)
    M.save_state("main")
    M.close_window("content")

    local status_space = config.ui.spacing or 2
    local content_height = #lines
    local win_height = math.min(math.max(content_height, 1), config.max_height or 10)
    local main_border = build_border(config.ui.border.main or {}, "main")

    selected_line = selected_line or get_target_line(lines)
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

            set_cursor_blend(100)
            local cursor_group = api.nvim_create_augroup("LvimSpaceCursorBlend", { clear = true })

            api.nvim_create_autocmd({ "WinLeave", "WinEnter" }, {
                group = cursor_group,
                callback = function()
                    set_cursor_blend(api.nvim_get_current_win() == win and 100 or 0)
                end,
            })

            api.nvim_create_autocmd("BufWipeout", {
                buffer = buf,
                group = cursor_group,
                callback = function()
                    set_cursor_blend(0)
                    if not state.disable_auto_close then
                        M.close_actions()
                    end
                end,
                once = true,
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

                local line = math.max(1, math.min(selected_line, api.nvim_buf_line_count(buf)))
                pcall(api.nvim_win_set_cursor, win, { line, 0 })
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

function M.create_input_field(prompt, default_value, callback)
    state.disable_auto_close = true

    if state.ui and state.ui.content and is_valid_win(state.ui.content.win) then
        saved_state.input_line = api.nvim_win_get_cursor(state.ui.content.win)[1]
    end

    M.save_state("actions")
    M.close_window("status_line")

    local dims = calculate_input_dimensions(prompt)

    local _, prompt_win = M.create_window({
        content = dims.prompt_text,
        row = vim.o.lines - 1,
        col = 0,
        width = dims.prompt_width,
        height = 1,
        zindex = 50,
        focusable = false,
        winhighlight = "Normal:LvimSpacePrompt,NormalNC:LvimSpacePrompt,FloatBorder:LvimSpacePrompt",
        border = dims.prompt_border,
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
        on_create = function(win, buf)
            if not is_valid_win(win) or not is_valid_buf(buf) then
                return
            end

            api.nvim_buf_set_var(buf, "input_callback", callback)
            api.nvim_buf_set_var(buf, "input_default", default_value or "")
            set_cursor_blend(0)

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
                    set_cursor_blend(0)
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
        return nil, nil
    end

    state.ui.prompt_window = { win = prompt_win }
    return input_buf, input_win
end

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

    local main_win = state.ui and state.ui.content and state.ui.content.win
    if is_valid_win(main_win) and api.nvim_get_current_win() == main_win then
        set_cursor_blend(100)
    end
end

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

M.save_state = function(type)
    if type == "main" and state.ui and state.ui.content and is_valid_buf(state.ui.content.buf) then
        saved_state.main = api.nvim_buf_get_lines(state.ui.content.buf, 0, -1, false)
    elseif type == "actions" and state.ui and state.ui.status_line and is_valid_buf(state.ui.status_line.buf) then
        saved_state.actions = api.nvim_buf_get_lines(state.ui.status_line.buf, 0, -1, false)
    end
end

M.restore_state = function(type)
    if type == "main" and saved_state.main and #saved_state.main > 0 then
        M.close_window("content")
        M.open_main(saved_state.main)
    elseif type == "actions" and saved_state.actions and #saved_state.actions > 0 then
        M.close_window("status_line")
        M.open_actions(saved_state.actions[1])
    end
end

M.close_content = function()
    M.close_window("content")
    M.close_actions()
end

M.close_actions = function()
    M.close_window("status_line")
end

M.close_all = function()
    for _, win_type in ipairs({ "prompt_window", "input_window", "status_line", "content" }) do
        M.close_window(win_type)
    end
end

return M
