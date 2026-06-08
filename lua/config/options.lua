-- Options are automatically loaded before lazy.nvim startup
-- Default options that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/options.lua
-- Add any additional options here
vim.g.mapleader = ","
vim.g.maplocalleader = ","

vim.opt.number = true
vim.opt.relativenumber = true

-- This tells the LazyVim utility to show the full relative path instead of shortening it
-- vim.g.lazyvim_statusline_path = 3 -- 0: Name, 1: Relative (Pretty), 2: Full Relative, 3: Absolute
vim.g.lazyvim_picker = "snacks"

-- Thicker split characters so panel boundaries are easier to see.
vim.opt.fillchars:append({
  vert = "┃",
  horiz = "━",
})
