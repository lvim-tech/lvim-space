-- lua/lvim-space/config/ui.lua
-- UI appearance settings

return {
    filetype = "lvim-space",
    title = "LVIM SPACE",
    title_position = "center",
    max_height = 10,
    spacing = 2,

    border = {
        sign = " ",
        main = { left = true, right = true },
        info = { left = true, right = true },
        prompt = { left = true, right = true, separate = ":" },
        input = { left = true, right = true },
    },

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
