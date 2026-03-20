-- lua/lvim-space/utils/table.lua
-- Table manipulation utilities

local M = {}

--- Deep merge t2 into t1 (modifies t1 in place).
--- Arrays are concatenated; maps are recursively merged.
---@param t1 table Base table
---@param t2 table Overrides table
---@return table t1 Modified base table
function M.merge(t1, t2)
    if type(t2) ~= "table" then
        return t1
    end
    for k, v in pairs(t2) do
        if type(v) == "table" and type(t1[k] or false) == "table" then
            if M.is_array(t1[k]) then
                t1[k] = M.concat(t1[k], v)
            else
                M.merge(t1[k], t2[k])
            end
        else
            t1[k] = v
        end
    end
    return t1
end

--- Append all elements of t2 to t1.
---@param t1 table Destination array
---@param t2 table Source array
---@return table t1
function M.concat(t1, t2)
    for i = 1, #t2 do
        table.insert(t1, t2[i])
    end
    return t1
end

--- Return true if t is a sequential array (no holes, integer keys only).
---@param t table Table to test
---@return boolean
function M.is_array(t)
    local i = 0
    for _ in pairs(t) do
        i = i + 1
        if t[i] == nil then
            return false
        end
    end
    return true
end

--- Swap two entries in an array-table in place.
--- Also updates `tabs.active` if it points to either index.
---@param tabs table Array with optional `.active` integer field
---@param from_idx integer Source index
---@param to_idx integer Destination index
function M.move_tab(tabs, from_idx, to_idx)
    if from_idx == to_idx or not tabs[from_idx] or not tabs[to_idx] then
        return
    end
    tabs[from_idx], tabs[to_idx] = tabs[to_idx], tabs[from_idx]
    if tabs.active == from_idx then
        tabs.active = to_idx
    elseif tabs.active == to_idx then
        tabs.active = from_idx
    end
end

return M
