local M = {}

M = {
    save = "~/.local/share/nvim/lvim-space",
    lang = "en",
    notify = true,
    log = true,
    log_errors = true,
    log_warnings = true,
    log_info = true,
    log_debug = true,
    filetype = "lvim-space",
    title = "LVIM SPACE",
    title_position = "center",
    status_space = 3,
    max_height = 10,
    autosave = true,
    open_panel_on_add_file = false,
    search = "fd --type f --hidden --follow"
        .. " --exclude .git"
        .. " --exclude node_modules"
        .. " --exclude target"
        .. " --exclude build"
        .. " --exclude dist"
        .. " --exclude .next"
        .. " --exclude .nuxt"
        .. " --exclude coverage"
        .. " --exclude __pycache__"
        .. " --exclude .pytest_cache"
        .. " --exclude .venv"
        .. " --exclude venv"
        .. " --exclude .env"
        .. " --exclude .idea"
        .. " --exclude .vscode"
        .. " --exclude .egg-info"
        .. " --exclude .mypy_cache"
        .. " --exclude vendor"
        .. " --exclude .svn",
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
            bg_fuzzy = "#1a1a22",
            fg_fuzzy_primary = "#b65252",
            fg_fuzzy_secondary = "#a26666",
        },
    },
    keymappings = {
        main = "<C-Space>",
        global = {
            projects = "p",
            workspaces = "w",
            tabs = "t",
            files = "f",
            search = "s",
        },
        action = {
            add = "a",
            delete = "d",
            rename = "r",
            switch = "<Space>",
            enter = "<CR>",
            split_v = "v",
            split_h = "h",
            move_down = "<C-j>",
            move_up = "<C-k>",
        },
    },
    key_control = {
        allowed = {
            "j",
            "k",
            "<C-j>",
            "<C-k>",
        },
        explicitly_disabled = {
            "$",
            "gg",
            "G",
            "<C-d>",
            "<C-u>",
            "<Left>",
            "<Right>",
            "<Up>",
            "<Down>",
            "<Space>",
            "BS",
        },
        disable_categories = {
            lowercase_letters = true,
            uppercase_letters = true,
            digits = true,
        },
    },
}

if M.save then
    M.save = vim.fn.expand(M.save)
end

return M
