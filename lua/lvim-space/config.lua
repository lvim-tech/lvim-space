local M = {}

M = {
    save = "~/.local/share/nvim/lvim-space",
    lang = "en",
    notify = true,
    log = true,
    log_errors = true,
    log_warnings = true,
    log_info = true,
    log_debug = false,
    filetype = "lvim-space",
    title = "LVIM SPACE",
    title_position = "center",
    status_space = 2,
    max_height = 10,
    autosave = true,
    ui = {
        border = {
            sign = " ",
            main = {
                left = true,
                right = true,
            },
            info = {
                left = true,
                right = true,
            },
            prompt = {
                left = true,
                right = true,
                separate = ":",
            },
            input = {
                left = true,
                right = true,
            },
        },
        icons = {
            error = " ",
            warn = " ",
            info = " ",
            -- line_prefix = " ",
            -- line_prefix_current = " ",
            project = " ",
            project_active = " ",
            workspace = " ",
            workspace_active = " ",
            tab = " ",
            tab_active = " ",
            file = " ",
            file_active = " ",
            empty = "󰇘 ",
            pre = "➤ ",
        },
        highlight = {
            bg = "#1a1a22",
            bg_line = "#1a1a22",
            fg = "#505067",
            fg_line = "#4a6494",
        },
    },
    keymappings = {
        main = "<C-Space>",
        global = {
            projects = "p",
            workspaces = "w",
            tabs = "t",
            files = "f",
        },
        action = {
            add = "a",
            delete = "d",
            rename = "r",
            switch = "<Space>",
            enter = "<CR>",
            split_v = "v",
            split_h = "h",
        },
    },
}

return M
