-- lvim-space.ui.search: file search, now a THIN ADAPTER over the shared lvim-utils PICKER (a fuzzy finder on
-- the same surface chassis as the panels). It docks in the configured zone (`config.ui.mode` → area | float |
-- bottom), honours the user's configured search command (`config.search`, an `fd …` invocation run in the
-- project root) as the candidate set, and shows the coloured ft devicon per row. ON SELECT it reuses the
-- existing data/session flow to open the file in the editor AND add it to the active tab (persisted) — the
-- exact behaviour of the old custom search panel. The split keys (`v` / `h`) open the selection in a
-- vertical / horizontal split. All the former 3-tier fuzzy-scoring + custom-window code is gone: the picker
-- owns matching (fzf in --filter mode, Lua fallback) and rendering.
--
---@module "lvim-space.ui.search"

local config = require("lvim-space.config")
local notify = require("lvim-space.api.notify")
local state = require("lvim-space.api.state")
local data = require("lvim-space.api.data")
local session = require("lvim-space.core.session")
local ui = require("lvim-space.ui")
local picker = require("lvim-utils.picker")

local M = {}

---Absolute path of the active project's root directory, or nil when no project is active.
---@return string|nil
local function project_path_abs()
    if not state.project_id then
        return nil
    end
    local proj = data.find_project_by_id(state.project_id)
    return proj and proj.path and vim.fn.fnamemodify(proj.path, ":p") or nil
end

---Resolve a (possibly relative) search-result path against the project root to an absolute path.
---@param rel string A path as emitted by the search command (relative to `cwd`, or already absolute).
---@param cwd string Absolute project root.
---@return string abs Absolute, normalised path.
local function absolutize(rel, cwd)
    local win32 = vim.fn.has("win32") == 1
    if vim.startswith(rel, "/") or vim.startswith(rel, "~") or (win32 and rel:match("^%a:[/\\]")) then
        return vim.fn.fnamemodify(rel, ":p")
    end
    local sep = win32 and "\\" or "/"
    return vim.fn.fnamemodify(cwd .. (cwd:match("[/\\]$") and "" or sep) .. rel, ":p")
end

---Run the configured `config.search` command in the project root and build the picker candidate items.
---Each item carries the relative path as its match/display `text` and the absolute `path` (the picker
---auto-renders the coloured ft devicon from `path`).
---@param cwd string Absolute project root.
---@return table[] items List of `{ text = relative_path, path = absolute_path }`.
local function collect_files(cwd)
    local shell_cmd = string.format("cd %s && %s", vim.fn.shellescape(cwd), config.search)
    local out = vim.fn.systemlist({ "sh", "-c", shell_cmd })
    local items = {}
    if vim.v.shell_error == 0 and type(out) == "table" then
        for _, rel in ipairs(out) do
            rel = vim.trim(rel)
            if rel ~= "" then
                items[#items + 1] = { text = rel, path = absolutize(rel, cwd) }
            end
        end
    end
    return items
end

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
        vim.api.nvim_set_current_win(target)
    else
        vim.cmd("edit " .. vim.fn.fnameescape(path))
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

---Open the file-search picker. Requires an active project, workspace and tab (the same preconditions as the
---legacy panel). Releases any open lvim-space panel first so the picker takes the shared area zone cleanly.
M.init = function()
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
    local cwd = project_path_abs()
    if not cwd then
        notify.error(state.lang.PROJECT_NOT_ACTIVE or "No active project")
        return
    end

    local fd_bin = (config.search or ""):match("^%S+") or "fd"
    if vim.fn.executable(fd_bin) ~= 1 then
        notify.error("lvim-space search requires '" .. fd_bin .. "' to be installed and on PATH.")
        return
    end

    -- Release any open panel so the picker docks in the (shared) area zone without stacking over it.
    ui.close_all()

    picker.open({
        title = state.lang.SEARCH or "Search",
        icon = config.ui.icons and config.ui.icons.file or nil,
        layout = config.ui.mode,
        items = collect_files(cwd),
        on_confirm = function(item)
            if item and item.path then
                select_file(item.path)
            end
        end,
        -- Split-open row actions. The picker binds these in the INSERT query prompt too, so they MUST be
        -- chord keys (a plain "v"/"h" would be swallowed while typing a query containing those letters) — the
        -- picker-idiomatic <C-v> / <C-x>. The panels keep their plain v/h (normal-mode, not a picker).
        keys = {
            {
                key = "<C-v>",
                name = "vsplit",
                run = function(item, close)
                    close()
                    open_in_split("vsplit", item and item.path)
                end,
            },
            {
                key = "<C-x>",
                name = "hsplit",
                run = function(item, close)
                    close()
                    open_in_split("split", item and item.path)
                end,
            },
        },
    })
end

return M
