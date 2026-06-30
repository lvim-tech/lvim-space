-- lua/lvim-space/config/ui.lua
-- UI appearance settings

return {
    filetype = "lvim-space",
    title = "LVIM SPACE",
    title_position = "center",
    -- Where the panel docks: "area" (the Emacs-minibuffer cmdline zone — hosted in the msgarea when it is
    -- enabled, else it grows cmdheight; the editor/heirline stay above it), "float" (a centred modal), or
    -- "bottom" (a bar over the bottom rows). Rendered through lvim-utils.ui.surface.
    mode = "area",
    -- In AREA mode, where the panel title goes: "border" (the native border-title — TITLE left + count right
    -- on the top border, the default) or "statusline" (published to the lvim-utils chrome overlay,
    -- minibuffer style — the heirline file segments give way to the panel title while a panel is open). A
    -- shared lvim-utils chassis key, consistent across every lvim-tech plugin. float / bottom always use the
    -- border-title. The frame border itself is the ONE shared `config.ui.border` in lvim-utils — lvim-space
    -- does not define its own; change that one key to re-border every panel.
    title_line = "border",
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
