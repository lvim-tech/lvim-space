-- lua/lvim-space/ui/cursor.lua
-- Cursor visibility management for lvim-space panels and input buffers

local api = vim.api

local M = {}

-- Filetypes that trigger cursor hiding (panels / select menus)
local PANEL_FILETYPES = {
    ["lvim-space"]        = true,
    ["lvim-space-panel"]  = true,
    ["lvim-space-prompt"] = true,
}

-- Filetypes that keep the cursor visible (user types in these)
local INPUT_FILETYPES = {
    ["lvim-space-input"]           = true,
    ["lvim-space-search-input"]    = true,
    ["lvim-space-tabs-input"]      = true,
    ["lvim-space-workspace-input"] = true,
}

-- Additionally track buffers explicitly registered as input
local input_buffers = {}

-- State
local _saved_guicursor = nil
local _cursor_hidden   = false

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

---Hide the Neovim cursor by switching to a 1-cell transparent vertical bar.
---Saves the original `guicursor` value so it can be restored by `show_cursor`.
---No-op when the cursor is already hidden.
local function hide_cursor()
    if _cursor_hidden then return end
    _saved_guicursor = vim.o.guicursor
    -- "a:" = all modes. ver1 = 1-cell vertical bar, practically invisible.
    -- We also link a dedicated hl group with blend=100 for GUI / termguicolors.
    api.nvim_set_hl(0, "LvimSpaceHiddenCursor", { blend = 100, nocombine = true })
    vim.o.guicursor = "a:ver1-LvimSpaceHiddenCursor"
    _cursor_hidden = true
end

---Restore the cursor to the shape that was active before `hide_cursor` was called.
---No-op when the cursor is already visible.
local function show_cursor()
    if not _cursor_hidden then return end
    if _saved_guicursor then
        vim.o.guicursor = _saved_guicursor
        _saved_guicursor = nil
    end
    _cursor_hidden = false
end

--- Return true when the buffer belongs to a panel (cursor should be hidden).
---@param bufnr integer
---@return boolean
local function is_panel_buf(bufnr)
    if not bufnr or not api.nvim_buf_is_valid(bufnr) then return false end
    if input_buffers[bufnr] then return false end
    local ok, ft = pcall(function() return vim.bo[bufnr].filetype end)
    return ok and PANEL_FILETYPES[ft] == true
end

--- Return true when the buffer is an input field (cursor must stay visible).
---@param bufnr integer
---@return boolean
local function is_input_buf(bufnr)
    if not bufnr or not api.nvim_buf_is_valid(bufnr) then return false end
    if input_buffers[bufnr] then return true end
    local ok, ft = pcall(function() return vim.bo[bufnr].filetype end)
    return ok and INPUT_FILETYPES[ft] == true
end

--- Return true if at least one visible window contains a panel buffer.
---@return boolean
local function any_panel_open()
    for _, win in ipairs(api.nvim_list_wins()) do
        if api.nvim_win_is_valid(win) then
            local ok, buf = pcall(api.nvim_win_get_buf, win)
            if ok and buf and is_panel_buf(buf) then return true end
        end
    end
    return false
end

--- Recompute and apply the correct cursor state for the current context.
--- Hides the cursor when a panel buffer is focused or visible; shows it when
--- an input buffer is focused or no panel is open.
local function refresh()
    local ok_win, win = pcall(api.nvim_get_current_win)
    if not ok_win or not win or not api.nvim_win_is_valid(win) then
        show_cursor()
        return
    end
    local ok_buf, buf = pcall(api.nvim_win_get_buf, win)
    if not ok_buf or not buf or not api.nvim_buf_is_valid(buf) then
        show_cursor()
        return
    end

    if is_input_buf(buf) then
        show_cursor()
        return
    end

    if is_panel_buf(buf) or any_panel_open() then
        hide_cursor()
    else
        show_cursor()
    end
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Explicitly mark / unmark a buffer as an input buffer.
---@param bufnr integer
---@param is_input boolean
function M.mark_input_buffer(bufnr, is_input)
    if is_input then
        input_buffers[bufnr] = true
    else
        input_buffers[bufnr] = nil
    end
    vim.schedule(refresh)
end

--- Force-refresh cursor visibility from outside (e.g. after closing a panel).
function M.refresh()
    refresh()
end

--- Register autocommands. Called once from ui.init().
function M.setup()
    local aug = api.nvim_create_augroup("LvimSpaceCursorBlend", { clear = true })

    api.nvim_create_autocmd({ "WinEnter", "WinLeave", "WinClosed", "BufEnter", "FileType" }, {
        group    = aug,
        callback = function() vim.schedule(refresh) end,
    })

    api.nvim_create_autocmd({ "BufDelete", "BufWipeout", "BufUnload" }, {
        group    = aug,
        callback = function(ev)
            if ev.buf then input_buffers[ev.buf] = nil end
            vim.schedule(refresh)
        end,
    })

    -- Always show cursor in command-line mode
    api.nvim_create_autocmd("CmdlineEnter", {
        group    = aug,
        callback = show_cursor,
    })
    api.nvim_create_autocmd("CmdlineLeave", {
        group    = aug,
        callback = function() vim.schedule(refresh) end,
    })
end

return M
