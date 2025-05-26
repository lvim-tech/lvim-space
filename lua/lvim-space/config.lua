local M = {}

M = {
	save = "/home/biserstoilov/.local/share/nvim/lvim-space",
	lang = "en",
	notify = true,
	log = true,
	filetype = "lvim-space",
	title = "LVIM SPACE",
	title_position = "center",
	max_height = 3,
	ui = {
		border = {
			sign = " ",
			maint = {
				left = false,
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
			warn = " ",
			info = " ",
			line_prefix = " ",
			line_prefix_current = " ",
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
		},
		action = {
			add = "a",
			delete = "d",
			rename = "r",
			path = "p",
		},
	},
}

return M
