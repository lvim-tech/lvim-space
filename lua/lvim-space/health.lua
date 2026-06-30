-- lvim-space.health: :checkhealth lvim-space
--
-- Validates the runtime lvim-space depends on: a recent Neovim, the sqlite.lua persistence backend
-- (hard requirement — it is the session store), the lvim-utils chassis the UI renders through
-- (ui.surface / picker / cursor), a writable save directory, and a coherent `ui.mode`. The area dock
-- additionally wants the lvim-utils msgarea zone enabled — without it the panel falls back to growing
-- 'cmdheight', so we warn rather than fail.
--
---@module "lvim-space.health"

local config = require("lvim-space.config")

local M = {}

---Run the lvim-space health checks. Auto-discovered by `:checkhealth lvim-space`.
function M.check()
    local health = vim.health
    health.start("lvim-space")

    -- Neovim version --------------------------------------------------------
    if vim.fn.has("nvim-0.11") == 1 then
        health.ok("Neovim >= 0.11")
    else
        health.error("Neovim >= 0.11 is required (vim.pack, ui.surface, msgarea host)")
    end

    -- Persistence backend (hard requirement) --------------------------------
    local ok_db = pcall(require, "sqlite.db")
    local ok_tbl = pcall(require, "sqlite.tbl")
    if ok_db and ok_tbl then
        health.ok("sqlite.lua found (session persistence backend)")
    else
        health.error("sqlite.lua not found — install kkharji/sqlite.lua; without it no state can be stored")
    end

    -- lvim-utils chassis ----------------------------------------------------
    local ok_surface = pcall(require, "lvim-utils.ui.surface")
    local ok_picker = pcall(require, "lvim-utils.picker")
    local ok_cursor = pcall(require, "lvim-utils.cursor")
    if ok_surface and ok_picker and ok_cursor then
        health.ok("lvim-utils found (ui.surface + picker + cursor)")
    else
        local missing = {}
        if not ok_surface then
            missing[#missing + 1] = "ui.surface"
        end
        if not ok_picker then
            missing[#missing + 1] = "picker"
        end
        if not ok_cursor then
            missing[#missing + 1] = "cursor"
        end
        health.error(
            "lvim-utils incomplete — missing { "
                .. table.concat(missing, ", ")
                .. " }; install lvim-tech/lvim-utils (the UI renders through it)"
        )
    end

    -- Save directory writable ----------------------------------------------
    local save = config.save and vim.fn.expand(config.save) or nil
    if not save then
        health.warn("config.save is unset — nowhere to store the session database")
    else
        local exists = vim.fn.isdirectory(save) == 1
        if not exists then
            -- The plugin creates it on first write; report the parent's writability instead.
            local parent = vim.fn.fnamemodify(save, ":h")
            if vim.fn.filewritable(parent) == 2 then
                health.ok("save dir parent writable: " .. parent .. " (will be created on first save)")
            else
                health.warn("save dir does not exist and its parent is not writable: " .. save)
            end
        elseif vim.fn.filewritable(save) == 2 then
            health.ok("save dir writable: " .. save)
        else
            health.error("save dir is not writable: " .. save)
        end
    end

    -- UI mode + area-zone coherence ----------------------------------------
    local mode = config.ui and config.ui.mode or nil
    local valid = { area = true, float = true, bottom = true }
    if valid[mode] then
        health.ok("ui.mode = '" .. mode .. "'")
        if mode == "area" then
            local ok_msg, msgarea = pcall(require, "lvim-utils.msgarea")
            if ok_msg and msgarea.is_enabled and msgarea.is_enabled() then
                health.ok("msgarea zone enabled — area panels dock above the messages")
            else
                health.warn(
                    "ui.mode = 'area' but the lvim-utils msgarea zone is OFF — "
                        .. "panels fall back to growing 'cmdheight' (enable the zone, or use ui.mode 'float'/'bottom')"
                )
            end
        end
    else
        health.error("ui.mode = '" .. tostring(mode) .. "' is invalid — expected one of 'area' | 'float' | 'bottom'")
    end

    -- File search dependency (soft) ----------------------------------------
    local fd_bin = (config.search or ""):match("^%S+")
    if fd_bin then
        if vim.fn.executable(fd_bin) == 1 then
            health.ok("file-search command available: '" .. fd_bin .. "'")
        else
            health.warn("search command '" .. fd_bin .. "' not on PATH — :LvimSpace open search will be unavailable")
        end
    end
end

return M
