-- lua/lvim-space/ui/highlight.lua
-- Defines and initialises all highlight groups used by the lvim-space UI.
-- Groups are only created when they have not been defined by the user's
-- colorscheme, preserving theme-provided overrides.

local config = require("lvim-space.config")

local M = {}

---Create a highlight group only when it has not already been defined.
---This lets user colorschemes override plugin defaults without being clobbered.
---@param name string Highlight group name (e.g. `"LvimSpaceNormal"`)
---@param opts table Attribute table accepted by `vim.api.nvim_set_hl` (colors, bold, etc.)
local function define_hl_if_missing(name, opts)
    local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
    if not ok or not hl or vim.tbl_isempty(hl) then
        vim.api.nvim_set_hl(0, name, opts)
    end
end

---Initialise all lvim-space highlight groups from the current config values.
---Called once during plugin setup. Safe to call multiple times (idempotent
---for groups that already exist).
function M.setup()
    define_hl_if_missing("LvimSpaceNormal", {
        bg = config.ui.highlight.bg,
        fg = config.ui.highlight.fg,
        default = true,
    })
    define_hl_if_missing("LvimSpaceCursorLine", {
        bg = config.ui.highlight.bg_line,
        fg = config.ui.highlight.fg_line,
        default = true,
    })
    define_hl_if_missing("LvimSpaceTitle", {
        bg = config.ui.highlight.fg,
        fg = config.ui.highlight.bg,
        default = true,
    })
    define_hl_if_missing("LvimSpaceInfo", {
        bg = config.ui.highlight.bg,
        fg = config.ui.highlight.fg_line,
        default = true,
    })
    define_hl_if_missing("LvimSpacePrompt", {
        bg = config.ui.highlight.bg,
        fg = config.ui.highlight.fg_line,
        default = true,
    })
    define_hl_if_missing("LvimSpaceInput", {
        bg = config.ui.highlight.fg,
        fg = config.ui.highlight.bg,
        default = true,
    })
    define_hl_if_missing("LvimSpaceSign", {
        bg = config.ui.highlight.bg,
        fg = config.ui.highlight.fg_line,
        default = true,
    })
    define_hl_if_missing("LvimSpaceFuzzyPrimary", {
        bg = config.ui.highlight.bg_fuzzy,
        fg = config.ui.highlight.fg_fuzzy_primary,
        bold = true,
    })
    define_hl_if_missing("LvimSpaceFuzzySecondary", {
        bg = config.ui.highlight.bg_fuzzy,
        fg = config.ui.highlight.fg_fuzzy_secondary,
        bold = true,
    })

    -- Re-register on every call so the autocmd is set up during setup().
    -- Only one augroup is created; subsequent calls clear and recreate it.
    local aug = vim.api.nvim_create_augroup("LvimSpaceHighlights", { clear = true })
    vim.api.nvim_create_autocmd("ColorScheme", {
        group    = aug,
        callback = M.setup,
        desc     = "Re-apply lvim-space highlight groups after colorscheme change",
    })
end

return M
