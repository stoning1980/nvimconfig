-- Keymaps are automatically loaded on the VeryLazy event
-- Default keymaps that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/keymaps.lua
-- Add any additional keymaps here
--
-- ┌─ Function key cheatsheet (custom mappings in this file) ─────────────┐
-- │ F1      : n → toggle Diffview (git index diff)                       │
-- │ F2      : n → toggle Diffview file panel                             │
-- │ S-F1/F2 : n → toggle Diffview layout (side-by-side ↔ stacked)       │
-- │ F3      : n → next diff hunk (Diffview only; error else)             │
-- │ S-F3    : n → next file entry (Diffview only)                        │
-- │ F4      : n → git grep string  |  v → git grep exact word (sel.)     │
-- │ F5      : n → find git files   |  v → find git files by selection    │
-- │ F6      : v → send selection to Claude IDE (claudeide.lua)           │
-- │ F7      : n → send file / v → send selection to AI agent (codechat)  │
-- │ F8      : n → document symbols of current file (LSP / Treesitter)    │
-- │ F9/F10  : (unmapped)                                                 │
-- │ F11     : n/t → toggle left Snacks terminal                         │
-- │ F12     : n → resume last Snacks picker search                       │
-- └─────────────────────────────────────────────────────────────────────┘

local map = vim.keymap.set

-- Shared Diffview helpers -----------------------------------------------------
local function diffview_view()
  local ok, lib = pcall(require, "diffview.lib")
  if not ok then
    return nil
  end
  return lib.get_current_view()
end

-- Toggle Diffview: open git index diff if closed, close all diff tabs if open.
-- When nvim was launched from the terminal wrapper purely to review a diff
-- (g:dv_from_terminal set by pdf/codereview/dvlc), closing the Diffview should
-- quit nvim entirely rather than drop into an empty session.
local function toggle_diffview()
  if diffview_view() then
    if vim.g.dv_from_terminal then
      vim.cmd("qa")
    else
      vim.cmd("DiffviewClose")
    end
  else
    vim.cmd("DiffviewOpen")
  end
end

-- Toggle the current Diffview's layout between side-by-side (left/right) and
-- stacked (top/bottom) — handy for long-line diffs. No-op when no Diffview open.
local function cycle_diffview_layout()
  if not diffview_view() then
    vim.notify("No Diffview open", vim.log.levels.INFO, { title = "Diffview" })
    return
  end
  require("diffview.actions").cycle_layout()
end

-- git grep the visual selection with whole-word matching (-w passed to git grep)
local function git_grep_selection_word()
  vim.cmd('noau normal! "yy')
  local text = vim.fn.getreg("y")
  Snacks.picker.git_grep({
    search = text,
    cmd_args = { "-w" },
  })
end

-- F1: Toggle Diffview.
map("n", "<F1>", toggle_diffview, { desc = "Toggle Diffview" })

-- F2: Toggle the Diffview file panel (maximizes space for the code diff).
map("n", "<F2>", "<cmd>DiffviewToggleFiles<cr>", { desc = "Toggle Diffview File Panel" })

-- Shift+F1 / Shift+F2: Toggle Diffview layout (H/V). Terminals emit shifted
-- function keys as <F13>/<F14>, so map both spellings.
map("n", "<S-F1>", cycle_diffview_layout, { desc = "Toggle Diffview Layout (H/V)" })
map("n", "<S-F2>", cycle_diffview_layout, { desc = "Toggle Diffview Layout (H/V)" })
map("n", "<F13>", cycle_diffview_layout, { desc = "Toggle Diffview Layout (H/V)" })
map("n", "<F14>", cycle_diffview_layout, { desc = "Toggle Diffview Layout (H/V)" })

-- Register the `:Pdf` (HEAD vs previous commit) and `:CodeReview`
-- (HEAD vs local/remote branch, with branch-name completion) commands.
require("config.git_diff").setup()

-- F3 / Shift+F3: Jump to next / previous diff hunk — only inside a Diffview.
-- The ]c / [c motions only work in a diff-mode window, so if focus is on the
-- file panel (or anywhere else) we jump into a diff window first. Prefer the
-- left panel (`a`) — get_main_win() returns the right panel (`b`), but the left
-- reads more naturally right after the file panel; fall back to the main win
-- when the left side is null (e.g. added files) or otherwise unavailable.
local function goto_diff_hunk(motion)
  local view = diffview_view()
  if not view then
    vim.notify("Not in a Diffview", vim.log.levels.ERROR, { title = "Diffview" })
    return
  end
  local layout = view.cur_layout
  local win = layout and layout.a
  if not (win and win.id and vim.api.nvim_win_is_valid(win.id)) then
    local ok, main = pcall(function()
      return layout:get_main_win()
    end)
    win = ok and main or nil
  end
  if win and win.id and vim.api.nvim_win_is_valid(win.id) then
    vim.api.nvim_set_current_win(win.id)
  end
  vim.cmd("normal! " .. motion)
end

map("n", "<F3>", function()
  goto_diff_hunk("]c")
end, { desc = "Next Diff Hunk (Diffview)" })

-- Shift+F3: jump to the next file entry in the Diffview (vs. next hunk on F3).
-- Terminals may emit shifted F3 as <F15>. Only meaningful inside a Diffview.
local function next_diff_file()
  if not diffview_view() then
    vim.notify("Not in a Diffview", vim.log.levels.ERROR, { title = "Diffview" })
    return
  end
  require("diffview.actions").select_next_entry()
end
map("n", "<S-F3>", next_diff_file, { desc = "Next File (Diffview)" })
map("n", "<F15>", next_diff_file, { desc = "Next File (Diffview)" })

-- F4: git grep. Normal → search string; visual → exact word from selection.
map("n", "<F4>", function()
  Snacks.picker.git_grep()
end, { desc = "Search String (Git tracked)" })
map("v", "<F4>", git_grep_selection_word, { desc = "Search exact word only (Git tracked)" })

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
