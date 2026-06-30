-- lua/lvim-space/config/ui.lua
-- UI appearance settings

return {
    filetype = "lvim-space",
    title = "LVIM SPACE",
    -- Title alignment — INHERITED from the central `lvim-utils config.ui.title_pos` (default "left") when nil,
    -- exactly like `title_line`. Set "left" | "center" | "right" here to override the panel title placement for
    -- lvim-space alone. (Was the dead `title_position`, never wired; now the real chassis `title_pos`.)
    title_pos = nil,
    -- Where the panel docks: "area" (the Emacs-minibuffer cmdline zone — hosted in the msgarea when it is
    -- enabled, else it grows cmdheight; the editor/heirline stay above it), "float" (a centred modal), or
    -- "bottom" (a bar over the bottom rows). Rendered through lvim-utils.ui.surface.
    mode = "area",
    -- Where the panel title goes — INHERITED from the central `lvim-utils config.ui.title_line` (default "row":
    -- a CONTENT row at the top, TITLE flush-left + count flush-right, matching the lvim-utils pickers). lvim-space
    -- does NOT set its own, so changing the one central key re-titles every lvim-tech plugin at once; SET this
    -- key here only to override the placement for lvim-space alone ("row" | "border" | "statusline"). Likewise
    -- the frame border is the ONE shared central `config.ui.border` — lvim-space defines neither.
    title_line = nil,
    max_height = 10,
    spacing = 2,

    icons = {
        error = " ",
        warn = " ",
        info = " ",
        project = " ",
        project_active = " ",
        workspace = " ",
        workspace_active = " ",
        tab = " ",
        tab_active = " ",
        file = " ",
        file_active = " ",
        empty = "󰇘 ",
        pre = "➤ ",
    },
}
