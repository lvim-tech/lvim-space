-- lua/lvim-space/config/highlights.lua
-- Highlight group definitions using the shared lvim-utils color palette.
-- Colors adapt automatically when lvim-colorscheme syncs the palette.

local c = require("lvim-utils.colors")
local hl = require("lvim-utils.highlight")

-- Returns a fresh highlight table by reading current palette values.
-- Must be a function so that each call reflects the latest palette state
-- (e.g. after lvim-colorscheme syncs via colors.on_change).
local function build()
    local blue_high = hl.blend(c.blue, c.bg, 0.1)
    local main_color = c.blue_dark
    return {
        LvimSpaceNormal = { bg = c.bg_dark },
        LvimSpaceCursorLine = { bg = c.bg_dark, fg = main_color, bold = true },
        LvimSpaceTitle = { bg = blue_high, fg = main_color, bold = true },
        LvimSpaceInfo = { bg = c.bg_dark, fg = main_color, bold = true },
        LvimSpacePrompt = { bg = c.bg_dark, fg = main_color, bold = true },
        LvimSpaceInput = { bg = blue_high, fg = c.blue },
        LvimSpaceSign = { bg = c.bg_dark, fg = main_color },
        LvimSpaceCursor = { bg = c.bg_dark, fg = c.bg_dark },
        LvimSpaceFuzzyPrimary = { bg = blue_high, fg = c.blue, bold = true },
        LvimSpaceFuzzySecondary = { bg = blue_high, fg = c.blue_dark, bold = true },
    }
end

return {
    build = build,
    force = true,
}
