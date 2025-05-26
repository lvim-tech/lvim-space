-- Load and initialize the plugin
if vim.fn.has("nvim-0.11.0") == 0 then
    print("Lvim space required Neovim >= 0.11.0")
	return
end

if vim.g.loaded_lvim_cspace then
	return
end
vim.g.loaded_lvim_cspace = true

require("lvim-space").setup({})
