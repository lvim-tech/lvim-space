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
            -- The keymap CHEATSHEET (`g?`) — a CHORD, so `g` stays free as its prefix (see `key_control.allowed`
            -- below: `g` must NOT be no-op'd, or the chord could never start). The window is built from THIS
            -- table, so a rebind shows up in it.
            help = "g?",
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
        -- `g` is allowed so it can serve as the PREFIX of the `g?` cheatsheet chord: `disable_all_maps` maps
        -- every other letter to <Nop> with `nowait`, and a nowait <Nop> on `g` would fire the moment `g` is
        -- pressed — the chord could never resolve. (lvim-ui OWNS the prefix on the panel buffer, so a bare `g`
        -- is inert and an unknown continuation like `gg` is simply replayed.)
        allowed = { "j", "k", "K", "J", "g" },
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
