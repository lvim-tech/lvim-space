local config = require("lvim-space.config")
local state = require("lvim-space.api.state") -- state.lang може да не е налично при много ранни грешки

local M = {}

-- Дефинирай нивата на логиране
M.levels = {
	ERROR = "ERROR",
	WARN = "WARN",
	INFO = "INFO",
	DEBUG = "DEBUG",
}

-- Функции за проверка дали дадено ниво на логиране е разрешено
-- config.log действа като главен превключвател.
-- Ако специфичен флаг за ниво (напр. config.log_errors) не е дефиниран,
-- той се счита за true по подразбиране (ако config.log е true).
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
		-- За DEBUG, обикновено искаме да е изрично включен, затова не проверяваме за nil.
		return config.log and config.log_debug
	end,
}

M.logger = function(level, msg)
	if not level or not M.levels[level] then
		-- Ако нивото е невалидно, записваме като грешка или пропускаме
		level = M.levels.ERROR
		-- Форматираме съобщението за грешка, за да е ясно какво се е случило
		local original_msg = msg
		if type(original_msg) ~= "string" then
			original_msg = vim.inspect(original_msg) -- Превръщаме в стринг, ако не е
		end
		msg = "Invalid log level provided. Original message: " .. original_msg
	end

	-- Провери дали логирането за това ниво е разрешено в конфигурацията
	if not (level_enabled[level] and level_enabled[level]()) then
		return
	end

	-- Проверка дали config.save е дефиниран
	if not config.save or config.save == "" then
		vim.schedule(function()
			vim.notify("LVIM CTRLSPACE: Log directory (config.save) is not configured. Cannot write logs.", vim.log.levels.ERROR, {
				title = "LVIM CTRLSPACE",
				icon = " ",
				timeout = 7000,
			})
		end)
		return -- Прекратяваме, ако няма къде да пишем
	end

	local log_path = config.save .. "/ctrlspace.log" -- Общ лог файл
	local file, err_open = io.open(log_path, "a")

	if file then
		local time = os.date("%Y-%m-%d %H:%M:%S")
		-- Уверяваме се, че msg е стринг
		local message_to_write = msg
		if type(message_to_write) ~= "string" then
			message_to_write = vim.inspect(message_to_write) -- vim.inspect е по-добър за таблици/сложни типове
		end
		local success_write, err_write = file:write(string.format("[%s] %s: %s\n", time, level, message_to_write))
		if not success_write then
			-- Опит за запис на грешката от писане, ако е възможно
			local write_error_msg = string.format("Error writing to log file '%s': %s", log_path, tostring(err_write))
			if file then -- Проверка дали файлът все още е отворен
				pcall(function() file:write(string.format("[%s] %s: %s\n", time, M.levels.ERROR, write_error_msg)) end)
			end
		end
		file:close()
	else
		local error_msg_text = "Cannot open log file: " .. log_path
		if err_open then
			error_msg_text = error_msg_text .. " (Reason: " .. tostring(err_open) .. ")"
		end

		-- За уведомяване при грешка с лог файла, може да е по-добре да се ограничи
		-- за да не спами потребителя, ако проблемът е постоянен.
		-- Също така, state.lang може да не е достъпно, ако грешката е много рано.
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
				timeout = 7000, -- Увеличено време за видимост
				replace = "lvim_space_log_error", -- Даваме ID за замяна, ако се появи многократно
			})
		end)
	end
end

-- Помощни функции за всяко ниво (удобство)
M.error = function(...) M.logger(M.levels.ERROR, ...) end
M.warn = function(...) M.logger(M.levels.WARN, ...) end
M.info = function(...) M.logger(M.levels.INFO, ...) end
M.debug = function(...) M.logger(M.levels.DEBUG, ...) end

return M
