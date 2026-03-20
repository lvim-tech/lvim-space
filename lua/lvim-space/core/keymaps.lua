--- Keymap utilities for lvim-space UI panels.
--- Provides helpers to disable regular typing keys inside plugin buffers and to
--- set the Escape key for closing all panels.

local config = require("lvim-space.config")

local M = {}

-- Cache the set of keys to disable so it is built only once.
---@type string[]|nil
local _disabled_keys_cache = nil

--- Build the list of keys that should be no-op'd in plugin buffers.
--- Reads `config.key_control` to determine categories and explicit overrides,
--- then removes any keys listed in `allowed`.
---@return string[] keys Sorted list of key strings to disable.
local function build_disabled_keys()
    local key_conf = config.key_control or {}
    local allowed_map = {}
    for _, k in ipairs(key_conf.allowed or {}) do
        allowed_map[k] = true
    end

    local candidates = {}
    local cats = key_conf.disable_categories
        or {
            lowercase_letters = true,
            uppercase_letters = true,
            digits = true,
        }

    if cats.lowercase_letters then
        for c = string.byte("a"), string.byte("z") do
            table.insert(candidates, string.char(c))
        end
    end
    if cats.uppercase_letters then
        for c = string.byte("A"), string.byte("Z") do
            table.insert(candidates, string.char(c))
        end
    end
    if cats.digits then
        for d = 0, 9 do
            table.insert(candidates, tostring(d))
        end
    end

    -- Add explicitly-disabled keys that are not already in the list.
    local seen = {}
    for _, k in ipairs(candidates) do
        seen[k] = true
    end
    for _, k in ipairs(key_conf.explicitly_disabled or {}) do
        if not seen[k] then
            table.insert(candidates, k)
            seen[k] = true
        end
    end

    -- Remove allowed keys.
    local result = {}
    for _, k in ipairs(candidates) do
        if not allowed_map[k] then
            table.insert(result, k)
        end
    end
    return result
end

--- Set up the essential Escape keymap for a plugin buffer.
--- Pressing Escape in normal mode will call `ui.close_all()`.
---@param buf integer Buffer handle to apply the keymap to.
function M.enable_base_maps(buf)
    vim.api.nvim_buf_set_keymap(buf, "n", "<Esc>", "", {
        nowait = true,
        noremap = true,
        silent = true,
        callback = function()
            require("lvim-space.ui").close_all()
        end,
    })
end

--- Map all configured keys to `<nop>` in the given buffer so regular typing is
--- suppressed inside plugin panels. The key list is computed once and cached.
---@param buf integer Buffer handle to apply the no-op keymaps to.
M.disable_all_maps = function(buf)
    if not _disabled_keys_cache then
        _disabled_keys_cache = build_disabled_keys()
    end
    for _, key in ipairs(_disabled_keys_cache) do
        vim.keymap.set("n", key, "<nop>", { buffer = buf, nowait = true, silent = true })
    end
end

return M
