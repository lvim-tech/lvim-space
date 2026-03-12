-- lua/lvim-space/config/keys.lua
-- Keymap and key-control configuration

return {
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
        allowed = { "j", "k", "<C-j>", "<C-k>" },
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
