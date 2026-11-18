-- lvim-space.ui.rows: THE one row renderer for every lvim-space list — projects, workspaces, tabs, files and
-- the search results all go through here, so they read exactly like a lvim-picker list.
--
-- A row is `<space><icon><text><space>`. The ICON is the entity glyph (`config.ui.icons.<type>[_active]`) for
-- every entity EXCEPT a file, which gets a real FILETYPE devicon in its own colour (the picker's language) —
-- resolved through the shared `lvim-utils.icons` provider, so it follows the same icon provider / colour mode
-- as every other lvim-tech list. A file's ACTIVE state can no longer live in the glyph (the glyph is now the
-- filetype's), so it moves to the row TEXT: the active row is painted with the accent (`hl.active`).
--
-- The row LOOK is not just the text: the picker stripes its rows odd/even and paints the SELECTED row with a
-- stronger tint of the same accent instead of relying on `cursorline` (the cursor is hidden in these panels).
-- `M.hls` builds those highlight ops in the CHASSIS format, and the list PROVIDER returns them from its
-- `render` — so the surface applies them on every render it does. They must not be painted on the side: a
-- relayout rewrites the panel's lines and wipes any foreign extmark.
--
---@module "lvim-space.ui.rows"

local config = require("lvim-space.config")
local iconlib = require("lvim-utils.icons")

local M = {}

--- The row style config, with the defaults applied. Kept as a function (not a module-level local) so a
--- runtime `setup()` merge — or a theme swap that renames a group — is picked up on the next paint.
---@return { stripes: boolean, devicons: boolean, hl: table<string, string> }
local function rowcfg()
    local ui = config.ui or {}
    local r = ui.rows or {}
    local h = r.hl or {}
    return {
        stripes = r.stripes ~= false,
        devicons = ui.devicons ~= false,
        hl = {
            -- The picker's OWN list groups by default, so lvim-space and the pickers stay one look under any
            -- theme; override any of them in `config.ui.rows.hl` to steer lvim-space alone.
            odd = h.odd or "LvimUiMsgAreaRowOdd",
            even = h.even or "LvimUiMsgAreaRowEven",
            sel_odd = h.sel_odd or "LvimUiMsgAreaSelOdd",
            sel_even = h.sel_even or "LvimUiMsgAreaSelEven",
            active = h.active or "LvimSpaceActiveRow",
        },
    }
end

--- A UI glyph (`"<glyph>"` + optional blanks) as lvim-icons shows it: in "material" mode its 2-cell image + the
--- image's group (its fg IS the image id, so it must be painted over the row's own fg); otherwise the glyph
--- unchanged and nil. `drop_blank`: the image is one cell wider than the glyph, so one blank after it is dropped
--- where the glyph sits in a column that has to stay aligned.
---@param icon string
---@param hl string|nil       the group whose colour the image takes (nil = Normal)
---@param drop_blank boolean|nil
---@return string text, string|nil img_hl
function M.image_cells(icon, hl, drop_blank)
    local t, h, img = iconlib.ui_text(icon, hl)
    if not img then
        return icon, nil
    end
    if drop_blank and t:sub(-1) == " " then
        t = t:sub(1, -2)
    end
    return t, h
end

--- The icon for one row: a filetype DEVICON (with its own highlight) for a file, else the entity glyph.
--- Returns the glyph plus the highlight to paint it with (nil = inherit the row's stripe colour).
---@param type_name string   entity type ("project" | "workspace" | "tab" | "file")
---@param active boolean     is this the active entity
---@param path string|nil    the file path (file rows only — the devicon is resolved from it)
---@return string glyph, string|nil hl
function M.icon(type_name, active, path)
    local common = require("lvim-space.ui.common") -- required here: common requires this module back
    if type_name == "file" and rowcfg().devicons and path and path ~= "" then
        local r = iconlib.get(path, {
            provider = (config.ui or {}).icon_provider,
            color_mode = (config.ui or {}).icon_color_mode,
        })
        if r and r.glyph and r.glyph ~= "" then
            return r.glyph .. " ", r.hl
        end
    end
    local glyph = common.get_entity_icon(type_name, active, false)
    if type_name ~= "file" then
        -- the entity glyph is a UI icon: an image in "material" mode, in the row's colour
        local cfg = rowcfg()
        local t, img_hl = M.image_cells(glyph, active and cfg.hl.active or cfg.hl.odd, true)
        if img_hl then
            return t, img_hl
        end
    end
    return glyph, nil
end

--- Build ONE list row + the span its icon occupies (byte columns, for the colour extmark).
---@param text string        the row's text (already formatted by the panel)
---@param type_name string   entity type
---@param active boolean     is this the active entity
---@param path string|nil    file path (file rows)
---@return string line, { c0: integer, c1: integer, hl: string|nil } span
function M.line(text, type_name, active, path)
    local glyph, ghl = M.icon(type_name, active, path)
    -- A REMOTE project's mark leads its text (`projects.format_project`): a UI icon too, so in "material" mode
    -- it becomes an image with its own span. Done here, not in the formatter, because the formatter's text
    -- also feeds the filter picker, which must keep the plain glyph.
    local mark_span
    if type_name == "project" then
        local mark = ((config.ui or {}).icons or {}).project_remote or ""
        if mark ~= "" and text:sub(1, #mark) == mark then
            local cfg = rowcfg()
            local t, img_hl = M.image_cells(mark, active and cfg.hl.active or cfg.hl.odd)
            if img_hl then
                text = t .. text:sub(#mark + 1)
                -- byte span after the leading air + the row glyph (blanks under it only take the bg)
                mark_span = { 1 + #glyph, 1 + #glyph + #t, img_hl }
            end
        end
    end
    -- 1 space of breathing room at BOTH ends of every row: the leading space keeps the glyph off column 0.
    local lead = 1
    local line = " " .. glyph .. text .. " "
    -- `line_bytes` bounds the ACTIVE accent to the row's own text (see M.hls): a full-row span would take the
    -- stripe's background with it.
    return line,
        { c0 = lead, c1 = lead + #glyph, hl = ghl, active = active, line_bytes = #line, mark = mark_span }
end

--- The highlight ops for `n` rows, in the CHASSIS format (`{ row0, col0, col_end, group, priority }`, with
--- `col_end = -1` meaning a full-row tint that reaches the window edge): odd/even stripes, the selected row's
--- stronger tint, the active entity's accent, and each icon in its own filetype colour.
---
--- This is the SURFACE's own mechanism (the list provider returns these from `render`, and `surface.paint`
--- applies them) — deliberately not extmarks painted on the side: every relayout re-renders the panel and
--- rewrites its lines, which wipes any foreign extmark. That is exactly how the stripes vanished the moment the
--- preview started re-fitting the frame.
---@param n integer  row count
---@param spans table[]|nil  per-row `{ c0, c1, hl, active }` from `M.line` (index = 1-based row)
---@param sel integer|nil  the 1-based selected row (the cursor row)
---@return table[]
function M.hls(n, spans, sel)
    local cfg = rowcfg()
    local out = {}
    for i = 1, n do
        local odd = (i % 2) == 1
        local sp = spans and spans[i] or nil
        if cfg.stripes then
            local group = (i == sel) and (odd and cfg.hl.sel_odd or cfg.hl.sel_even)
                or (odd and cfg.hl.odd or cfg.hl.even)
            out[#out + 1] = { i - 1, 0, -1, group, (i == sel) and 200 or 100 }
        end
        if sp and sp.active then
            -- The ACTIVE entity (the loaded file / current tab …). With a devicon in the glyph slot the icon can
            -- no longer carry this, so the row TEXT does. TEXT — not the row: a full-row span (`col_end = -1`,
            -- hl_eol) painted with this fg-only group wiped the row's own stripe background, so an active row
            -- that happened to land on an EVEN (yellow) stripe turned blue and the alternation read as three
            -- blue rows in a row. Bounded to the line's own columns, the accent colours the text and the stripe
            -- underneath survives.
            out[#out + 1] = { i - 1, 0, sp.line_bytes or -1, cfg.hl.active, 210 }
        end
        if sp and sp.hl and sp.c1 > sp.c0 then
            out[#out + 1] = { i - 1, sp.c0, sp.c1, sp.hl, 220 }
        end
        if sp and sp.mark then
            -- an image mark inside the text (a remote project's): its own group above the stripe / accent
            out[#out + 1] = { i - 1, sp.mark[1], sp.mark[2], sp.mark[3], 220 }
        end
    end
    return out
end

return M
