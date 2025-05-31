local M = {}

M = {
	save = "/home/biserstoilov/.local/share/nvim/lvim-space",
	lang = "en",
	notify = true,
	log = true,
	-- Конфигурация за нивата на логиране (избери един от двата подхода)
	-- Подход 1: Индивидуални флагове
	log_errors = true,
	log_warnings = true,
	log_info = true,
	log_debug = false,
	-- Подход 2: Едно общо ниво (ако използваш това, коментирай горните 4 реда)
	-- log_level = "INFO", -- Може да бъде "ERROR", "WARN", "INFO", "DEBUG"

	filetype = "lvim-space",
	title = "LVIM SPACE",
	title_position = "center",
	max_height = 10,
	ui = {
		border = {
			sign = " ",
			main = {
				left = true,
				right = true,
			},
			info = {
				left = true,
				right = true,
			},
			prompt = {
				left = true,
				right = true,
				separate = ":",
			},
			input = {
				left = true,
				right = true,
			},
		},
		icons = {
			error = " ",
			warn = " ",
			info = " ",
			-- line_prefix = " ",
			-- line_prefix_current = " ",
			project = " ",
			project_active = " ",
			workspace = " ",
			workspace_active = " ",
			tab = " ",
			tab_active = " ",
			file = " ",
			file_active = " ",
			empty = "󰇘 ",
		},
		highlight = {
			bg = "#1a1a22",
			bg_line = "#1a1a22",
			fg = "#505067",
			fg_line = "#4a6494",
		},
	},
	keymappings = {
		main = "<C-Space>",
		global = {
			projects = "p",
			workspaces = "w",
			tabs = "t",
			files = "f",
		},
		action = {
			add = "a",
			delete = "d",
			rename = "r",
			path = "p",
			switch = "<Space>",
			enter = "<CR>",
            split_v = "v",
            split_h = "h",
		},
	},

	-- НОВО: Конфигурация за специални буфери, които да се игнорират от сесиите
	special_buffer_patterns = {
		-- Буфери, чиито имена съвпадат с тези шаблони, ще се считат за специални
		name_matches = {
			"^term://", -- Терминални буфери
			"NvimTree_", -- NvimTree плъгин
			"%[Git%]", -- Различни Git плъгини (напр. fugitive)
			" fugitive:", -- Fugitive
			"Overseer:", -- Overseer
			"Telescope", -- Правилно: За буфери, чиито имена СЪДЪРЖАТ "Telescope"
			"TelescopePrompt", -- Правилно: За буфери с точно това име или съдържащи го
			"packer", -- Packer плъгин мениджър
			"lazy", -- Lazy плъгин мениджър
			"mason", -- Mason
			"neo-tree", -- Neo-tree
			"Outline", -- nvim-navic или подобни
			-- Може да добавиш и други специфични за твоята конфигурация
		},
		-- Буфери с тези filetypes ще се считат за специални
		filetypes = {
			"lvim-space", -- Собственият UI на плъгина ТРЯБВА да е тук
			"alpha",
			"dashboard",
			"startify",
			"SnacksDashboard",
			"neo-tree", -- Filetype за neo-tree
			"Outline",
			"TelescopePrompt",
			"mason",
			"lazy",
			"help",
			"qf", -- Quickfix лист
			"man", -- Man страници
			"oil", -- Oil.nvim (въпреки че is_special_buffer го третира малко по-различно)
			"fugitive",
			"fugitiveblame",
			-- Може да добавиш и други
		},
		-- Допълнителни filetypes, които ВИНАГИ да се считат за специални,
		-- дори ако са 'buflisted' и 'modifiable' (това е по-рядко)
		always_special_filetypes = {
			"packer",
		},
	},
}

return M
