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
        -- What the server's environment lacks for remote Neovim and for the tools installed there: an
        -- XDG_RUNTIME_DIR exported without its directory (a CageFS jail on shared hosting), and node / npm or
        -- python3 present on the host but not on PATH (CloudLinux alt-nodejs / alt-python, nvm, mise).
        -- "ask" offers to write one marked block at the top of the login shell's startup file there
        -- (~/.bashrc, ~/.zshenv); "always" writes it unasked; "never" only reports. (`fix_runtime_dir`, the
        -- earlier name, is still read.)
        fix_environment = "ask",
        -- Neovim asks "Connect? Yes / Update Nvim / No" on every :connect ssh:// (it installs Nvim there and
        -- overwrites ~/.config/nvim-remote). "first" lets it ask until a connect to that address succeeds, then
        -- answers Yes; "always" lets it ask every time (the way to pick "Update Nvim"); "never" always answers Yes.
        confirm_connect = "first",
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
