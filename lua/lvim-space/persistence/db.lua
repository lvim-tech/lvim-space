-- Current User: lvim-tech
-- Current DateTime (UTC): 2025-05-31 15:03:33

local config = require("lvim-space.config")
local notify = require("lvim-space.api.notify")
local log = require("lvim-space.api.log")
local state = require("lvim-space.api.state") -- Използва се за state.lang

local sqlite = require("sqlite.db") -- Предполага се, че това е правилната библиотека (напр. обвивка около lua-sqlite3)
local tbl = require("sqlite.tbl")   -- Предполага се, че това е правилната библиотека за дефиниране на таблици

local uri = config.save .. "/lvimspace.db" -- Път до файла на базата данни

local M = {}
M.db = nil -- Обектът на базата данни, ще се инициализира в M.init

-- Търси записи в таблица.
-- @param table_name (string): Име на таблицата.
-- @param conditions (table|nil): Условия за търсене (напр. { id = 1, name = "test" }).
-- @return (table|nil|false): Таблица с резултати, nil ако няма намерени, false при грешка.
M.find = function(table_name, conditions)
	if not M.db or not M[table_name] then
		log.error(string.format("db.find: Базата данни или таблица '%s' не са инициализирани.", table_name))
		return false
	end
	local ok, result_or_err = pcall(function()
		return M[table_name]:get({ where = conditions }) -- :get метод от sqlite.tbl
	end)

	if not ok then
		log.error(string.format("db.find: Грешка при търсене в таблица '%s' с условия %s: %s", table_name, vim.inspect(conditions), tostring(result_or_err)))
		return false
	end

	if result_or_err == nil or (type(result_or_err) == "table" and next(result_or_err) == nil) then
		return nil -- Няма намерени записи
	end
	return result_or_err
end

-- Вмъква нови записи в таблица.
-- @param table_name (string): Име на таблицата.
-- @param values (table): Стойности за вмъкване (напр. { name = "test", path = "/path" }).
-- @return (integer|false): ID на последния вмъкнат ред при успех, false при грешка.
M.insert = function(table_name, values)
	if not M.db or not M[table_name] then
		log.error(string.format("db.insert: Базата данни или таблица '%s' не са инициализирани.", table_name))
		return false
	end
	local ok, row_id_or_err = pcall(function()
		return M[table_name]:insert(values) -- :insert метод от sqlite.tbl
	end)

	if not ok then
		log.error(string.format("db.insert: Грешка при вмъкване в таблица '%s' със стойности %s: %s", table_name, vim.inspect(values), tostring(row_id_or_err)))
		return false
	end
	return row_id_or_err -- Връща row_id
end

-- Обновява съществуващи записи в таблица.
-- @param table_name (string): Име на таблицата.
-- @param conditions (table): Условия за обновяване (напр. { id = 1 }).
-- @param values (table): Нови стойности (напр. { name = "new_name" }).
-- @return (boolean): true при успех, false при грешка.
M.update = function(table_name, conditions, values)
	if not M.db or not M[table_name] then
		log.error(string.format("db.update: Базата данни или таблица '%s' не са инициализирани.", table_name))
		return false
	end
	local ok, err_msg = pcall(function()
		M[table_name]:update({ where = conditions, set = values }) -- :update метод от sqlite.tbl
	end)

	if not ok then
		log.error(string.format("db.update: Грешка при обновяване на таблица '%s' с условия %s и стойности %s: %s", table_name, vim.inspect(conditions), vim.inspect(values), tostring(err_msg)))
		return false
	end
	return true
end

-- Премахва записи от таблица.
-- @param table_name (string): Име на таблицата.
-- @param conditions (table): Условия за премахване (напр. { id = 1 }).
-- @return (boolean): true при успех, false при грешка.
M.remove = function(table_name, conditions)
	if not M.db or not M[table_name] then
		log.error(string.format("db.remove: Базата данни или таблица '%s' не са инициализирани.", table_name))
		return false
	end
	local ok, err_msg = pcall(function()
		M[table_name]:remove(conditions) -- :remove метод от sqlite.tbl
	end)

	if not ok then
		log.error(string.format("db.remove: Грешка при премахване от таблица '%s' с условия %s: %s", table_name, vim.inspect(conditions), tostring(err_msg)))
		return false
	end
	return true
end

-- Инициализира базата данни и дефинира схемата на таблиците.
-- @return (boolean): true при успех, false при неуспех.
M.init = function()
	log.info("db.init: Начало на инициализация на базата данни.")
	if vim.fn.isdirectory(config.save) == 0 then
		log.info("db.init: Директорията за запазване '" .. config.save .. "' не съществува. Опит за създаване.")
		local mkdir_ok, mkdir_err_msg = pcall(vim.fn.mkdir, config.save, "p")
		-- vim.fn.mkdir връща nil при успех и не-nil (съобщение за грешка) при неуспех,
		-- или 0 при неуспех и 1 при успех, ако се използва като vim команда.
		-- pcall ще хване грешката, ако mkdir се провали и mkdir_ok ще е false.
		if not mkdir_ok then
			local err_msg_notify = state.lang and state.lang.FAILED_TO_CREATE_SAVE_DIRECTORY or "Неуспешно създаване на директория за данни: "
			notify.error(err_msg_notify .. config.save)
			log.error("db.init: Неуспешно създаване на директория '" .. config.save .. "'. Грешка: " .. tostring(mkdir_err_msg))
			config.log = false
			return false
		end
		log.info("db.init: Директорията за запазване е създадена успешно: " .. config.save)
	end

	local db_init_ok, db_err_msg = pcall(function()
		M.db = sqlite({ -- Увери се, че това е правилният конструктор за твоята sqlite обвивка
			uri = uri,
			opts = {
				foreign_keys = "ON", -- Опит за активиране на foreign keys чрез опции
			},
			-- Алтернативно, ако opts не работи за PRAGMA:
			-- on_connect = function(conn)
			-- conn:execute("PRAGMA foreign_keys = ON;")
			-- end,
		})

		if not M.db then
			error("sqlite constructor for M.db returned nil") -- Ще бъде хванато от pcall
		end

		-- Дефиниция на таблица "projects"
		M.projects = tbl("projects", {
			id = { "integer", primary = true, autoincrement = true },
			name = { "text", required = true, unique = true },
			path = { "text", required = true, unique = true },
		}, M.db)

		-- Дефиниция на таблица "workspaces"
		M.workspaces = tbl("workspaces", {
			id = { "integer", primary = true, autoincrement = true },
			project_id = {
				type = "integer",
				required = true,
				reference = "projects.id", -- Провери синтаксиса на sqlite.tbl за foreign keys
				on_delete = "cascade",     -- Каскадно изтриване
			},
			name = { "text", required = true }, -- Уникалността на име в рамките на проект се проверява в data.lua
			tabs = { "text" }, -- JSON низ, сериализацията се прави в data.lua
			active = { "boolean", default_value = false },
		}, M.db)

		-- Дефиниция на таблица "tabs"
		M.tabs = tbl("tabs", {
			id = { "integer", primary = true, autoincrement = true },
			workspace_id = {
				type = "integer",
				required = true,
				reference = "workspaces.id", -- Провери синтаксиса
				on_delete = "cascade",
			},
			name = { "text", required = true }, -- Уникалността на име в рамките на workspace се проверява в data.lua
			data = { "text" }, -- JSON низ, сериализацията се прави в data.lua/session.lua
		}, M.db)

		-- Проверка дали PRAGMA foreign_keys е наистина активиран
		if M.db.get_Rows then -- Увери се, че M.db има такъв метод
			local fk_status_rows = M.db:get_Rows("PRAGMA foreign_keys;")
			if fk_status_rows and fk_status_rows[1] and fk_status_rows[1][1] == "1" then
				log.info("db.init: PRAGMA foreign_keys е успешно АКТИВИРАН (ON).")
			else
				log.warn("db.init: PRAGMA foreign_keys НЕ Е активиран (OFF) или не може да се провери. Статус: " .. vim.inspect(fk_status_rows))
			end
		else
			log.warn("db.init: Не може да се провери статуса на PRAGMA foreign_keys, липсва метод get_Rows в M.db.")
		end
	end)

	if not db_init_ok then
		local err_msg_notify = state.lang and state.lang.FAILED_TO_CREATE_DB or "Неуспешно създаване/отваряне на база данни."
		notify.error(err_msg_notify)
		-- Коригирана грешка: използваме db_err_msg
		log.error("db.init: КРИТИЧНО - Неуспешно инициализиране на базата данни или дефиниране на таблици: " .. tostring(db_err_msg))
		M.db = nil -- Нулираме M.db при грешка
		return false
	end

	log.info("db.init: Базата данни и таблиците са инициализирани успешно: " .. uri)
	return true
end

-- Затваря връзката с базата данни.
M.close_db_connection = function()
	if M.db then
		log.info("db.close_db_connection: Опит за затваряне на връзката с базата данни.")
		local ok, err_msg = pcall(function()
			if M.db.close then -- Проверка дали методът съществува
				M.db:close()
			else
				log.warn("db.close_db_connection: Обектът M.db няма метод :close().")
			end
		end)
		if ok then
			log.info("db.close_db_connection: Връзката с базата данни е (опит за) затворена.")
			M.db = nil
		else
			log.error("db.close_db_connection: Грешка при опит за затваряне на връзката с базата данни: " .. tostring(err_msg))
		end
	else
		log.debug("db.close_db_connection: Няма активна връзка с база данни за затваряне (M.db е nil).")
	end
end

return M
