local config = require("lvim-space.config")

local M = {}

local function notify(msg, level)
    if not config.notify then
        return
    end
    vim.schedule(function()
        vim.notify(msg, level, {
            title = config.title,
            icon = level == 4 and config.ui.icons.error or level == 3 and config.ui.icons.warn or config.ui.icons.info,
            timeout = 5000,
            replace = nil,
        })
    end)
end

function M.info(msg)
    notify(msg, vim.log.levels.INFO)
end

function M.warn(msg)
    notify(msg, vim.log.levels.WARN)
end

function M.error(msg)
    notify(msg, vim.log.levels.ERROR)
end

return M
