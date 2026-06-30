-- lua/lvim-space/config/base.lua
-- Core plugin settings (persistence, behavior, language)

return {
    save = "~/.local/share/nvim/lvim-space",
    lang = "en",
    -- When false (the default) every LvimSpace* highlight group (including the LvimSpaceFooter* bar groups)
    -- is registered through `define_if_missing`, so a colorscheme — or the user's own `nvim_set_hl` — that
    -- already set the group WINS. Set true to always force lvim-space's own palette-derived colours.
    highlights_force = false,
    autosave = true,
    autorestore = true,
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
}
