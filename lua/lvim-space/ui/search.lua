-- lvim-space.ui.search: file search, a THIN ADAPTER over the shared lvim-utils FILES picker — the SAME
-- `:LvimPicker files` finder (fzf TUI backend with a real-Neovim preview + coloured ft devicons, Lua fallback
-- otherwise), embedded in lvim-space's configured zone (`config.ui.mode` → area | float | bottom) so it docks
-- exactly where the panels do instead of opening a separate window. The candidate set is the picker's own
-- file list (`config.picker.source` in lvim-utils) run in the cwd — which lvim-space pins to the active
-- project root on project load, so the listing is project-scoped. ON SELECT it reuses the existing
-- data/session flow to open the file in the editor AND add it to the active tab (persisted) — the exact
-- behaviour of the old custom search panel. The split keys (`<C-v>` / `<C-x>`) open the selection in a
-- vertical / horizontal split. The picker owns matching, preview and rendering.
--
---@module "lvim-space.ui.search"

local config = require("lvim-space.config")
local notify = require("lvim-space.api.notify")
local state = require("lvim-space.api.state")
local data = require("lvim-space.api.data")
local session = require("lvim-space.core.session")
local ui = require("lvim-space.ui")
local picker = require("lvim-picker")

local M = {}

---Open the selected file in the best non-plugin editor window AND add it to the active tab's buffer list,
---persisting the change — preserving the legacy search on-select behaviour 1:1 (open + record + save), via
---the existing data / session functions. No panel is opened.
---@param path string|nil Absolute path of the chosen file.
local function select_file(path)
    if not path or vim.trim(path) == "" then
        notify.error(state.lang.FILE_PATH_NOT_FOUND or "Cannot find path for selected file")
        return
    end
    if vim.fn.filereadable(path) ~= 1 then
        notify.error(state.lang.FILE_NOT_READABLE or "File is not readable")
        return
    end

    local bufnr = vim.fn.bufadd(path)
    vim.fn.bufload(bufnr)

    -- Pick a real (non-plugin, non-floating) editor window to load the file into; fall back to `:edit`.
    local target = vim.api.nvim_get_current_win()
    if ui.is_plugin_window(target) or vim.api.nvim_win_get_config(target).relative ~= "" then
        target = nil
        for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
            if vim.api.nvim_win_get_config(w).relative == "" and not ui.is_plugin_window(w) then
                target = w
                break
            end
        end
    end
    if target and vim.api.nvim_win_is_valid(target) then
        vim.api.nvim_win_set_buf(target, bufnr)
    else
        pcall(vim.cmd, "edit " .. vim.fn.fnameescape(path))
    end
    if session.save_window_context then
        session.save_window_context(state.tab_active)
    end

    -- Record the file in the active tab (persisted) when it is not already there.
    local tab = data.find_tab_by_id(state.tab_active, state.workspace_id)
    if tab then
        local ok, tdata = pcall(vim.fn.json_decode, tab.data or "{}")
        if not ok or type(tdata) ~= "table" then
            tdata = {}
        end
        tdata.buffers = tdata.buffers or {}
        local exists = false
        for _, buf in ipairs(tdata.buffers) do
            if buf.filePath == path then
                exists = true
                break
            end
        end
        if not exists then
            table.insert(tdata.buffers, { filePath = path, bufnr = bufnr })
            data.update_tab_data(state.tab_active, vim.fn.json_encode(tdata), state.workspace_id)
            session.save_current_state(state.tab_active, true)
        end
    end
    notify.info(state.lang.SEARCH_FILE_OPENED or "File opened successfully.")
end

---Open the selected file in a split (no tab mutation — matching the legacy split-open keys).
---@param split_cmd "vsplit"|"split" The Vim split command.
---@param path string|nil Absolute path of the chosen file.
local function open_in_split(split_cmd, path)
    if not path or vim.trim(path) == "" then
        notify.error(state.lang.FILE_PATH_NOT_FOUND or "Cannot find path for selected file")
        return
    end
    if vim.fn.filereadable(path) ~= 1 then
        notify.error(state.lang.FILE_NOT_READABLE or "File is not readable")
        return
    end
    local ok = pcall(vim.cmd, split_cmd .. " " .. vim.fn.fnameescape(path))
    if split_cmd == "vsplit" then
        if ok then
            notify.info(state.lang.FILE_OPENED_VERTICAL or "File opened in vertical split")
        else
            notify.error(state.lang.FILE_OPEN_VERTICAL_FAILED or "Failed to open file in vertical split")
        end
    else
        if ok then
            notify.info(state.lang.FILE_OPENED_HORIZONTAL or "File opened in horizontal split")
        else
            notify.error(state.lang.FILE_OPEN_HORIZONTAL_FAILED or "Failed to open file in horizontal split")
        end
    end
end

---Resolve a picker item's path to an absolute path. The files picker emits paths relative to the cwd (fd
---`--strip-cwd-prefix`); lvim-space pins the cwd to the active project root, so `:p` absolutises correctly.
---@param item table|nil The confirmed/acted picker item (`{ path = <relative path> }`).
---@return string|nil abs Absolute path, or nil when the item carries none.
local function item_abs(item)
    if not (item and item.path and vim.trim(item.path) ~= "") then
        return nil
    end
    return vim.fn.fnamemodify(item.path, ":p")
end

---Open the file-search picker: the shared `:LvimPicker files` finder, embedded in lvim-space's zone. Requires
---an active project, workspace and tab (the same preconditions as the legacy panel). Releases any open
---lvim-space panel first so the picker takes the shared area zone cleanly.
---@param opts? { on_back?: fun() }  `on_back` re-opens the panel the search was launched from when the picker
---  is DISMISSED (Esc/abort with no selection), so the search behaves like a sub-panel you can step back out of.
M.init = function(opts)
    opts = opts or {}
    if not state.project_id then
        notify.error(state.lang.PROJECT_NOT_ACTIVE or "No active project")
        return
    end
    if not state.workspace_id then
        notify.error(state.lang.WORKSPACE_NOT_ACTIVE or "No active workspace")
        return
    end
    if not state.tab_active then
        notify.error(state.lang.TAB_NOT_ACTIVE or "No active tab")
        return
    end

    local picker_opts = {
        title = state.lang.SEARCH or "Search",
        layout = config.ui.mode,
        on_confirm = function(item)
            local abs = item_abs(item)
            if abs then
                select_file(abs)
            end
            if opts.on_back then
                opts.on_back()
            end
        end,
        -- Dismissed (Esc/abort, no pick) → step BACK to the panel the search was opened from. Run it
        -- SYNCHRONOUSLY: the picker's `finish` calls this inside a msgarea HANDOFF, so the picker's close and
        -- this panel re-open coalesce into one zone reflow (no flicker on the way back).
        on_cancel = opts.on_back and function()
            opts.on_back()
        end or nil,
        -- Split-open row actions. The picker binds these in the INSERT query prompt too, so they MUST be
        -- chord keys (a plain "v"/"h" would be swallowed while typing a query containing those letters) — the
        -- picker-idiomatic <C-v> / <C-x>. The panels keep their plain v/h (normal-mode, not a picker).
        keys = {
            {
                key = "<C-v>",
                name = "vsplit",
                run = function(item, close)
                    close()
                    open_in_split("vsplit", item_abs(item))
                end,
            },
            {
                key = "<C-x>",
                name = "hsplit",
                run = function(item, close)
                    close()
                    open_in_split("split", item_abs(item))
                end,
            },
            -- <BS> steps BACK to the launching panel — NORMAL mode only (`mode = "n"`), so insert-mode <BS> still
            -- edits the query. Reuses the same step-back path as a plain dismiss (close the picker, re-open the panel).
            {
                key = "<BS>",
                name = "back",
                mode = "n",
                run = function(_, close)
                    -- close + re-open SYNCHRONOUSLY: the picker's `fire` wraps this in a msgarea handoff, so the
                    -- two coalesce into one zone reflow (no flicker stepping back to the panel).
                    close()
                    if opts.on_back then
                        opts.on_back()
                    end
                end,
            },
        },
    }
    -- Swap the panel for the picker in ONE msgarea reflow (a "handoff") so the area zone never collapses
    -- between the close and the open — without it the editor flickers (the zone shrinks, then grows again).
    -- Off the area zone (float / bottom) there is nothing to coalesce, so just run it directly.
    local function open()
        ui.close_all() -- release any open panel so the picker takes the shared zone without stacking over it
        picker.files(picker_opts)
    end
    local ok_ma, msgarea = pcall(require, "lvim-msgarea")
    if ok_ma and msgarea.handoff and config.ui.mode == "area" and msgarea.is_enabled() then
        msgarea.handoff(open)
    else
        open()
    end
end

return M
