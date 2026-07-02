-- lvim-space.config.highlights: highlight group definitions built from the shared lvim-utils colour
-- palette, so the groups adapt automatically when lvim-colorscheme syncs the palette.
--
---@module "lvim-space.config.highlights"

local c = require("lvim-utils.colors")
local hl = require("lvim-utils.highlight")

-- Returns a fresh highlight table by reading current palette values.
-- Must be a function so that each call reflects the latest palette state
-- (e.g. after lvim-colorscheme syncs via colors.on_change).
local function build()
    local blue_high = hl.blend(c.blue, c.bg, 0.1)
    local main_color = c.blue_dark
    -- Drop the panel background (NONE) when the theme is transparent so lvim-space follows a
    -- translucent terminal; the tinted chrome cells (title/input/fuzzy) keep their accents.
    local panel_bg = c.transparent and c.none or c.bg_dark
    -- The navigable footer bar mirrors the lvim-utils footer convention (LvimUiFooter*) but as lvim-space's
    -- OWN, user-overridable groups derived from the live palette: every cell is its accent blended toward the
    -- panel background (c.bg_dark, kept concrete even when the theme is transparent so the tinted boxes stay
    -- visible). KEY box = blue, LABEL box = yellow, hover variants = a stronger tint, and the group separator
    -- (the "red dot" + the ❮/❯ overflow chevrons) = our defined red box. Tints track the colourscheme.
    local foot_bg = c.bg_dark
    return {
        LvimSpaceNormal = { bg = panel_bg },
        LvimSpaceCursorLine = { bg = panel_bg, fg = main_color, bold = true },
        LvimSpaceTitle = { bg = blue_high, fg = main_color, bold = true },
        LvimSpaceInfo = { bg = panel_bg, fg = main_color, bold = true },
        LvimSpacePrompt = { bg = panel_bg, fg = main_color, bold = true },
        LvimSpaceInput = { bg = blue_high, fg = c.blue },
        LvimSpaceSign = { bg = panel_bg, fg = main_color },
        LvimSpaceCursor = { bg = panel_bg, fg = c.bg_dark },
        LvimSpaceFuzzyPrimary = { bg = blue_high, fg = c.blue, bold = true },
        LvimSpaceFuzzySecondary = { bg = blue_high, fg = c.blue_dark, bold = true },
        LvimSpaceFooterKey = { bg = hl.blend(c.blue, foot_bg, 0.3), fg = c.blue, bold = true },
        LvimSpaceFooterLabel = { bg = hl.blend(c.yellow, foot_bg, 0.2), fg = c.yellow },
        LvimSpaceFooterKeyHover = { bg = hl.blend(c.blue, foot_bg, 0.5), fg = c.blue, bold = true },
        LvimSpaceFooterLabelHover = { bg = hl.blend(c.yellow, foot_bg, 0.4), fg = c.yellow, bold = true },
        LvimSpaceFooterSep = { bg = hl.blend(c.red, foot_bg, 0.6), fg = hl.blend(c.red, foot_bg, 0.3), bold = true },
    }
end

return {
    build = build,
}
