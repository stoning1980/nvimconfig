-- Keymaps are automatically loaded on the VeryLazy event
-- Default keymaps that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/keymaps.lua
-- Add any additional keymaps here
-- <F2> ----------------------------------------------------------------
vim.keymap.set("n", "<F2>", function()
  Snacks.picker.git_grep()
end, { desc = "Search String (Git tracked)" })

vim.keymap.set("v", "<F2>", function()
  -- 1. Copy selection to register y
  vim.cmd('noau normal! "yy')
  local text = vim.fn.getreg("y")

  -- 2. git grep the selection with whole-word matching (-w passed to git grep)
  Snacks.picker.git_grep({
    search = text,
    cmd_args = { "-w" },
  })
end, { desc = "Search exact word only (Git tracked)" })

local map = vim.keymap.set

-- Register the `:Pdf` (HEAD vs previous commit) and `:CodeReview`
-- (HEAD vs local/remote branch, with branch-name completion) commands.
require("config.git_diff").setup()

-- F4: Toggle Diffview (Opens git index diff if closed, closes all diff tabs if open)
map("n", "<F3>", function()
  local lib = require("diffview.lib")
  local view = lib.get_current_view()
  if view then
    vim.cmd("DiffviewClose")
  else
    vim.cmd("DiffviewOpen")
  end
end, { desc = "Toggle Diffview" })
-- Leader, F4: Toggle File Panel (Maximizes space for the code diff)
map("n", "<F4>", "<cmd>DiffviewToggleFiles<cr>", { desc = "Toggle Diffview File Panel" })

-- <F5> ----------------------------------------------------------------
-- vim.keymap.set("n", "<F5>", "<leader>ff", { desc = "Find Files", remap = true })
vim.keymap.set("n", "<F5>", function()
  Snacks.picker.git_files()
end, { desc = "Search Git Files" })

vim.keymap.set("v", "<F5>", function()
  -- 1. Copy selection to the 'y' register
  vim.cmd('noau normal! "yy')
  -- 2. Get the text from the register
  local text = vim.fn.getreg("y")
  -- 3. Open Snacks git_files picker pre-filtered with that text
  Snacks.picker.git_files({ pattern = text })
end, { desc = "Find Git files by selection" })

-- lua/keymaps.lua

local function get_root_relative_path()
  local current_file = vim.fn.expand("%:p")
  if current_file == "" then
    return nil
  end

  local project_root = vim.fs.root(0, { ".git", "package.json", "Cargo.toml", "go.mod", "Makefile" })

  if project_root then
    local relative_path = vim.fn.fnamemodify(current_file, ":." .. project_root)
    if relative_path:sub(1, #project_root) == project_root then
      relative_path = current_file:sub(#project_root + 2)
    end
    return relative_path
  else
    return vim.fn.fnamemodify(current_file, ":.")
  end
end

-- Normal mode mapping: F9
--vim.keymap.set("n", "<F6>", function()
--  local path = get_root_relative_path()
--  if not path then
--    return
--  end
--
--  vim.fn.setreg("+", path)
--  vim.notify("Copied: " .. path, vim.log.levels.INFO)
--end, { desc = "Copy root relative file path" })

-- Visual mode mapping: F9
-- vim.keymap.set("v", "<F6>", function()
--   local path = get_root_relative_path()
--   if not path then
--     return
--   end
--
--   vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<ESC>", true, false, true), "x", true)
--
--   local start_line = vim.api.nvim_buf_get_mark(0, "<")[1]
--   local end_line = vim.api.nvim_buf_get_mark(0, ">")[1]
--
--   local result_text = path
--   if start_line == end_line then
--     result_text = string.format("%s, line %d", path, start_line)
--   else
--     result_text = string.format("%s, line %d-%d", path, start_line, end_line)
--   end
--
--   vim.fn.setreg("+", result_text)
--   vim.notify("Copied: " .. result_text, vim.log.levels.INFO)
-- end, { desc = "Copy root relative path with lines" })

-- List symbols / methods of the current file.
-- Uses LSP document symbols when a server is attached, otherwise falls back to
-- a Treesitter-based extractor (works for Kotlin in huge Android projects where
-- kotlin_language_server can't attach).
vim.keymap.set("n", "<F8>", function()
  require("config.ts_symbols").pick()
end, { desc = "Document Symbols (Current File)" })

-- Toggle Snacks terminal on the left split
vim.keymap.set("n", "<F11>", function()
  Snacks.terminal.toggle(nil, {
    win = {
      position = "left",
      width = 80,
    },
  })
end, { desc = "Toggle Left Snacks Terminal" })

-- Make sure F11 works inside Terminal mode to hide it
vim.keymap.set("t", "<F11>", function()
  Snacks.terminal.toggle(nil, {
    win = {
      position = "left",
      width = 80,
    },
  })
end, { desc = "Hide Left Snacks Terminal" })

-- Map F12 to resume the last Snacks picker search
-- Map F12 to resume the last Snacks picker search
vim.keymap.set("n", "<F12>", function()
  Snacks.picker.resume()
end, { desc = "Resume Last Search" })
