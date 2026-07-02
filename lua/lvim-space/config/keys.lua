-- lvim-space.config.keys: keymap and key-control configuration.
--
---@module "lvim-space.config.keys"

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
            move_down = "J",
            move_up = "K",
        },
    },

    key_control = {
        -- `j`/`k` move the list cursor; `K`/`J` reorder the selected entity (uppercase, mirroring the cursor
        -- keys). `<C-j>`/`<C-k>` are deliberately ABSENT here: they belong to the surface's SECTOR navigation
        -- (list ⇄ footer bar ⇄ messages), so the panel must NOT claim them — they fall through to the chassis.
        -- `K`/`J` are listed so the `uppercase_letters` blanket-disable below does not no-op the reorder keys.
        allowed = { "j", "k", "K", "J" },
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
