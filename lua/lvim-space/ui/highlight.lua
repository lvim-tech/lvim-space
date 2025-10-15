local config = require("lvim-space.config")

local M = {}

local function define_hl_if_missing(name, opts)
    local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
    if not ok or not hl or vim.tbl_isempty(hl) then
        vim.api.nvim_set_hl(0, name, opts)
    end
end

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
end

return M
