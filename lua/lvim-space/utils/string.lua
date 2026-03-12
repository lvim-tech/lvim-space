-- lua/lvim-space/utils/string.lua
-- String utilities

local M = {}

local SUPERSCRIPT = {
    "\u{2070}",
    "\u{00b9}",
    "\u{00b2}",
    "\u{00b3}",
    "\u{2074}",
    "\u{2075}",
    "\u{2076}",
    "\u{2077}",
    "\u{2078}",
    "\u{2079}",
}

--- Convert an integer to a superscript unicode string.
---@param num integer|string Number to convert
---@return string Superscript representation
function M.to_superscript(num)
    local str = tostring(num)
    local result = ""
    for i = 1, #str do
        local digit = tonumber(str:sub(i, i))
        if digit then
            result = result .. SUPERSCRIPT[digit + 1]
        end
    end
    return result
end

return M
