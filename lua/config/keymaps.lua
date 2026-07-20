-- Keymaps are automatically loaded on the VeryLazy event
-- Default keymaps that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/keymaps.lua
-- Add any additional keymaps here
--
-- ┌─ Function key cheatsheet (this file + plugin keys) ──────────────────┐
-- │ F1      : n → toggle Diffview (git index diff)                       │
-- │ F2      : n → toggle Diffview file panel                             │
-- │ S-F1    : n → toggle git annotate panel (per-line author/date)       │
-- │ S-F2    : n → toggle Diffview layout (side-by-side ↔ stacked)        │
-- │ F3      : n → next diff hunk (Diffview only; error else)             │
-- │ S-F3    : n → next file entry (Diffview only)                        │
-- │ F4      : v → selection | n → word under cursor / clipboard (adb)    │
-- │ S-F4    : n → AdbHelper action menu (A/B debug/relaunch/kill/clear)  │
-- │ F5      : n → grep open buffers  |  v → grep selection in buffers    │
-- │ F6      : n → git grep string  |  v → git grep literal word (sel.)   │
-- │ F7      : n → find git files   |  v → find git files by selection    │
-- │ F8      : v → send selection | n → send buffered files (claudeide)   │
-- │ F9      : n → send file / v → send selection to AI agent (codechat)  │
-- │ F10     : n → mark word / v → mark selection (interestingwords)      │
-- │ S-F10   : n → clear all interestingwords marks                       │
-- │ F11     : n → copy repo-rel path | v → repo-rel path + line range    │
-- │ S-F11   : n/v/i → copy-path menu (abs / rel / name / ~)              │
-- │ F12     : n → resume last Snacks picker search                       │
-- │ Note: terminals emit S-Fn as F(n+12): S-F1=F13 S-F2=F14 S-F4=F16 …   │
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

-- git grep the visual selection literally, whole-word only. -F treats the text
-- as a fixed string (so parens/dots aren't regex), -w restricts to whole words.
local function git_grep_selection_word()
  vim.cmd('noau normal! "yy')
  local text = vim.fn.getreg("y")
  Snacks.picker.git_grep({
    search = text,
    cmd_args = { "-w", "-F" },
  })
end

-- F1: Toggle Diffview.
map("n", "<F1>", toggle_diffview, { desc = "Toggle Diffview" })

-- F2: Toggle the Diffview file panel (maximizes space for the code diff).
map("n", "<F2>", "<cmd>DiffviewToggleFiles<cr>", { desc = "Toggle Diffview File Panel" })

-- Shift+F2: Toggle Diffview layout (H/V). Terminals emit shifted F2 as <F14>,
-- so map both spellings.
map("n", "<S-F2>", cycle_diffview_layout, { desc = "Toggle Diffview Layout (H/V)" })
map("n", "<F14>", cycle_diffview_layout, { desc = "Toggle Diffview Layout (H/V)" })

-- Register the `:Pdf` (HEAD vs previous commit) and `:CodeReview`
-- (HEAD vs local/remote branch, with branch-name completion) commands.
require("config.git_diff").setup()

-- Register the `:Goto` project switcher (recents + autojump.txt list).
require("config.goto").setup()

-- F3 / Shift+F3: Jump to next / previous diff hunk — only inside a Diffview.
-- The ]c / [c motions only work in a diff-mode window, so if focus is on the
-- file panel (or anywhere else) we jump into a diff window first. Prefer the
-- left panel (`a`) — get_main_win() returns the right panel (`b`), but the left
-- reads more naturally right after the file panel; fall back to the main win
-- when the left side is null (e.g. added files) or otherwise unavailable.
local function goto_diff_hunk(motion)
  local view = diffview_view()
  if not view then
    -- Outside Diffview, still support a plain diff-mode window (e.g. the
    -- :CompareFiles / :diffsplit view): the ]c / [c motions work there directly.
    if vim.wo.diff then
      vim.cmd("normal! " .. motion)
    else
      vim.notify("Not in a diff view", vim.log.levels.ERROR, { title = "Diffview" })
    end
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

-- F6: git grep. Normal → regex search string; visual → literal whole-word match
-- of the selection (see git_grep_selection_word).
map("n", "<F6>", function()
  Snacks.picker.git_grep()
end, { desc = "Search String (Git tracked)" })
map("v", "<F6>", git_grep_selection_word, { desc = "Search exact word only (Git tracked)" })

-- <F7> ----------------------------------------------------------------
-- vim.keymap.set("n", "<F7>", "<leader>ff", { desc = "Find Files", remap = true })
vim.keymap.set("n", "<F7>", function()
  Snacks.picker.git_files()
end, { desc = "Search Git Files" })

vim.keymap.set("v", "<F7>", function()
  -- 1. Copy selection to the 'y' register
  vim.cmd('noau normal! "yy')
  -- 2. Get the text from the register
  local text = vim.fn.getreg("y")
  -- 3. Open Snacks git_files picker pre-filtered with that text
  Snacks.picker.git_files({ pattern = text })
end, { desc = "Find Git files by selection" })

-- Path-copy helpers -----------------------------------------------------------

-- Copy text to the system clipboard and echo what was copied.
local function copy_path(text)
  if not text or text == "" then
    vim.notify("No file path to copy", vim.log.levels.WARN, { title = "Copy Path" })
    return
  end
  vim.fn.setreg("+", text)
  vim.notify("Copied: " .. text, vim.log.levels.INFO, { title = "Copy Path" })
end

-- Repo-relative path of the current buffer. Falls back to a home-relative path
-- when the file lives outside any recognized project root, and nil for unnamed
-- buffers.
local function repo_relative_path()
  local abs = vim.fn.expand("%:p")
  if abs == "" then
    return nil
  end
  local root = vim.fs.root(0, { ".git", "package.json", "Cargo.toml", "go.mod", "Makefile" })
  if root and abs:sub(1, #root + 1) == root .. "/" then
    return abs:sub(#root + 2)
  end
  return vim.fn.fnamemodify(abs, ":~")
end

-- Start/end line of the current visual selection (ascending).
local function visual_line_range()
  local l1, l2 = vim.fn.line("v"), vim.fn.line(".")
  if l1 > l2 then
    l1, l2 = l2, l1
  end
  return l1, l2
end

-- F10: mark matching text in a distinct color (interestingwords.nvim). Normal
-- mode marks the word under the cursor; visual mode marks the selection. Every
-- occurrence of the same text gets the same color across all open and future
-- buffers; press F10 again on it to unmark. Shift+F10 clears every mark
-- (terminals emit shifted F10 as <F22>, so map both spellings).
vim.keymap.set("n", "<F10>", function()
  require("interestingwords").InterestingWord("n", false)
end, { desc = "Mark word under cursor" })

vim.keymap.set("x", "<F10>", function()
  require("interestingwords").InterestingWord("v", false)
end, { desc = "Mark selection" })

local function clear_marks()
  require("interestingwords").UncolorAllWords()
end
vim.keymap.set("n", "<S-F10>", clear_marks, { desc = "Clear all marks" })
vim.keymap.set("n", "<F22>", clear_marks, { desc = "Clear all marks" })

-- Shift+F1: toggle an Android Studio / JetBrains style "Annotate" panel — a
-- scroll-bound left split showing author + date for every line. Press q inside
-- the panel (or Shift+F1 again) to close it. Terminals emit shifted F1 as
-- <F13>, so map both spellings.
local function toggle_git_annotate()
  require("config.git_annotate").toggle()
end
map("n", "<S-F1>", toggle_git_annotate, { desc = "Toggle Git Annotate Panel" })
map("n", "<F13>", toggle_git_annotate, { desc = "Toggle Git Annotate Panel" })

-- F5: grep across open buffers (like F6, but scoped to loaded buffers instead
-- of git-tracked files). Normal → prompt for the search string; visual → grep
-- the selection immediately.
-- need_search = true overrides the grep_buffers default (false), which would
-- otherwise grep every line of every buffer with an empty pattern and keep
-- re-ranking that streaming list — that churn resets the selection so <c-n>/
-- <c-p> can't move it. Requiring a term yields a stable list like F6.
map("n", "<F5>", function()
  Snacks.picker.grep_buffers({ need_search = true })
end, { desc = "Grep Open Buffers" })

map("v", "<F5>", function()
  -- Capture the selection before touching modes or registers. Grabbing it with a
  -- `"yy` yank inside a visual mapping is fragile: it can leave a dangling `y`
  -- operator (nvim gets stuck in operator-pending, "can't exit"), and it yanks
  -- the whole multi-line block whose embedded newlines break the fixed-string
  -- (regex = false) search.
  local region = vim.fn.getregion(vim.fn.getpos("v"), vim.fn.getpos("."), { type = vim.fn.mode() })
  -- Leave visual mode synchronously ("x") so the picker opens in a clean state.
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
  -- A grep term is a single line; if several were selected, search the first.
  local text = region[1] or ""
  if text == "" then
    return
  end
  -- regex = false → rg --fixed-strings, so the selection matches literally
  -- (e.g. "oncomplete()" isn't treated as a regex with an empty group).
  Snacks.picker.grep_buffers({ search = text, regex = false, need_search = true })
end, { desc = "Grep selection in Open Buffers" })

-- F11: copy the repo-relative path of the current file. In visual mode the
-- selected line range is appended (path:start or path:start-end).
map("n", "<F11>", function()
  copy_path(repo_relative_path())
end, { desc = "Copy repo-relative path" })

map("v", "<F11>", function()
  local rel = repo_relative_path()
  if not rel then
    copy_path(nil)
    return
  end
  local l1, l2 = visual_line_range()
  copy_path(l1 == l2 and (rel .. ":" .. l1) or (rel .. ":" .. l1 .. "-" .. l2))
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "n", false)
end, { desc = "Copy repo-relative path + line range" })

-- Shift+F11: pick which representation of the current file path to copy.
-- Terminals emit shifted F11 as <F23>, so map both spellings. Available in
-- normal, visual and insert modes (the menu reads the file, not the selection).
local function copy_path_menu()
  local abs = vim.fn.expand("%:p")
  if abs == "" then
    copy_path(nil)
    return
  end
  local rel = repo_relative_path()
  local items = {
    { label = "Absolute path", value = abs },
    { label = "Repo-relative path", value = rel },
    { label = "File name (with extension)", value = vim.fn.expand("%:t") },
    { label = "File name (no extension)", value = vim.fn.expand("%:t:r") },
    { label = "Home-relative path", value = vim.fn.expand("%:p:~") },
  }
  vim.ui.select(items, {
    prompt = "Copy path as:",
    format_item = function(item)
      return item.label .. "  →  " .. (item.value or "n/a")
    end,
  }, function(choice)
    if choice then
      copy_path(choice.value)
    end
  end)
end

map({ "n", "v", "i" }, "<S-F11>", copy_path_menu, { desc = "Copy path (menu)" })
map({ "n", "v", "i" }, "<F23>", copy_path_menu, { desc = "Copy path (menu)" })

-- Map F12 to resume the last Snacks picker search
-- Map F12 to resume the last Snacks picker search
vim.keymap.set("n", "<F12>", function()
  Snacks.picker.resume()
end, { desc = "Resume Last Search" })
