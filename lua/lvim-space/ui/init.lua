-- lvim-space.ui: the UI CORE. Every entity panel (projects / workspaces / tabs / files / search) renders
-- through here. The list, the action/info bar and the input field are all drawn by the lvim-utils.ui.surface
-- chassis — the ONE windowed-UI surface shared across every lvim-tech plugin — so lvim-space lives in the
-- same zone as the pickers and the lsp peek and self-themes from the lvim-utils palette.
--
-- A configurable MODE (`config.ui.mode`) chooses where the surface docks:
--   * "area"   — the Emacs-minibuffer cmdline zone (hosted in the msgarea when it is enabled, else it grows
--                cmdheight itself); the editor / heirline stay above it. The default.
--   * "float"  — a centred modal with a native border-title.
--   * "bottom" — a docked bar over the bottom rows.
--
-- The public surface kept STABLE for the panel modules: `open_main(lines, name, selected)` opens the list and
-- returns the REAL `(buf, win)` of the list block (so the panels keep setting their own a/d/r/Space/CR/K/J
-- keymaps + CursorMoved tracking + live `nvim_buf_set_lines` refresh on that buffer); `open_actions(line)`
-- fills the footer info bar; `create_input_field(prompt, default, cb)` opens an in-zone prompt; `close_all()`
-- tears the surface down (releasing the msgarea host); `submit_input` / `cancel_input` resolve the prompt;
-- `is_plugin_window(win)` is consulted by the session engine. `state.ui.content = { win, buf }` is the handle
-- the panels read. Cursor hiding is delegated to `lvim-utils.cursor` (panel_ft), never hand-rolled.
--
---@module "lvim-space.ui"

local config = require("lvim-space.config")
local state = require("lvim-space.api.state")
local lvim_cursor = require("lvim-utils.cursor")
local surface = require("lvim-utils.ui.surface")
local keymaps = require("lvim-space.core.keymaps")

local api = vim.api

local M = {}

local ns_syntax = api.nvim_create_namespace("lvim_space_syntax")

---@class LvimSpacePanelHandle
---@field state table  The live lvim-utils.ui.surface state (`.close`, `.set_footer`, `.reposition`, …)
---@field buf integer  Buffer handle of the list content block
---@field win integer  Window handle of the list content block
---@field seg table|nil  The msgarea host segment (area mode, when the zone is enabled) — released on close
---@field mode "area"|"float"|"bottom"  The resolved dock mode this panel opened in
---@field title string|nil  The panel's current title text (kept in sync by `M.set_title`)
---@field count integer|nil  The panel's current item count, shown in the docked header bar's counter

---@class LvimSpaceInputHandle
---@field state table|nil  The live surface state of the input prompt
---@field buf integer|nil  Buffer handle of the editable input band
---@field callback fun(value: string|nil, input_line: integer|nil)|nil  Resolved on submit
---@field input_line integer|nil  Cursor row of the list when the prompt opened

---The open list panel (nil while closed).
---@type LvimSpacePanelHandle|nil
local panel = nil

---The open input prompt (nil while no prompt is active).
---@type LvimSpaceInputHandle|nil
local input = nil

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

---Resolve the configured panel mode, defaulting to "area" for any unknown value.
---@return "area"|"float"|"bottom" mode
local function panel_mode()
    local mode = config.ui.mode
    if mode == "float" or mode == "bottom" then
        return mode
    end
    return "area"
end

---Return the lvim-utils msgarea module when the zone is enabled, else nil.
---@return table|nil msgarea
local function active_msgarea()
    local ok, m = pcall(require, "lvim-utils.msgarea")
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

---@class LvimSpacePanelSpec
---@field title string|nil  Panel title (float border-title / docked header bar)
---@field count integer|nil  Item count shown beside the title in the docked header bar (the picker's counter)
---@field lines string[]  Initial content lines
---@field hls table[]|nil  Provider highlight ops `{ row, col0, col_end, group, priority }`
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

---Close the active input prompt (if any).
local function close_input()
    local inp = input
    if not inp then
        return
    end
    input = nil
    if api.nvim_get_mode().mode:match("i") then
        pcall(vim.cmd, "stopinsert")
    end
    if inp.state and inp.state.close then
        pcall(inp.state.close)
    end
end

---Build the single list content block + mode wiring and open the surface. Returns the real list block
---`(buf, win)` so the panel modules can keep operating directly on them.
---@param spec LvimSpacePanelSpec
---@return integer|nil buf
---@return integer|nil win
local function open_panel(spec)
    close_panel()

    local mode = panel_mode()
    local msgarea = mode == "area" and active_msgarea() or nil
    local opener = api.nvim_get_current_win()
    local max_h = config.ui.max_height or 10

    -- The live list store: the provider renders from it on first paint, then reads the panel buffer directly
    -- (the panels rewrite it on refresh) so a relayout / host reflow never clobbers their content.
    local list = { lines = spec.lines or {}, hls = spec.hls or {}, initialized = false }
    ---@type table  the content-block provider
    local provider = {
        render = function()
            if list.initialized and is_valid_buf(list.buf) then
                return api.nvim_buf_get_lines(list.buf, 0, -1, false), list.hls
            end
            return list.lines, list.hls
        end,
        size = function()
            local n = (list.initialized and is_valid_buf(list.buf)) and api.nvim_buf_line_count(list.buf) or #list.lines
            return nil, math.max(1, math.min(n, max_h))
        end,
        keys = function(map, pan, st)
            list.buf = pan.buf
            list.win = pan.win
            if spec.on_keys then
                spec.on_keys(map, pan, st)
            end
        end,
    }

    -- The msgarea host: reserve our rows ABOVE the messages instead of growing cmdheight ourselves, and follow
    -- the zone as it reflows. A descend from the editor enters the list directly.
    local seg
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

    local docked = mode ~= "float"
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
        size = {
            -- AREA dock (hosted): leave the CONTAINER cap wide open so the panel grows like the pickers do — the
            -- msgarea zone (`Handle:reserve`) clamps every docked float to its `max_height`, the single height
            -- authority, so the panels line up instead of this one self-capping lower and squeezing its list.
            -- FLOAT / BOTTOM (no host): `max_h` stays the real cap.
            height = { auto = true, max = host and 9999 or max_h, min = 1 },
            width = (not docked) and { auto = true, max = 0.8, min = 30 } or nil,
        },
        -- The list is a CONTENT data panel, so it carries the single-source content ring — `surface.CONTENT_BORDER`,
        -- resolved live to `config.ui.content_border` in lvim-utils at open time — independent of the container
        -- ring. The footer button bar below is a nav band (not a block) and stays borderless.
        content = { blocks = { { id = "list", provider = provider, border = surface.CONTENT_BORDER } } },
        footer = { bars = { { text = spec.footer or "", hl = "LvimSpaceInfo" } } },
        -- Sector navigation is the surface chassis default: <C-j> descends (list → footer bar → … messages),
        -- <C-k> ascends (footer → list → editor), exactly like the lvim-utils picker. The list keeps these for
        -- the chassis — entity REORDER lives on `K`/`J` (config.keymappings.action), NOT on <C-j>/<C-k> — so the
        -- navigable footer is reachable without a bespoke seam, while the list's j/k/a/d/r/Space/CR stay intact.
        -- From the footer, the menu keys (h/l) move along the buttons and <CR>/<Space> fire the focused button.
        close_keys = {}, -- <Esc> is bound by keymaps.enable_base_maps → close_all
        on_escape_above = function()
            if is_valid_win(opener) then
                api.nvim_set_current_win(opener)
            end
        end,
        on_escape_below = msgarea and function()
            return msgarea.focus_messages()
        end or nil,
        on_close = function()
            if seg then
                pcall(function()
                    seg:release()
                end)
                seg = nil
            end
            if spec.on_close then
                pcall(spec.on_close)
            end
        end,
    }

    local st = surface.open(cfg)
    local pan = st and st.panels and st.panels[1]
    if not (pan and is_valid_buf(pan.buf) and is_valid_win(pan.win)) then
        return nil, nil
    end
    list.initialized = true

    local buf, win = pan.buf, pan.win
    -- Self-theme the list window: the panel background + a full-row active-line tint, the lvim-space way.
    vim.wo[win].winhighlight = "Normal:LvimSpaceNormal,NormalNC:LvimSpaceNormal,CursorLine:LvimSpaceCursorLine"
    vim.wo[win].cursorline = true
    vim.wo[win].signcolumn = "no"
    vim.wo[win].wrap = false
    -- The lvim-space filetype drives cursor hiding (registered as a current-only panel_ft in M.init) and lets
    -- other tooling recognise the panel.
    vim.bo[buf].filetype = config.ui.filetype or "lvim-space"

    state.ui = state.ui or {}
    state.ui.content = { win = win, buf = buf }

    panel = { state = st, buf = buf, win = win, seg = seg, mode = mode, title = spec.title, count = spec.count }

    -- Suppress stray typing keys and bind <Esc> → close, exactly as the legacy panel did. The panel modules
    -- bind their own action keys AFTER open_main returns, overriding both these and the chassis defaults.
    keymaps.disable_all_maps(buf)
    keymaps.enable_base_maps(buf)

    local selected = spec.selected or 1
    selected = math.max(1, math.min(selected, math.max(1, #list.lines)))
    vim.schedule(function()
        if is_valid_win(win) then
            pcall(api.nvim_win_set_cursor, win, { selected, 0 })
            lvim_cursor.update()
        end
    end)

    return buf, win
end

---Open (or reopen) the primary content panel showing a list of items.
---@param lines string[] Lines to display in the panel
---@param name string|nil Title shown in the panel (defaults to the configured title)
---@param selected_line integer|nil 1-based line to position the cursor on initially
---@param count integer|nil Item count shown beside the title in the docked header bar (e.g. the entity total)
---@return integer|nil buf Buffer handle of the list block
---@return integer|nil win Window handle of the list block
M.open_main = function(lines, name, selected_line, count)
    lines = lines or {}
    if not selected_line then
        selected_line = (saved_state.input_line and saved_state.input_line <= #lines) and saved_state.input_line or 1
    end
    return open_panel({
        title = name or config.ui.title or "LVIM SPACE",
        count = count,
        lines = lines,
        selected = selected_line,
    })
end

-- Footer button style: lvim-space's OWN, user-overridable groups (defined in config/highlights.lua),
-- NOT the internal LvimUiFooter* of lvim-utils — so the user can recolour the footer from lvim-space's
-- config exactly like the other LvimSpace* groups. The KEY box uses the blue tint, the LABEL box the
-- yellow tint, and the hover variants the stronger tints.
local FOOTER_STYLE = {
    icon = {
        padding = { 1, 1 },
        normal = "LvimSpaceFooterKey",
        active = "LvimSpaceFooterKey",
        hover = "LvimSpaceFooterKeyHover",
        hover_active = "LvimSpaceFooterKeyHover",
    },
    text = {
        padding = { 1, 1 },
        normal = "LvimSpaceFooterLabel",
        active = "LvimSpaceFooterLabel",
        hover = "LvimSpaceFooterLabelHover",
        hover_active = "LvimSpaceFooterLabelHover",
    },
}

-- The group separator (our defined RED DOT) and the ❮/❯ overflow chevrons, all on the overridable
-- LvimSpaceFooterSep group.
local FOOTER_SEP = "LvimSpaceFooterSep"

---Assemble a navigable `lvim-utils.ui.bar` footer spec from a list of button GROUPS — modelled on the
---lvim-utils `ui.tabs` / picker footer: each group is a list of footer button shorthands
---`{ key, name, run, no_hotkey? }`; consecutive (non-empty) groups are joined by a `●` red-dot separator,
---the bar is centred, and `❮`/`❯` chevrons appear on overflow. Every button carries the lvim-space
---FOOTER_STYLE so it paints from the overridable LvimSpaceFooter* groups.
---@param groups table[][]  List of button groups (each a list of `{ key, name, run, no_hotkey? }`)
---@return table footer  A `{ bars = { { items, align, chevrons } } }` footer spec
local function footer_bar(groups)
    local items = {}
    for _, group in ipairs(groups) do
        if #group > 0 then
            if #items > 0 then
                items[#items + 1] =
                    { type = "separator", text = "●", style = { padding = { 1, 1 }, hl = FOOTER_SEP } }
            end
            for _, it in ipairs(group) do
                items[#items + 1] = {
                    key = it.key,
                    name = it.name,
                    run = it.run,
                    no_hotkey = it.no_hotkey,
                    style = FOOTER_STYLE,
                }
            end
        end
    end
    return {
        bars = {
            {
                items = items,
                align = "center",
                chevrons = {
                    left = { text = "❮", style = { hl = FOOTER_SEP } },
                    right = { text = "❯", style = { hl = FOOTER_SEP } },
                },
            },
        },
    }
end

---Update the open panel's footer. Accepts either a navigable button model `{ groups = { … } }` (the entity
---panels' action bar, built by `common.set_action_footer`) — rendered as a centred `ui.bar` of buttons with
---red-dot separators + chevrons — or a plain string / `{ string }` (the error / guidance info lines), which
---renders as a simple text band. No-op when no panel is open.
---@param footer string|string[]|table  A `{ groups = … }` button model, or a text info line
M.open_actions = function(footer)
    if not (panel and panel.state and panel.state.set_footer) then
        return
    end
    local spec
    if type(footer) == "table" and footer.groups then
        spec = footer_bar(footer.groups)
    elseif type(footer) == "table" and footer.bars then
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

---Open an in-zone input prompt. Pressing `<CR>` resolves it (calls `callback(value, input_line)`); `<Esc>`
---cancels (the callback is NOT invoked, matching the legacy behaviour). Works in every panel mode.
---@param prompt string Label displayed in the prompt badge
---@param default_value string|nil Pre-filled text for the input field
---@param callback fun(value: string|nil, input_line: integer|nil) Called on submit with the entered text and saved cursor line
---@param options table|nil Optional overrides (`input_filetype`)
---@return integer|nil buf Buffer handle of the input field, or nil on failure
function M.create_input_field(prompt, default_value, callback, options)
    options = options or {}
    close_input()

    -- Remember the list cursor row so the callback can restore selection after a CRUD op.
    local input_line
    if panel and is_valid_win(panel.win) then
        input_line = api.nvim_win_get_cursor(panel.win)[1]
    end
    saved_state.input_line = input_line

    local mode = panel_mode()
    local msgarea = mode == "area" and active_msgarea() or nil
    -- The prompt label reads "<prompt>: " — a literal colon, the lvim-space prompt convention.
    local separator = ":"
    local docked = mode ~= "float"

    local seg
    local host = msgarea
            and function(h)
                seg = msgarea.segment("lvim-space-input-host", { priority = 6 })
                return seg:reserve(h, function(rect)
                    if input and input.state and input.state.reposition then
                        input.state.reposition(rect)
                    end
                end)
            end
        or nil

    ---@type LvimSpaceInputHandle
    local inp = { callback = callback, input_line = input_line }

    local cfg = {
        mode = "float",
        position = (mode == "area" and "cmdline") or (mode == "bottom" and "bottom") or nil,
        host = host,
        zindex = (host and 215) or (mode == "area" and 205) or nil,
        -- Same unified ring as the list panel — the shared `config.ui.border` via the chassis marker.
        border = surface.FRAME_BORDER,
        header_air = false,
        size = {
            height = { auto = true, max = 3, min = 1 },
            width = (not docked) and { auto = true, max = 0.8, min = 30 } or nil,
        },
        content = { blocks = {} },
        header = {
            bars = {
                {
                    input = true,
                    prompt = " " .. prompt .. separator .. " ",
                    prompt_hl = "LvimSpacePrompt",
                    input_hl = "LvimSpaceInput",
                    filetype = options.input_filetype or "lvim-space-input",
                    keys = function(buf, st)
                        inp.buf = buf
                        inp.state = st
                        -- Keep the hardware cursor VISIBLE here (the user types) even though the panel ft hides it.
                        lvim_cursor.mark_input_buffer(buf, true)
                        if default_value and default_value ~= "" then
                            api.nvim_buf_set_lines(buf, 0, 1, false, { default_value })
                        end
                        local function imap(lhs, fn)
                            vim.keymap.set("i", lhs, fn, { buffer = buf, nowait = true, silent = true })
                        end
                        imap("<CR>", function()
                            M.submit_input()
                        end)
                        imap("<Esc>", function()
                            M.cancel_input()
                        end)
                        imap("<C-c>", function()
                            M.cancel_input()
                        end)
                    end,
                },
            },
        },
        close_keys = {},
        on_close = function()
            if seg then
                pcall(function()
                    seg:release()
                end)
                seg = nil
            end
        end,
    }

    inp.state = surface.open(cfg)
    input = inp
    return inp.buf
end

---Submit the active input prompt: read the field, close it, and schedule the stored callback.
function M.submit_input()
    local inp = input
    if not inp then
        return
    end
    local value = ""
    if is_valid_buf(inp.buf) then
        value = api.nvim_buf_get_lines(inp.buf, 0, 1, false)[1] or ""
    end
    local callback, input_line = inp.callback, inp.input_line
    close_input()
    if panel and is_valid_win(panel.win) then
        api.nvim_set_current_win(panel.win)
        lvim_cursor.update()
    end
    if type(callback) == "function" then
        vim.schedule(function()
            callback(value, input_line)
        end)
    end
end

---Cancel the active input prompt without invoking the callback; return focus to the list.
function M.cancel_input()
    close_input()
    if panel and is_valid_win(panel.win) then
        api.nvim_set_current_win(panel.win)
        lvim_cursor.update()
    end
end

---Check whether a window belongs to one of the plugin's managed windows. The session engine consults this
---to skip plugin UI when scanning / restoring editor windows. Every lvim-utils surface window carries the
---`w:lvim_frame` mark, so the panel + input + header/footer band windows are all recognised.
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
    lvim_cursor.setup({
        panel_ft = {
            config.ui.filetype or "lvim-space",
        },
    })
end

---Close every window managed by the plugin (the input prompt and the list panel), releasing the msgarea
---host and clearing the `state.ui` handles.
M.close_all = function()
    close_input()
    close_panel()
    state.ui = state.ui or {}
    state.ui.content = nil
    state.ui.status_line = nil
    state.ui.prompt_window = nil
    state.ui.input_window = nil
end

return M
