-- Configuration
local config = require("lvim-space.config")

-- UI modules
local ui = require("lvim-space.ui")

-- State module
local state = require("lvim-space.api.state")

local M = {}

M.init = function()
	-- Create explicit content
	local workspaces = {
		"Workspace 1",
		"Workspace 2",
		"Workspace 3",
	}
    local lines = {}

	local icons = config.ui.icons

	-- Open the panel with specific content
	local buf, win = ui.open_main({}, "Workspaces")

	if not buf or not win then
		return
	end

	-- Prepare lines without icons
	for _, workspace in ipairs(workspaces) do
		local line = string.format(" %s", workspace)
		table.insert(lines, line)
	end

	-- Set the content
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

	-- Enable sign column and set its width
	vim.wo[win].signcolumn = "yes:1"


	-- Define and place signs for each line with the appropriate icon
	for i, _ in ipairs(workspaces) do
		local icon = icons.line_prefix
		local sign_name = "LvimProject" .. i

		-- Define a unique sign for each line
		vim.fn.sign_define(sign_name, { text = "" .. icon, texthl = "LvimSpaceSign" })

		-- Place the sign on the corresponding line
		vim.fn.sign_place(i, "LvimSpaceSign", sign_name, buf, { lnum = i })
	end

	vim.bo[buf].modifiable = false
	vim.bo[buf].buftype = "nofile"

	-- Initialize the status line
	ui.open_actions(state.lang.INFO_LINE_WORKSPACES)

	vim.keymap.set("n", config.keymappings.global.projects, function()
		ui.close_all()
		require("lvim-space.ui.projects").init()
	end, {
		buffer = buf,
		noremap = true,
		silent = true,
		nowait = true,
	})
end

return M
