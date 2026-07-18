-- lvim-space.config.ui: UI appearance settings — dock mode, title placement, icons and dimensions.
-- Title placement keys (title_pos / title_line) default to nil so they INHERIT the central lvim-utils
-- chassis values; set them here only to override the placement for lvim-space alone.
--
---@module "lvim-space.config.ui"

return {
    filetype = "lvim-space",
    title = "LVIM SPACE",
    -- Title alignment — INHERITED from the central `lvim-utils config.ui.title_pos` (default "left") when nil,
    -- exactly like `title_line`. Set "left" | "center" | "right" here to override the panel title placement for
    -- lvim-space alone. (Was the dead `title_position`, never wired; now the real chassis `title_pos`.)
    title_pos = nil,
    -- Where the panel docks: "area" (the Emacs-minibuffer cmdline zone — hosted in the msgarea when it is
    -- enabled, else it grows cmdheight; the editor/heirline stay above it), "float" (a centred modal), or
    -- "bottom" (a bar over the bottom rows). Rendered through lvim-ui.surface.
    mode = "area",
    -- Where the panel title goes — INHERITED from the central `lvim-utils config.ui.title_line` (default "row":
    -- a CONTENT row at the top, TITLE flush-left + count flush-right, matching the lvim-utils pickers). lvim-space
    -- does NOT set its own, so changing the one central key re-titles every lvim-tech plugin at once; SET this
    -- key here only to override the placement for lvim-space alone ("row" | "border" | "statusline"). Likewise
    -- the frame border is the ONE shared central `config.ui.border` — lvim-space defines neither.
    title_line = nil,
    spacing = 2,

    -- PICKER-PARITY ROWS. Every list (projects / workspaces / tabs / files / search) renders through
    -- `lvim-space.ui.rows`, the same visual language as a lvim-picker list.
    --
    -- A FILE row gets a real filetype DEVICON in its own colour instead of the flat `icons.file` glyph; the
    -- glyph therefore can no longer mark the ACTIVE file, so the active row is painted with `rows.hl.active`.
    -- Set `devicons = false` to go back to the flat `icons.file` / `icons.file_active` pair.
    devicons = true,
    -- The icon PROVIDER + colour mode, passed to the shared `lvim-utils.icons` (nil = its own defaults), so
    -- lvim-space resolves the same glyphs, from the same source, as every other lvim-tech list.
    icon_provider = nil,
    icon_color_mode = nil,
    rows = {
        -- Odd/even row striping + the stronger tint on the SELECTED row — the picker's list look. The cursor is
        -- hidden in these panels, so the selection IS this tint (not `cursorline`).
        stripes = true,
        -- Every group is overridable. The defaults are the pickers' OWN list groups, so a theme change moves
        -- lvim-space and the pickers together; name your own here to steer lvim-space alone.
        hl = {
            odd = "LvimUiMsgAreaRowOdd",
            even = "LvimUiMsgAreaRowEven",
            sel_odd = "LvimUiMsgAreaSelOdd",
            sel_even = "LvimUiMsgAreaSelEven",
            active = "LvimSpaceActiveRow",
        },
    },
    -- The PREVIEW panel beside the FILES list — the file under the cursor, shown through the shared
    -- `lvim-ui.preview` (the picker's preview: the file's REAL buffer, so it is editable and in two-way sync).
    -- It follows the cursor as you move through the list. Only the files view has one (it is the only entity
    -- that names a file); `enabled = false` turns it off.
    preview = {
        enabled = true,
        side = "right", -- "right" | "left" | "dynamic" (a peek float above the list)
        width = 0.5, -- the preview's share of the panel width (side = left/right)
        numbers = true, -- line numbers in the preview
        empty = "Nothing to preview",
    },

    icons = {
        error = " ",
        warn = " ",
        info = " ",
        -- No per-entity glyph by default: an EMPTY icon (not a blank space) keeps the row's leading air to the
        -- single space `ui.rows` adds itself — a placeholder " " here would double it into a 2-space indent.
        project = "",
        project_active = "",
        workspace = "",
        workspace_active = "",
        tab = "",
        tab_active = "",
        file = "",
        file_active = "",
        empty = "󰇘 ",
        pre = "➤ ",
    },
}
