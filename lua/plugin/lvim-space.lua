if vim.fn.has("nvim-0.10.0") == 0 then
    print("Lvim space requires Neovim >= 0.10.0")
    return
end

if vim.g.loaded_lvim_cspace then
    return
end
vim.g.loaded_lvim_cspace = true

require("lvim-space").setup({})
