local config = require("lvim-space.config")

local M = {}

function M.setup()
    vim.api.nvim_set_hl(0, "LvimSpaceNormal", {
        bg = config.ui.highlight.bg,
        fg = config.ui.highlight.fg,
        default = true,
    })
    vim.api.nvim_set_hl(0, "LvimSpaceCursorLine", {
        bg = config.ui.highlight.bg_line,
        fg = config.ui.highlight.fg_line,
        default = true,
    })
    vim.api.nvim_set_hl(0, "LvimSpaceTitle", {
        bg = config.ui.highlight.fg,
        fg = config.ui.highlight.bg,
        default = true,
    })
    vim.api.nvim_set_hl(0, "LvimSpaceInfo", {
        bg = config.ui.highlight.bg,
        fg = config.ui.highlight.fg_line,
        default = true,
    })
    vim.api.nvim_set_hl(0, "LvimSpaceInfo", {
        bg = config.ui.highlight.bg_line,
        fg = config.ui.highlight.fg_line,
        default = true,
    })
    vim.api.nvim_set_hl(0, "LvimSpacePrompt", {
        bg = config.ui.highlight.bg,
        fg = config.ui.highlight.fg_line,
        default = true,
    })
    vim.api.nvim_set_hl(0, "LvimSpaceInput", {
        bg = config.ui.highlight.fg,
        fg = config.ui.highlight.bg,
        default = true,
    })
    vim.api.nvim_set_hl(0, "LvimSpaceSign", {
        bg = config.ui.highlight.bg,
        fg = config.ui.highlight.fg_line,
        default = true,
    })
end

return M
