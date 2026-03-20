-- lua/lvim-space/ui/highlight.lua
-- Registers all lvim-space highlight groups via lvim-utils.highlight,
-- which handles the ColorScheme autocmd and "define only when missing" logic.

local config = require("lvim-space.config")
local lhl    = require("lvim-utils.highlight")
local colors = require("lvim-utils.colors")

local M = {}

---Initialise all lvim-space highlight groups from the shared lvim-utils color palette.
---Groups are defined only when not already set by the user's colorscheme.
---Registers an on_change listener so that groups are force-reapplied with fresh
---palette values whenever lvim-colorscheme syncs the palette.
function M.setup()
    local force = config.highlights_force
    lhl.register(config.build_highlights(), force)
    lhl.setup()

    colors.on_change(function()
        lhl.register(config.build_highlights(), force)
    end)
end

return M
