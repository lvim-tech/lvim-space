-- lua/lvim-space/ui/highlight.lua
-- Registers all lvim-space highlight groups via lvim-utils.highlight,
-- which handles the ColorScheme autocmd and "define only when missing" logic.

local config = require("lvim-space.config")
local lhl    = require("lvim-utils.highlight")

local M = {}

---Initialise all lvim-space highlight groups from the current config values.
---Groups are defined only when not already set by the user's colorscheme.
---Delegates persistence across colorscheme changes to lvim-utils.highlight.
function M.setup()
    local h = config.ui.highlight
    lhl.register({
        LvimSpaceNormal          = { bg = h.bg,       fg = h.fg,               default = true },
        LvimSpaceCursorLine      = { bg = h.bg_line,  fg = h.fg_line,          default = true },
        LvimSpaceTitle           = { bg = h.fg,        fg = h.bg,              default = true },
        LvimSpaceInfo            = { bg = h.bg,       fg = h.fg_line,          default = true },
        LvimSpacePrompt          = { bg = h.bg,       fg = h.fg_line,          default = true },
        LvimSpaceInput           = { bg = h.fg,        fg = h.bg,              default = true },
        LvimSpaceSign            = { bg = h.bg,       fg = h.fg_line,          default = true },
        LvimSpaceFuzzyPrimary    = { bg = h.bg_fuzzy, fg = h.fg_fuzzy_primary,   bold = true },
        LvimSpaceFuzzySecondary  = { bg = h.bg_fuzzy, fg = h.fg_fuzzy_secondary, bold = true },
    }, false) -- false = define only when not already defined

    lhl.setup() -- installs the ColorScheme autocmd that re-applies registered groups
end

return M
