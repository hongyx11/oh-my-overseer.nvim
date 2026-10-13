vim.cmd([[set runtimepath+=.]])
vim.cmd([[runtime! plugin/plenary.vim]])
vim.cmd([[packadd telescope.nvim]])

vim.o.swapfile = false
vim.bo.swapfile = false
