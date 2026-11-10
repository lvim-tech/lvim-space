-- lvim-space.config.base: core plugin settings (persistence, behaviour, language).
--
---@module "lvim-space.config.base"

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
    -- Remote (SSH) projects: a project whose path is `ssh://[user@]host[:port]/abs/path` is opened through
    -- Neovim's `:connect ssh://` (needs a Neovim that has it). See `lvim-space.core.ssh`.
    ---@class LvimSpaceSshConfig
    ---@field auth "auto"|"key"|"password" How to authenticate before connecting:
    ---   "key"      — key-based only (an agent-held key included); ssh never prompts, a failure is reported.
    ---   "password" — unless a shared connection is already alive, open a floating terminal running an ssh
    ---                master so the password can be typed; then connect over that connection.
    ---   "auto"     — reuse a live connection, else try key-based, and only when that fails fall back to the
    ---                password terminal. The default.
    ---@field timeout integer Timeout (ms) for each NON-interactive ssh call (0 = none).
    ssh = {
        auth = "auto",
        timeout = 30000,
        -- A server that exports XDG_RUNTIME_DIR without creating the directory (a CageFS jail on shared
        -- hosting) stops a newer remote Nvim from starting. "ask" offers to add a guarded unset to the top
        -- of the login shell's startup file there (~/.bashrc, ~/.zshenv); "always" does it unasked; "never"
        -- only reports it.
        fix_runtime_dir = "ask",
        -- Mirror every dir= plugin checkout to the server before connecting (through lvim-pack's
        -- remote_sync, when lvim-pack is the plugin manager), so the remote Neovim runs the same code.
        sync_plugins = true,
    },
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
