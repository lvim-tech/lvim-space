-- lvim-space.ui: the UI CORE. Every entity panel (projects / workspaces / tabs / files / search) renders
-- through here. The list, the action/info bar and the input field are all drawn by the lvim-ui.surface
-- chassis — the ONE windowed-UI surface shared across every lvim-tech plugin — so lvim-space lives in the
-- same zone as the pickers and the lsp peek and self-themes from the lvim-utils palette.
--
-- Switching between the entity views (projects ⇄ workspaces ⇄ tabs ⇄ files) NEVER rebuilds the surface: it is
-- ONE chassis with four sets of content, so `open_main` refreshes the live panel in place (`swap_view`) and only
-- a first open / a dead panel / a dock-MODE change opens a new surface. That is what removes the panel flicker
-- and the hardware-cursor flash on a switch: both came from the teardown+rebuild (2 windows destroyed, 2-3
-- created, focus falling to the editor and `lvim-utils.cursor` restoring the cursor for ~16ms in between).
--
-- A configurable MODE (`config.ui.mode`, overridable for the session by the `:LvimSpace … area|bottom|float`
-- layout token — `M.set_mode`) chooses where the surface docks:
--   * "area"   — the Emacs-minibuffer cmdline zone (hosted in the msgarea when it is enabled, else it grows
--                cmdheight itself); the editor / heirline stay above it. The default.
--   * "float"  — a centred modal with a native border-title.
--   * "bottom" — a docked bar over the bottom rows.
--
-- The public surface kept STABLE for the panel modules: `open_main(lines, name, selected)` opens the list and
-- returns the REAL `(buf, win)` of the list block (so the panels keep setting their own a/d/r/Space/CR/K/J
-- keymaps + CursorMoved tracking + live `nvim_buf_set_lines` refresh on that buffer); `open_actions(line)`
-- fills the footer info bar; `create_input_field(prompt, default, cb)` asks for a name through Neovim's
-- command-line prompt or the lvim-ui popup (`config.ui.input`); `close_all()` tears the surface down
-- (releasing the msgarea host); `is_plugin_window(win)` is consulted by the session engine. `state.ui.content = { win, buf }` is the handle
-- the panels read. Cursor hiding is delegated to `lvim-utils.cursor` (panel_ft), never hand-rolled.
--
---@module "lvim-space.ui"

local config = require("lvim-space.config")
local state = require("lvim-space.api.state")
local lvim_cursor = require("lvim-utils.cursor")
local surface = require("lvim-ui.surface")
local lvim_ui = require("lvim-ui")
local uipreview = require("lvim-ui.preview")
local picker_source = require("lvim-picker.source")
local rows = require("lvim-space.ui.rows")
local keymaps = require("lvim-space.core.keymaps")

local api = vim.api

local M = {}

local ns_syntax = api.nvim_create_namespace("lvim_space_syntax")
---@type integer  the preview panel's own namespace (the "nothing to preview" placeholder tint)
local preview_ns = api.nvim_create_namespace("lvim_space_preview")

---How many lines of a file the preview reads. One screenful is plenty for a docked panel; the cap keeps a huge
---file from being read whole on every cursor move.
---@return integer
local function preview_lines()
    return math.max(50, vim.o.lines)
end

---@class LvimSpaceViewStore
---The LIVE view data every provider on the open surface renders from. ONE store per open surface, its
---fields rewritten in place when a VIEW is swapped (projects ⇄ workspaces ⇄ tabs ⇄ files) — which is why
---the providers can be built once, at open, and never rebuilt.
---@field lines string[]  The lines the list provider paints before the buffer takes over
---@field hls table[]  Provider highlight ops for those lines
---@field spans table[]  Per-row icon spans of the CURRENT lines
---@field initialized boolean  True once the surface is open (the provider then reads the live buffer)
---@field buf integer|nil  The list block's buffer (filled by the provider's `keys`)
---@field win integer|nil  The list block's window
---@field preview LvimSpacePreviewSpec|nil  The CURRENT view's preview spec (nil = this view has none)
---@field shown string|nil  The file path the preview currently renders (re-read only on a change)
---@field shown_h integer  Its line count — the preview's natural height

---@class LvimSpacePanelHandle
---@field state table  The live lvim-ui.surface state (`.close`, `.set_footer`, `.reposition`, …)
---@field buf integer  Buffer handle of the list content block
---@field win integer  Window handle of the list content block
---@field seg table|nil  The msgarea host segment (area mode, when the zone is enabled) — released on close
---@field mode "area"|"float"|"bottom"  The resolved dock mode this panel opened in
---@field title string|nil  The panel's current title text (kept in sync by `M.set_title`)
---@field count integer|nil  The panel's current item count, shown in the docked header bar's counter
---@field spans table[]|nil  The per-row icon spans of the CURRENT lines (re-rendered on every cursor move)
---@field list_pan table|nil  The list panel handle (`refresh()` re-renders it through the chassis)
---@field last_h integer  Row count the surface last fitted its height to — `set_rows` re-fits on a CRUD change
---@field set_spans (fun(spans: table[]))|nil  Hand the provider the spans of the lines just written
---@field augroup integer|nil  The row painter's CursorMoved group — destroyed with the panel
---@field preview (fun(): table|nil)|nil  The live preview panel handle (files view), or nil when there is none
---@field live LvimSpaceViewStore  The view store the providers read — rewritten in place by `swap_view`
---@field base_keys table<string, boolean>  The lhs set of the CHASSIS key layer (see `reset_view_keys`)

---The open list panel (nil while closed).
---@type LvimSpacePanelHandle|nil
local panel = nil

---@class LvimSpaceSavedState
---@field input_line integer|nil  Cursor row that was active when an input was opened

---@type LvimSpaceSavedState
local saved_state = {
    input_line = nil,
}

---@param win integer|nil Window handle to check
---@return boolean is_valid True when the handle is non-nil and refers to a valid window
local function is_valid_win(win)
    return win ~= nil and api.nvim_win_is_valid(win)
end

---@param buf integer|nil Buffer handle to check
---@return boolean is_valid True when the handle is non-nil and refers to a valid buffer
local function is_valid_buf(buf)
    return buf ~= nil and api.nvim_buf_is_valid(buf)
end

---Normalise a layout token, or nil when it is not one of the three dock modes.
---@param mode string|nil
---@return "area"|"float"|"bottom"|nil
local function valid_mode(mode)
    if mode == "area" or mode == "float" or mode == "bottom" then
        return mode
    end
    return nil
end

---Resolve the EFFECTIVE panel mode, in the canonical order: the SESSION override (a layout token typed on
---`:LvimSpace <sub> [area|bottom|float]`, which sticks for the rest of the session) → `config.ui.mode` →
---"area". Unknown values fall through to the default, so a typo can never leave the panel unopenable.
---@return "area"|"float"|"bottom" mode
local function panel_mode()
    return valid_mode(state.ui_mode_override) or valid_mode(config.ui.mode) or "area"
end

---Set (or clear) the SESSION layout override — the per-command `area` / `bottom` / `float` token. It
---survives panel re-opens for the rest of the session; a fresh session falls back to `config.ui.mode`.
---@param mode "area"|"float"|"bottom"|nil  nil clears the override
---@return boolean ok  False when `mode` is not a valid layout token (the override is left untouched)
M.set_mode = function(mode)
    if mode == nil then
        state.ui_mode_override = nil
        return true
    end
    local m = valid_mode(mode)
    if not m then
        return false
    end
    state.ui_mode_override = m
    return true
end

---The EFFECTIVE panel mode (override → config → default) — read by `:checkhealth` and the command layer.
---@return "area"|"float"|"bottom" mode
M.mode = function()
    return panel_mode()
end

---Return the lvim-utils msgarea module when the zone is enabled, else nil.
---@return table|nil msgarea
local function active_msgarea()
    local ok, m = pcall(require, "lvim-msgarea")
    if ok and m.is_enabled and m.is_enabled() then
        return m
    end
    return nil
end

---Apply a highlight group to a byte range on a single buffer line via extmarks.
---Kept for the search/fuzzy panels (which paint match ranges); the entity lists use winhighlight instead.
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

---@class LvimSpacePreviewSpec
---@field item fun(): { filename: string, lnum: integer?, col: integer? }|nil  The location under the cursor
---@field side "right"|"left"|"dynamic"|nil  Where the preview sits (default "right")
---@field width number|nil  Its share of the editor width (side = left/right; default 0.5)
---@field numbers boolean|nil  Line numbers in the preview (default true)
---@field empty string|nil  The "nothing to preview" placeholder text
---@field initial_path string|nil  The INITIAL selection's file path — pre-sizes the preview so the panel
--- reserves its full height on the first pass (no async grow / zone bounce). Resolved by the caller pre-open.

---Whether the surface carries a preview BLOCK at all. The block is built once, at open, for EVERY view —
---even the three that never show it — because a docked/parked preview can be swapped in place, while a
---block-set change cannot: that is what lets `swap_view` move between the files view and the others with
---zero window churn. `config.ui.preview.enabled = false` opts out entirely (no block, ever).
---@return boolean
local function preview_enabled()
    return ((config.ui or {}).preview or {}).enabled ~= false
end

---The side the preview docks on — the single configured position (`config.ui.preview.side`), constant
---across views.
---@return "right"|"left"
local function preview_side()
    local side = ((config.ui or {}).preview or {}).side
    return side == "left" and "left" or "right"
end

---The natural HEIGHT (line count) of the preview for `path` — read synchronously so the panel reserves the
---right number of rows in the SAME pass that docks the preview (an async grow would bounce the zone).
---@param path string|nil
---@return integer rows
local function preview_height(path)
    if type(path) ~= "string" or path == "" then
        return 1
    end
    local ok, lines = pcall(picker_source.read_preview, path, preview_lines())
    if ok and type(lines) == "table" and #lines > 0 then
        return #lines
    end
    return 1
end

---@class LvimSpacePanelSpec
---@field title string|nil  Panel title (float border-title / docked header bar)
---@field count integer|nil  Item count shown beside the title in the docked header bar (the picker's counter)
---@field lines string[]  Initial content lines
---@field hls table[]|nil  Provider highlight ops `{ row, col0, col_end, group, priority }`
---@field spans table[]|nil  Per-row icon spans from `ui.rows.line` (painted with the stripes/selection)
---@field preview LvimSpacePreviewSpec|nil  A preview block beside the list (the files view)
---@field selected integer|nil  1-based row to place the cursor on
---@field footer string|nil  Initial footer info text
---@field on_keys (fun(map: fun(lhs: string|string[], fn: function), pan: table, st: table))|nil  Extra panel keys
---@field on_close fun()|nil  Extra teardown run after the surface closes

---Close the open list panel (if any). The surface `on_close` releases the msgarea host + clears state.
local function close_panel()
    local p = panel
    if not p then
        return
    end
    panel = nil
    if p.state and p.state.close then
        pcall(p.state.close)
    end
    if state.ui then
        state.ui.content = nil
    end
end

---The 1-based cursor row of a window (1 when it is gone) — the SELECTED row of a list.
---@param win integer|nil
---@return integer
local function selected_row(win)
    if not (win and is_valid_win(win)) then
        return 1
    end
    local ok, cur = pcall(api.nvim_win_get_cursor, win)
    return (ok and cur[1]) or 1
end

---Repaint the open list after a panel rewrote its lines in place (stripes, the selection tint, the coloured
---icons — all extmarks, all wiped by `nvim_buf_set_lines`). The panels call this through `common`, never by
---hand-rolling their own highlighting.
---@param buf integer  the list buffer that was rewritten
---@param spans table[]|nil  the per-row icon spans the row renderer returned for the NEW lines
M.set_rows = function(buf, spans)
    if not (panel and panel.buf == buf) then
        return
    end
    panel.spans = spans or {}
    if panel.set_spans then
        panel.set_spans(panel.spans) -- the provider renders from these on its next paint
    end
    if panel.list_pan and panel.list_pan.refresh then
        panel.list_pan.refresh()
    end
    -- A CRUD op (add / delete) changes the row count: the in-place repaint above only rewrites the buffer,
    -- it does NOT re-reserve the zone — so a new row would be clipped by the old dock height. Re-fit the
    -- surface to the new content height ONLY when the count actually changed, so a plain selection-move
    -- repaint (same count) never triggers a zone reflow.
    local n = is_valid_buf(buf) and api.nvim_buf_line_count(buf) or nil
    if n and n ~= panel.last_h then
        panel.last_h = n
        if panel.state and panel.state.relayout then
            panel.state.relayout()
        end
    end
end

---Place the SELECTION and the SCROLL of the list window in ONE step.
---
---Setting only the cursor leaves the scroll to nvim, which paints the list from the top and THEN scrolls to
---bring the selected row into view — a visible re-scroll every time the active entity sits below the fold (a
---long files list, an active file 18 rows down a 16-row panel). The final topline is computable here (the
---selection, floored so the last screenful never leaves blank rows), so `winrestview` applies both at once
---and the panel's very first paint is already the final view.
---@param win integer|nil  the list window
---@param selected integer  1-based row to select
---@param total integer  row count of the list
local function set_view(win, selected, total)
    if not is_valid_win(win) then
        return
    end
    selected = math.max(1, math.min(selected, math.max(1, total)))
    local h = math.max(1, api.nvim_win_get_height(win))
    -- Scroll only when the selection would fall past the window's last row; then show the screenful that
    -- ENDS on it (never further, so the view keeps as much of the list above as fits).
    local top = math.max(1, math.min(selected - h + 1, math.max(1, total - h + 1)))
    api.nvim_win_call(win, function()
        vim.fn.winrestview({ topline = top, lnum = selected, col = 0, leftcol = 0, curswant = 0 })
    end)
end

---Bind the CHASSIS key layer of a panel buffer: the stray-typing suppression, `<Esc>` → close, and the
---cheatsheet chord. Everything here is view-INDEPENDENT — it is what a buffer carries before any entity
---panel binds its own actions, and what `reset_view_keys` restores when a view is swapped out.
---@param buf integer  the list buffer
local function bind_base_keys(buf)
    -- Suppress stray typing keys and bind <Esc> → close, exactly as the legacy panel did. The panel modules
    -- bind their own action keys AFTER open_main returns, overriding both these and the chassis defaults.
    keymaps.disable_all_maps(buf)
    keymaps.enable_base_maps(buf)
    -- The cheatsheet (`g?`), bound centrally so EVERY entity panel has it. The panel keys the modules bind
    -- afterwards are raw `vim.keymap.set`s the chassis never sees, so it cannot own the `g` chord prefix
    -- itself — `surface.own_chords` is the shared seam that does (without it a `g?` typed at human speed
    -- falls through to the builtin `g` once `timeoutlen` expires).
    local help_key = (config.keymappings and config.keymappings.action and config.keymappings.action.help) or nil
    if type(help_key) == "string" and help_key ~= "" then
        vim.keymap.set("n", help_key, function()
            require("lvim-space.ui.help").show()
        end, { buffer = buf, nowait = true, silent = true, desc = "lvim-space: keymap cheatsheet" })
        surface.own_chords(buf, { help_key })
    end
end

---The set of normal-mode lhs currently mapped on `buf`. Taken once, right after `bind_base_keys` at open,
---as the CHASSIS baseline (see `reset_view_keys`).
---@param buf integer
---@return table<string, boolean>
local function key_snapshot(buf)
    local set = {}
    if not is_valid_buf(buf) then
        return set
    end
    for _, m in ipairs(api.nvim_buf_get_keymap(buf, "n")) do
        set[m.lhs] = true
    end
    return set
end

---Strip the VIEW key layer from the shared panel buffer and restore the chassis baseline.
---
---The panel modules bind their action keys (`a`/`r`/`d`/`K`/`J`/`<CR>`/`<Space>`/`p`/`w`/`t`/`f`/`s`, the
---`/` filter, the footer button hotkeys) straight onto the list buffer. A rebuild used to throw that buffer
---away; an in-place view swap keeps it, so the outgoing view's keys would otherwise still fire — a `<CR>` on
---the workspaces list running the projects handler. Diffing against the OPEN-time snapshot is what makes
---this exact: every lhs the view added is deleted, and every baseline key the view overrode (the letters are
---`<Nop>` by default) is re-established by re-binding the base layer.
---@param buf integer
local function reset_view_keys(buf)
    if not (is_valid_buf(buf) and panel and panel.base_keys) then
        return
    end
    for _, m in ipairs(api.nvim_buf_get_keymap(buf, "n")) do
        if not panel.base_keys[m.lhs] then
            pcall(api.nvim_buf_del_keymap, buf, "n", m.lhs)
        end
    end
    bind_base_keys(buf)
end

---Build the single list content block + mode wiring and open the surface. Returns the real list block
---`(buf, win)` so the panel modules can keep operating directly on them.
---@param spec LvimSpacePanelSpec
---@return integer|nil buf
---@return integer|nil win
local function open_panel(spec)
    local mode = panel_mode()
    local msgarea = mode == "area" and active_msgarea() or nil
    -- The window lvim-space was entered from: filled in during the SWAP below (after the outgoing panel's
    -- close restores focus to it) and read lazily by `on_escape_above`. Sharing it through a table lets the
    -- cfg — built here, BEFORE the swap — reference an opener that is only known once the swap runs, so the
    -- panel teardown + re-open can coalesce into one zone reflow (no backdrop flicker on a panel change).
    local swap_ctx = {}

    -- The live VIEW store: the provider renders from it on first paint, then reads the panel buffer directly
    -- (the panels rewrite it on refresh) so a relayout / host reflow never clobbers their content. `swap_view`
    -- rewrites this SAME table when the user switches view, which is why the providers below are built once.
    ---@type LvimSpaceViewStore
    local list = {
        lines = spec.lines or {},
        hls = spec.hls or {},
        spans = spec.spans or {},
        initialized = false,
        preview = spec.preview,
        shown = nil,
        -- PRE-SIZE the preview from the INITIAL selection BEFORE the surface reserves the zone: else the panel
        -- reserves list-only height, then the first `update` reads the file and RELAYOUTS to grow — bouncing
        -- the zone (a `cmdheight` shudder of the editor above) on the way back from search. Only the line count
        -- is read here (`shown` stays nil, so the first `update` still renders the file — but with `shown_h`
        -- already correct, so it does NOT relayout). The picker sizes its preview synchronously the same way.
        shown_h = preview_height(spec.preview and spec.preview.initial_path),
    }
    ---@type table|nil, table|nil  the live panel handles (captured by each provider's `keys`)
    local list_pan, preview_pan
    ---@type table  the content-block provider
    local provider = {
        cursorline = false, -- the SELECTION is a row tint (see ui.rows), not a cursorline
        render = function()
            -- The rows and their look are ONE thing: whatever lines this panel currently holds, the highlight
            -- ops (stripes, the selected row, the active entity, the coloured icons) are rebuilt for them here.
            -- The chassis applies them right after it writes the lines, so a relayout / refresh repaints itself
            -- — painting them separately with extmarks lost them on the next render.
            local lines = (list.initialized and is_valid_buf(list.buf))
                    and api.nvim_buf_get_lines(list.buf, 0, -1, false)
                or list.lines
            return lines, rows.hls(#lines, list.spans, selected_row(list.win))
        end,
        -- Report the list's NATURAL content height (one row per item). The surface's auto-height clamps it to
        -- the central dock slot (`dock.slot(layout)` — float/bottom via the surface, area via the msgarea zone's
        -- reserve, which itself caps at `config.dock.geometry.area.height`), so the panel content-fits UP TO the
        -- one central height authority and grows exactly like the pickers — no self-cap of its own.
        size = function()
            local n = (list.initialized and is_valid_buf(list.buf)) and api.nvim_buf_line_count(list.buf) or #list.lines
            return nil, math.max(1, n)
        end,
        keys = function(map, pan, st)
            list.buf = pan.buf
            list.win = pan.win
            list_pan = pan
            if spec.on_keys then
                spec.on_keys(map, pan, st)
            end
        end,
    }

    -- The msgarea host: reserve our rows ABOVE the messages instead of growing cmdheight ourselves, and follow
    -- the zone as it reflows. A descend from the editor enters the list directly.
    local seg
    -- Forward-declared so `on_close` (defined in cfg below, BEFORE the panel is built) can delete the row
    -- painter's augroup. close_panel() nils the module `panel` before the surface teardown runs, so the old
    -- `panel.augroup` guard in on_close was always false → the augroup leaked one per panel open.
    local rows_group
    local host = msgarea
            and function(h)
                seg = msgarea.segment("lvim-space-host", { priority = 5 })
                seg:configure({
                    on_descend = function()
                        if panel and panel.win and is_valid_win(panel.win) then
                            api.nvim_set_current_win(panel.win)
                            lvim_cursor.update()
                        end
                        return true
                    end,
                })
                return seg:reserve(h, function(rect)
                    if panel and panel.state and panel.state.reposition then
                        panel.state.reposition(rect)
                    end
                end)
            end
        or nil

    -- The PREVIEW block: the file under the cursor, shown beside the list. It is built for EVERY view, not
    -- just the files one — a view WITHOUT a preview simply parks it (`state.set_preview_visible(false)`), so
    -- switching between the files view and the others swaps CONTENT instead of the block set, and no window is
    -- ever created or destroyed on a view change. It re-reads its location from the LIVE view store's
    -- `preview.item()` on every `refresh()`, which the list's CursorMoved fires — so it follows the cursor.
    local blocks = { { id = "list", provider = provider, border = surface.CONTENT_BORDER } }
    if preview_enabled() then
        -- A READ-ONLY SCRATCH preview — the picker's file preview, NOT `lvim-ui.preview` (the editable
        -- real-buffer one the LSP peek uses). A real buffer drags the FILE's own autocmds into this docked
        -- panel: showing it here fired the file's CursorMoved chain (LSP features, breadcrumbs, the lightbulb)
        -- inside a two-row window, and one of them blew up with `E36: Not enough room`. A scratch copy has no
        -- such wiring — and a panel preview should not be editable anyway.
        blocks[#blocks + 1] = {
            id = "preview",
            -- When the stack does not fit the cap, the PREVIEW is the panel that gives up rows — the chassis'
            -- own protection rule. So the LIST always keeps its content height and never jumps while you scroll
            -- through files of wildly different lengths, side by side or stacked.
            shrink_first = true,
            provider = {
                hide_cursor = true,
                -- The preview's share of the width, and its OWN natural height — the shown file's line count, in
                -- EVERY direction. The frame then fits the content of both panels (the taller one when they sit
                -- side by side, their sum when stacked) and the central `dock.geometry` cap clamps it — so the
                -- panel is never taller than the file it shows. `shrink_first` on this block means the PREVIEW is
                -- the one that gives up rows when that does not fit, so the LIST keeps its own content height and
                -- never shrinks/jumps as you scroll through files of wildly different lengths.
                size = function()
                    local w = tonumber(list.preview and list.preview.width) or 0.5
                    return math.max(20, math.floor(vim.o.columns * w)), math.max(1, list.shown_h)
                end,
                -- Re-read the file on the next paint. The chassis calls it when the preview is re-docked, and
                -- `swap_view` when a new view takes over the block — a view swap keeps the same scratch buffer,
                -- so without dropping `shown` the previous view's file would stay on screen.
                reset = function()
                    list.shown = nil
                end,
                update = function(pan)
                    local ps = list.preview
                    local it = ps and ps.item and ps.item() or nil
                    local path = it and it.filename or nil
                    if path == list.shown then
                        return
                    end
                    list.shown = path
                    if not path then
                        list.shown_h = 1
                        uipreview.render_empty(pan.buf, preview_ns, ps and ps.empty)
                        return
                    end
                    local lines, ft = picker_source.read_preview(path, preview_lines())
                    local prev_h = list.shown_h
                    list.shown_h = #lines
                    api.nvim_buf_clear_namespace(pan.buf, preview_ns, 0, -1)
                    uipreview.render_file(pan, lines, ft)
                    if pan.win and is_valid_win(pan.win) then
                        vim.wo[pan.win].number = (ps and ps.numbers) ~= false
                    end
                    -- Re-fit when the height this panel wants actually changed (a new file of a different
                    -- length): the frame re-fits to the two panels' content, and the list — protected by
                    -- `shrink_first` on this block — keeps its height through it.
                    if list.shown_h ~= prev_h then
                        local st = pan.frame
                        if st and st.relayout then
                            st.relayout()
                        end
                    end
                end,
                keys = function(_, pan)
                    preview_pan = pan
                end,
            },
            border = surface.CONTENT_BORDER,
        }
    end

    ---@type table  the live surface handle (forward-declared: `on_close` below identifies it by identity)
    local st
    local cfg = {
        mode = "float",
        position = (mode == "area" and "cmdline") or (mode == "bottom" and "bottom") or nil,
        host = host,
        zindex = (host and 210) or (mode == "area" and 200) or nil,
        -- Unified border model: ONE shared ring for every mode — the `surface.FRAME_BORDER` marker, which
        -- the chassis resolves live to `config.ui.border` (in lvim-utils) at open time, so a single config
        -- key re-borders lvim-space alongside every other lvim-tech panel. No per-mode / per-block border.
        border = surface.FRAME_BORDER,
        -- Title in the BORDER (the single title path): the chassis renders the native border-title — TITLE
        -- left + COUNT right on the top border row (default `counter="title"`) — and, for an AREA dock with
        -- `config.ui.title_line="statusline"`, publishes it to the chrome overlay instead (minibuffer style,
        -- so the heirline file segments give way to the panel title). The list block stays borderless.
        title = spec.title,
        -- nil → the chassis falls back to the CENTRAL `lvim-utils config.ui.title_line` (no local "border"
        -- override); set lvim-space's `config.ui.title_line` only to override per-plugin.
        title_line = config.ui.title_line,
        title_pos = config.ui.title_pos, -- nil → inherit central `config.ui.title_pos` (like title_line)

        count = spec.count,
        -- The counter reads "<row>/<total>" (item N of M) — the chassis tracks the list cursor as `current`.
        count_follows_cursor = true,
        -- Canon: +1 blank "air" row under the border-title (and the footer auto-adds one above its content).
        -- Keeps the list visually detached from the title row instead of butting up against the top border.
        header_air = true,
        -- No `size` here ON PURPOSE: the surface is the SOLE size resolver. With no `size`, it derives the OUTER
        -- slot geometry from the ONE central authority — `dock.slot(layout)` reading `config.dock.geometry` in
        -- lvim-utils (area/bottom full-width, float centred at its configured fraction; area's rows come from the
        -- msgarea zone's reserve). The panel then content-fits WITHIN that slot via the list provider's `size`.
        -- The list is a CONTENT data panel, so it carries the single-source content ring — `surface.CONTENT_BORDER`,
        -- resolved live to `config.ui.content_border` in lvim-utils at open time — independent of the container
        -- ring. The footer button bar below is a nav band (not a block) and stays borderless.
        content = { blocks = blocks },
        -- Where the preview sits beside the list — the chassis lays the blocks out along this axis. A view
        -- WITHOUT a preview opens the block PARKED (`"hide"`): the block exists but takes no room, and the
        -- first view that has one docks it on the configured side via `state.set_preview_visible`.
        preview_side = (#blocks > 1) and (spec.preview and preview_side() or "hide") or nil,
        footer = { bars = { { text = spec.footer or "", hl = "LvimSpaceInfo" } } },
        -- Sector navigation is the surface chassis default: <C-j> descends (list → footer bar → … messages),
        -- <C-k> ascends (footer → list → editor), exactly like the lvim-utils picker. The list keeps these for
        -- the chassis — entity REORDER lives on `K`/`J` (config.keymappings.action), NOT on <C-j>/<C-k> — so the
        -- navigable footer is reachable without a bespoke seam, while the list's j/k/a/d/r/Space/CR stay intact.
        -- From the footer, the menu keys (h/l) move along the buttons and <CR>/<Space> fire the focused button.
        close_keys = {}, -- <Esc> is bound by keymaps.enable_base_maps → close_all
        on_escape_above = function()
            if swap_ctx.opener and is_valid_win(swap_ctx.opener) then
                api.nvim_set_current_win(swap_ctx.opener)
            end
        end,
        on_escape_below = msgarea and function()
            return msgarea.focus_messages()
        end or nil,
        on_close = function()
            -- The row painter's cursor hook dies WITH the panel: a stale autocmd on a torn-down frame would
            -- keep firing (the buffer outlives the windows) and drive a layout that no longer exists. Use the
            -- closure local (not the module `panel`, already nil'd by close_panel by the time this runs).
            if rows_group then
                pcall(api.nvim_del_augroup_by_id, rows_group)
                rows_group = nil
            end
            if seg then
                pcall(function()
                    seg:release()
                end)
                seg = nil
            end
            -- The module handle must never outlive its frame: a frame torn down from OUTSIDE lvim-space (a
            -- `:q` on one of its windows, the chassis' own watch autocmd) does not go through `close_panel`,
            -- so without this the stale handle would answer "a panel is live" and `open_main` would try to
            -- swap a view into a dead surface. Identity-checked, so a handle already repointed at a NEWER
            -- surface (the rebuild path closes the old one after opening the new) is left alone.
            if panel and panel.state == st then
                panel = nil
                if state.ui then
                    state.ui.content = nil
                end
            end
            if spec.on_close then
                pcall(spec.on_close)
            end
        end,
    }

    -- Release the outgoing panel, open the incoming one AND finish its setup as ONE zone reflow (msgarea's
    -- lazyredraw + single flush), so the shared area zone and its PER-SURFACE backdrop never collapse-then-
    -- regrow between the two surfaces — the one-frame flicker on any panel change. `close_panel` runs FIRST
    -- inside the swap (its focus-restore is what `swap_ctx.opener` captures). EVERYTHING the panel needs to
    -- look finished — theme, filetype, the row painter, the keys and above all the SELECTION + scroll — runs
    -- inside the same batch: done after it, the surface has already painted once, so a list whose active row
    -- sits below the fold visibly re-scrolled into place. Off the area zone (no msgarea host) there is no
    -- shared zone to coalesce, so `build` runs directly.
    local buf, win
    local function build()
        close_panel()
        swap_ctx.opener = api.nvim_get_current_win()
        st = surface.open(cfg)
        local pan = st and st.panels and st.panels[1]
        if not (pan and is_valid_buf(pan.buf) and is_valid_win(pan.win)) then
            return
        end
        list.initialized = true
        buf, win = pan.buf, pan.win
        -- Self-theme the list window: the panel background. The SELECTION is not `cursorline` any more — the rows
        -- are striped and the selected row is a stronger tint of its stripe, painted by `ui.rows` (the picker's
        -- language; the hardware cursor is hidden in this panel, so a cursorline would be the only marker and it
        -- cannot stripe). `LvimSpaceCursorLine` stays mapped for a user who turns the stripes off.
        vim.wo[win].winhighlight = "Normal:LvimSpaceNormal,NormalNC:LvimSpaceNormal,CursorLine:LvimSpaceCursorLine"
        vim.wo[win].cursorline = not ((config.ui.rows or {}).stripes ~= false)
        vim.wo[win].signcolumn = "no"
        vim.wo[win].wrap = false
        -- The lvim-space filetype drives cursor hiding (registered as a current-only panel_ft in M.init) and lets
        -- other tooling recognise the panel.
        vim.bo[buf].filetype = config.ui.filetype or "lvim-space"

        state.ui = state.ui or {}
        state.ui.content = { win = win, buf = buf }

        panel = {
            state = st,
            buf = buf,
            win = win,
            seg = seg,
            mode = mode,
            title = spec.title,
            count = spec.count,
            spans = list.spans,
            list_pan = list_pan,
            -- Row count the surface last fitted its height to — `set_rows` re-fits when a CRUD op changes it.
            last_h = #(spec.lines or {}),
            set_spans = function(sp)
                list.spans = sp
            end,
            preview = function()
                return preview_pan
            end,
            -- The store the providers render from — `swap_view` rewrites it in place for the incoming view.
            live = list,
            base_keys = {},
        }

        -- ONE cursor hook for every view: repaint the selection (the row tint that replaces `cursorline`) and let
        -- the preview follow the cursor. Central here — not per panel module — so every entity list behaves the
        -- same and a module cannot forget it.
        rows_group = api.nvim_create_augroup("lvim_space_rows_" .. buf, { clear = true })
        panel.augroup = rows_group
        api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
            buffer = buf,
            group = rows_group,
            callback = function()
                -- Only while the user is actually ON the list. A CursorMoved also fires in this buffer while the
                -- panel is being TORN DOWN (closing, or handing the zone over to the search picker): the frame is
                -- half-dismantled by then, so driving a preview re-render from here tried to lay out a window that
                -- no longer has room (E36). The panel's own window being current is the precise "the user moved"
                -- signal; the augroup is destroyed with the panel besides (see cfg.on_close).
                if not (panel and panel.buf == buf and is_valid_win(win) and api.nvim_get_current_win() == win) then
                    return
                end
                if list_pan and list_pan.refresh then
                    list_pan.refresh() -- re-render → the selected row's tint follows the (hidden) cursor
                end
                local pv = preview_pan
                if pv and pv.refresh then
                    pv.refresh()
                end
            end,
        })

        bind_base_keys(buf)
        -- The CHASSIS key layer, snapshotted BEFORE any panel module binds its own: everything mapped on this
        -- buffer from here on belongs to the VIEW, and `reset_view_keys` strips exactly that on a view swap.
        panel.base_keys = key_snapshot(buf)

        -- The selection + scroll, SYNCHRONOUSLY and in one step (see `set_view`), before this batch's flush.
        set_view(win, spec.selected or 1, #list.lines)
        lvim_cursor.update()
    end

    if msgarea and msgarea.handoff then
        msgarea.handoff(build)
    else
        build()
    end
    if not (buf and win) then
        return nil, nil
    end
    return buf, win
end

---Swap the CONTENT of the live panel to a new view — the projects ⇄ workspaces ⇄ tabs ⇄ files switch — with
---NO teardown: the window, the buffer, the msgarea reserve, the backdrop, the border-title band and the
---chassis key layer all stay. Rebuilding the surface instead (`close_panel` + `surface.open`) is what made a
---switch destroy 2 windows and create 2-3, bounce focus panel → editor → panel and round-trip `guicursor`
---HIDDEN → visible → HIDDEN — i.e. the panel flicker AND the cursor flash, which are the same defect: with
---no intermediate state there is nothing to hide.
---
---Everything that is per-VIEW is replaced here, in one coalesced zone reflow: the key layer, the lines +
---their row spans, the title / counter, the footer band, the preview (docked for the files view, parked for
---the others — the block itself is never rebuilt) and the cursor row. The caller (the panel module) then
---binds its own keys and action footer on the SAME buffer, exactly as it does after a fresh open.
---@param spec LvimSpacePanelSpec
---@return integer|nil buf
---@return integer|nil win
local function swap_view(spec)
    local p = panel
    if not p then
        return nil, nil
    end
    local buf, win = p.buf, p.win
    local lines = spec.lines or {}

    local function apply()
        -- 1. The outgoing view's keys go, the chassis layer is restored — the incoming panel module binds
        --    its own on top, as after an open.
        reset_view_keys(buf)

        -- 2. The new rows, into the SAME buffer (the entity lists keep it non-modifiable between writes).
        local modifiable = vim.bo[buf].modifiable
        vim.bo[buf].modifiable = true
        pcall(api.nvim_buf_set_lines, buf, 0, -1, false, lines)
        vim.bo[buf].modifiable = modifiable

        -- 3. The selection + scroll, SYNCHRONOUSLY and in ONE step (never deferred on a switch — a deferred
        --    cursor set lands after the next keypress has already acted on the old row).
        local selected = math.max(1, math.min(spec.selected or 1, math.max(1, #lines)))
        set_view(win, selected, #lines)

        -- 4. The preview: the incoming view's spec, then dock or park the block. `shown_h` is pre-read from
        --    the initial selection so the re-fit below reserves the right rows in ONE pass.
        p.live.preview = spec.preview
        p.live.shown = nil
        if spec.preview then
            p.live.shown_h = preview_height(spec.preview.initial_path)
        end
        if p.state.set_preview_visible then
            p.state.set_preview_visible(spec.preview ~= nil, preview_side())
        end

        -- 5. Title + counter + the info footer (the panel module replaces the footer with its action bar).
        M.set_title(spec.title, spec.count)
        M.open_actions(spec.footer or "")

        -- 6. Repaint the rows (stripes / selection / icons) and re-fit the surface when the row count changed.
        M.set_rows(buf, spec.spans)

        -- 7. The view again, now that the panel has its FINAL height. Step 3 placed it while the window still
        --    had the OUTGOING view's height, so the topline it computed can be off (and `clamp_view`, run by
        --    the re-render, may have pulled it further); re-asserting against the fitted window makes the
        --    result identical to a fresh open — and it is still inside this batch, so it never paints twice.
        set_view(win, selected, #lines)

        -- 8. Focus: a switch driven from outside the panel (`:LvimSpace tabs` typed in the editor) must land
        --    in the list, exactly as a fresh open does.
        if api.nvim_get_current_win() ~= win and p.state.focus_block then
            p.state.focus_block("list")
        end
        lvim_cursor.update()
    end

    -- ONE zone reflow for the whole swap: the preview dock/park and the height re-fit both re-reserve the
    -- msgarea zone, and the handoff coalesces them into a single repaint (a no-op off the zone).
    surface.zone_handoff(apply)
    return buf, win
end

---Open (or reopen) the primary content panel showing a list of items.
---@param lines string[] Lines to display in the panel
---@param name string|nil Title shown in the panel (defaults to the configured title)
---@param selected_line integer|nil 1-based line to position the cursor on initially
---@param count integer|nil Item count shown beside the title in the docked header bar (e.g. the entity total)
---@param opts { spans: table[]|nil, preview: LvimSpacePreviewSpec|nil }|nil  Row spans + the preview block
---@return integer|nil buf Buffer handle of the list block
---@return integer|nil win Window handle of the list block
M.open_main = function(lines, name, selected_line, count, opts)
    lines = lines or {}
    opts = opts or {}
    if not selected_line then
        selected_line = (saved_state.input_line and saved_state.input_line <= #lines) and saved_state.input_line or 1
    end
    ---@type LvimSpacePanelSpec
    local spec = {
        title = name or config.ui.title or "LVIM SPACE",
        count = count,
        lines = lines,
        selected = selected_line,
        spans = opts.spans, -- the row renderer's per-row icon spans (painted with the stripes)
        preview = opts.preview, -- the files view's preview block ({ item, side, width, numbers, empty })
    }
    -- THE funnel every panel switch goes through. A LIVE panel in the SAME dock mode is REFRESHED in place —
    -- no window/buffer churn, no focus bounce, no cursor flash (see `swap_view`). Only a first open, a dead
    -- panel, or a MODE change (a `:LvimSpace tabs float` over a live area panel — a float cannot be
    -- content-swapped into the cmdline zone) rebuilds the surface.
    if panel and panel.mode == panel_mode() and is_valid_buf(panel.buf) and is_valid_win(panel.win) and panel.state then
        return swap_view(spec)
    end
    return open_panel(spec)
end

---Update the open panel's footer. Accepts either a ready `lvim-ui.bar` band model `{ bars = { … } }`
---(the entity panels' navigable action bar, assembled by `common.set_action_footer` through the shared
---`surface.button` spec builder) — rendered verbatim as a centred bar of buttons with red-dot separators +
---chevrons — or a plain string / `{ string }` (the error / guidance info lines), which renders as a simple
---text band. No-op when no panel is open.
---@param footer string|string[]|table  A `{ bars = … }` band model, or a text info line
M.open_actions = function(footer)
    if not (panel and panel.state and panel.state.set_footer) then
        return
    end
    local spec
    if type(footer) == "table" and footer.bars then
        spec = footer
    else
        local text = type(footer) == "table" and (footer[1] or "") or tostring(footer or "")
        spec = { bars = { { text = text, hl = "LvimSpaceInfo" } } }
    end
    panel.state.set_footer(spec)
end

---Update the open panel's title (and optionally its count) in place via the chassis' single title path —
---`state.set_title` re-renders the native border-title (or re-publishes the chrome overlay when
---`title_line="statusline"`), and `state.set_counter` updates the right-aligned count on the same border
---row. Used by `tabs` / `files` (and the other panels) to refresh a live title — e.g. the active workspace
---/ tab name — without tearing the surface down. The count is preserved unless a new `count` is given.
---No-op when no panel is open.
---@param text string New title text
---@param count integer|nil New item count for the border-title counter (keeps the current count when omitted)
M.set_title = function(text, count)
    if not panel then
        return
    end
    panel.title = text
    if count ~= nil then
        panel.count = count
    end
    if panel.state and panel.state.set_title then
        panel.state.set_title(text)
    end
    if count ~= nil and panel.state and panel.state.set_counter then
        panel.state.set_counter(count)
    end
end

---Ask for a single line of text for the add / rename actions. Presented as Neovim's command-line prompt
---(`config.ui.input == "cmd"`, the default — `vim.ui.input({ ui = "cmdline" })`, the lvim-hud external
---cmdline) or the centred, themed lvim-ui input popup (`"popup"`). The callback fires ONLY on confirm, with
---the typed value and the list row selected when the prompt opened (so the caller can restore the selection
---after the CRUD op); cancelling (Esc / Ctrl-C) does NOT invoke it.
---@param prompt string Label shown in the command-line prompt / popup title (a trailing colon is normalised away)
---@param default_value string|nil Pre-filled text
---@param callback fun(value: string, input_line: integer|nil) Called on confirm with the entered text and saved cursor line
---@param completion string|nil A `getcompletion()` kind ("dir", "file", …) enabling <Tab> completion in the
---       field. A prompt that asks for a PATH is unusable without it — you would have to type the whole thing
---       by hand, in the one place in the editor where <Tab> does nothing. Both input modes take it: the
---       lvim-ui popup completes in place (longest common prefix, then lists), and the cmdline prompt gets
---       Neovim's own path completion.
function M.create_input_field(prompt, default_value, callback, completion)
    -- Remember the list cursor row so the callback can restore selection after a CRUD op.
    local input_line
    if panel and is_valid_win(panel.win) then
        input_line = api.nvim_win_get_cursor(panel.win)[1]
    end
    saved_state.input_line = input_line

    -- "Workspace Name:" → "Workspace Name" — the command-line prompt / popup title add their own separator.
    local label = tostring(prompt or ""):gsub("%s*:%s*$", "")

    local function resolve(value)
        if type(callback) ~= "function" then
            return
        end
        -- Defer the CRUD op so the prompt's own teardown starts settling first, then defer ONE more tick to
        -- RE-FIT the (possibly rebuilt) panel. A CRUD rebuild (`M.init` — delete / rename) positions the docked
        -- area float while the input's ASYNC teardown and the result notify are still reflowing the zone, so it
        -- lands one row too high — covering the global statusline and leaving an empty band below. A settled
        -- `relayout` (same re-fit a VimResized would do) drops the panel back onto the zone. No-op when the CRUD
        -- op closed the panel (guarded on a live window).
        vim.schedule(function()
            callback(value, input_line)
            vim.schedule(function()
                if panel and panel.state and panel.state.relayout and is_valid_win(panel.win) then
                    panel.state.relayout()
                end
            end)
        end)
    end

    if config.ui.input == "popup" then
        -- The canonical centred, themed lvim-ui input popup.
        lvim_ui.input({
            title = label,
            default = default_value,
            completion = completion,
            callback = function(confirmed, value)
                if confirmed then
                    resolve(value or "")
                end
            end,
        })
    else
        -- Neovim's command-line prompt. `ui = "cmdline"` pins it to the lvim-hud external cmdline explicitly,
        -- so the mode is deterministic regardless of the hud's own `input.default` (which may be "popup").
        vim.ui.input({
            prompt = label .. ": ",
            default = default_value,
            completion = completion,
            ui = "cmdline",
        }, function(val)
            if val ~= nil then
                resolve(val)
            end
        end)
    end
end

---Check whether a window belongs to one of the plugin's managed windows. The session engine consults this
---to skip plugin UI when scanning / restoring editor windows. Every lvim-utils surface window carries the
---`w:lvim_frame` mark, so the panel + header/footer band windows are all recognised.
---@param win integer Window handle to test
---@return boolean is_plugin_window True when `win` is owned by lvim-space (or any lvim-utils frame)
M.is_plugin_window = function(win)
    if win and api.nvim_win_is_valid(win) and vim.w[win].lvim_frame then
        return true
    end
    if state.ui and state.ui.content and state.ui.content.win == win then
        return true
    end
    return false
end

---Initialise the UI subsystem. Registers the lvim-space filetype as a current-only panel for cursor hiding
---(the canonical lvim-utils.cursor mechanism — no hand-rolled guicursor). No auto-close autocmd: a docked
---surface stays put until an explicit `close_all` (every flow that leaves the panel calls it directly).
M.init = function()
    state.disable_auto_close = false
    -- Self-register our panel filetype via `register` (the CLAUDE.md canon): it EXTENDS the shared cursor
    -- registry (deduped) without rebuilding the shared autocmds, unlike `setup` which a plugin should not
    -- drive.
    lvim_cursor.register({
        panel_ft = {
            config.ui.filetype or "lvim-space",
        },
    })
end

---Close every window managed by the plugin (the list panel), releasing the msgarea host and clearing the
---`state.ui` handles.
M.close_all = function()
    close_panel()
    state.ui = state.ui or {}
    state.ui.content = nil
    state.ui.status_line = nil
end

return M
