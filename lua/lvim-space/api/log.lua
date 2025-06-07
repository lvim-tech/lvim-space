local config = require("lvim-space.config")
local state = require("lvim-space.api.state")

local M = {}

M.levels = {
    ERROR = "ERROR",
    WARN = "WARN",
    INFO = "INFO",
    DEBUG = "DEBUG",
}

local level_enabled = {
    [M.levels.ERROR] = function()
        return config.log and (config.log_errors == nil or config.log_errors)
    end,
    [M.levels.WARN] = function()
        return config.log and (config.log_warnings == nil or config.log_warnings)
    end,
    [M.levels.INFO] = function()
        return config.log and (config.log_info == nil or config.log_info)
    end,
    [M.levels.DEBUG] = function()
        return config.log and config.log_debug
    end,
}

M.logger = function(level, msg)
    if not level or not M.levels[level] then
        level = M.levels.ERROR
        local original_msg = msg
        if type(original_msg) ~= "string" then
            original_msg = vim.inspect(original_msg)
        end
        msg = "Invalid log level provided. Original message: " .. original_msg
    end

    if not (level_enabled[level] and level_enabled[level]()) then
        return
    end

    if not config.save or config.save == "" then
        vim.schedule(function()
            vim.notify(
                "LVIM CTRLSPACE: Log directory (config.save) is not configured. Cannot write logs.",
                vim.log.levels.ERROR,
                {
                    title = "LVIM CTRLSPACE",
                    icon = " ",
                    timeout = 7000,
                }
            )
        end)
        return
    end

    local log_path = config.save .. "/ctrlspace.log"
    local file, err_open = io.open(log_path, "a")

    if file then
        local time = os.date("%Y-%m-%d %H:%M:%S")
        local message_to_write = msg
        if type(message_to_write) ~= "string" then
            message_to_write = vim.inspect(message_to_write)
        end
        local success_write, err_write = file:write(string.format("[%s] %s: %s\n", time, level, message_to_write))
        if not success_write then
            local write_error_msg = string.format("Error writing to log file '%s': %s", log_path, tostring(err_write))
            if file then
                pcall(function()
                    file:write(string.format("[%s] %s: %s\n", time, M.levels.ERROR, write_error_msg))
                end)
            end
        end
        file:close()
    else
        local error_msg_text = "Cannot open log file: " .. log_path
        if err_open then
            error_msg_text = error_msg_text .. " (Reason: " .. tostring(err_open) .. ")"
        end
        if state and state.lang and state.lang.CANNOT_OPEN_ERROR_LOG_FILE then
            error_msg_text = state.lang.CANNOT_OPEN_ERROR_LOG_FILE .. log_path
            if err_open then
                error_msg_text = error_msg_text .. " (Reason: " .. tostring(err_open) .. ")"
            end
        end
        vim.schedule(function()
            vim.notify(error_msg_text, vim.log.levels.ERROR, {
                title = "LVIM CTRLSPACE",
                icon = " ",
                timeout = 7000,
                replace = "lvim_space_log_error",
            })
        end)
    end
end

M.error = function(...)
    M.logger(M.levels.ERROR, ...)
end
M.warn = function(...)
    M.logger(M.levels.WARN, ...)
end
M.info = function(...)
    M.logger(M.levels.INFO, ...)
end
M.debug = function(...)
    M.logger(M.levels.DEBUG, ...)
end

return M
