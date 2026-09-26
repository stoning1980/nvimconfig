-- Keymaps are automatically loaded on the VeryLazy event
-- Default keymaps that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/keymaps.lua
-- Add any additional keymaps here
--
-- ┌─ Function key cheatsheet (this file + plugin keys) ──────────────────┐
-- │ F1      : n → toggle Diffview (pick: git status / branch vs HEAD)    │
-- │ F2      : n → toggle Diffview file panel                             │
-- │ S-F1    : n → toggle git annotate panel (per-line author/date)       │
-- │ S-F2    : n → open current diff's two sides in Beyond Compare        │
-- │ F3      : n → next diff hunk (Diffview only; error else)             │
-- │ S-F3    : n → next file entry (Diffview only)                        │
-- │ F4      : n → resume last Snacks picker search                       │
-- │ F5      : all modes → jump back (jumplist <C-o>)                     │
-- │ F6      : all modes → jump forward (jumplist <C-i>)                  │
-- │ F7      : n → grep open buffers  |  v → grep selection in buffers    │
-- │ F8      : v → send selection | n → send buffered files (claudeide)   │
-- │ S-F8    : n → start Claude IDE server (auto_start off)               │
-- │ F9      : n → send file / v → send selection to AI agent (codechat)  │
-- │ F10     : n → mark word / v → mark selection (interestingwords)      │
-- │ S-F10   : n → clear all interestingwords marks                       │
-- │ F11     : n → copy repo-rel path | v → repo-rel path + line range    │
-- │ S-F11   : n/v/i → copy-path menu (abs / rel / name / ~)              │
-- │ F12     : v → selection | n → word under cursor / clipboard (adb)    │
-- │ S-F12   : n → AdbHelper action menu (A/B debug/relaunch/kill/clear)  │
-- │ Note: terminals emit S-Fn as F(n+12): S-F1=F13 S-F12=F24 …           │
-- │ Commands without a key: :DiffviewCycleLayout (side-by-side ↔ stacked)│
-- │                         :GitGrep (grep git-tracked files only)       │
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

-- Toggle Diffview: close all diff tabs if one is open, else ask what to diff.
--
-- The prompt lists the uncommitted changes first, then the same ordered branch
-- list `:CodeReview`/`:EditDiff` complete against (origin/develop first). The
-- first entry opens a bare `:DiffviewOpen` (working tree vs index+HEAD); a
-- branch opens `branch...HEAD`, i.e. what HEAD added since the merge-base.
--
-- When nvim was launched from the terminal wrapper purely to review a diff
-- (g:dv_from_terminal set by pdf/codereview/dvlc), closing the Diffview should
-- quit nvim entirely rather than drop into an empty session.
local WORKING_TREE = "Git status (uncommitted changes)"

local function toggle_diffview()
  if diffview_view() then
    if vim.g.dv_from_terminal then
      vim.cmd("qa")
    else
      vim.cmd("DiffviewClose")
    end
    return
  end

  local choices = { WORKING_TREE }
  vim.list_extend(choices, require("config.git_diff").get_branches())

  vim.ui.select(choices, { prompt = "Diffview:" }, function(choice)
    if not choice then
      return
    end
    if choice == WORKING_TREE then
      vim.cmd("DiffviewOpen")
    else
      vim.cmd("DiffviewOpen " .. choice .. "...HEAD")
    end
  end)
end

-- Toggle the current Diffview's layout between side-by-side (left/right) and
-- stacked (top/bottom) — handy for long-line diffs. No-op when no Diffview open.
-- Reachable as `:DiffviewCycleLayout`; it has no key binding because <S-F2> now
-- opens Beyond Compare instead.
local function cycle_diffview_layout()
  if not diffview_view() then
    vim.notify("No Diffview open", vim.log.levels.INFO, { title = "Diffview" })
    return
  end
  require("diffview.actions").cycle_layout()
end

vim.api.nvim_create_user_command("DiffviewCycleLayout", cycle_diffview_layout, {
  nargs = 0,
  desc = "Toggle Diffview layout (side-by-side ↔ stacked)",
})

-- F1: Toggle Diffview (picks a base when opening).
map("n", "<F1>", toggle_diffview, { desc = "Toggle Diffview" })

-- F2: Toggle the Diffview file panel (maximizes space for the code diff).
map("n", "<F2>", "<cmd>DiffviewToggleFiles<cr>", { desc = "Toggle Diffview File Panel" })

-- Give Snacks' `vim.ui.select` picker an integral list height, which it
-- otherwise miscomputes and crashes on (see lua/config/ui_select.lua).
require("config.ui_select").setup()

-- Register the `:Pdf` (a commit's own changes), `:CompareHead` (HEAD vs a
-- previous commit), `:CodeReview` (HEAD vs local/remote branch, with
-- branch-name completion), `:EditDiff` (open the files that differ from a base
-- branch as buffers, same branch completion, defaults to origin/develop) and
-- `:DiffThisFile` (diff the focused file against a branch, same completion and
-- default) commands.
require("config.git_diff").setup()

-- Register the `:Goto` project switcher (recents + autojump.txt list).
require("config.goto").setup()

-- Register `:GitGrep` — live grep over git-tracked files via `git grep`, which
-- is dramatically faster than rg in very large repos (see lua/config/git_grep.lua).
require("config.git_grep").setup()

-- Register `:BeyondCompare` and bind it to Shift+F2: hand the two sides of the
-- current diff (Diffview entry, or any plain diff split) to Beyond Compare,
-- whose side-by-side rendering is much easier to read for large files.
-- Terminals emit shifted F2 as <F14>, so map both spellings.
require("config.beyond_compare").setup()

local function open_beyond_compare()
  require("config.beyond_compare").open()
end
map("n", "<S-F2>", open_beyond_compare, { desc = "Open diff in Beyond Compare" })
map("n", "<F14>", open_beyond_compare, { desc = "Open diff in Beyond Compare" })

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

-- F5 / F6: navigate the jumplist backward / forward, like an IDE's back/forward
-- buttons. <C-o> / <C-i> are normal-mode motions, so from any other mode we first
-- drop to normal with <C-\><C-N> (works from insert, visual, and terminal) and
-- then perform the jump. Feeding the keys with noremap ("n") keeps <C-i> as the
-- jumplist motion rather than an <expr>/remapped Tab.
local function jumplist(motion)
  return function()
    local keys = vim.api.nvim_replace_termcodes("<C-\\><C-N>" .. motion, true, false, true)
    vim.api.nvim_feedkeys(keys, "n", false)
  end
end

map({ "n", "i", "v", "x", "s", "t" }, "<F5>", jumplist("<C-o>"), { desc = "Jump back" })
map({ "n", "i", "v", "x", "s", "t" }, "<F6>", jumplist("<C-i>"), { desc = "Jump forward" })

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
-- the panel (or Shift+F1 again) to close it. Terminals emit shifted F1 as <F13>,
-- so map both spellings.
local function toggle_git_annotate()
  require("config.git_annotate").toggle()
end
map("n", "<S-F1>", toggle_git_annotate, { desc = "Toggle Git Annotate Panel" })
map("n", "<F13>", toggle_git_annotate, { desc = "Toggle Git Annotate Panel" })

-- F7: grep across open buffers (like F6, but scoped to loaded buffers instead
-- of git-tracked files). Normal → prompt for the search string; visual → grep
-- the selection immediately.
-- need_search = true overrides the grep_buffers default (false), which would
-- otherwise grep every line of every buffer with an empty pattern and keep
-- re-ranking that streaming list — that churn resets the selection so <c-n>/
-- <c-p> can't move it. Requiring a term yields a stable list like F6.
map("n", "<F7>", function()
  Snacks.picker.grep_buffers({ need_search = true })
end, { desc = "Grep Open Buffers" })

map("v", "<F7>", function()
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

-- Map F4 to resume the last Snacks picker search
vim.keymap.set("n", "<F4>", function()
  Snacks.picker.resume()
end, { desc = "Resume Last Search" })

-- Visual-mode pickers seeded with the selection --------------------------------
-- LazyVim binds <leader><space>, <leader>, and <leader>/ in normal mode only, so
-- in visual mode they fall back to their prefix (e.g. `,` = repeat find-char) and
-- appear "broken". These wrappers grab the selection and open the same pickers
-- pre-filled with it. Capturing via getregion + a synchronous <Esc> mirrors the
-- <F7> handler above: a "yy yank inside a visual mapping can strand nvim in
-- operator-pending, and its embedded newlines break fixed-string searches.
local function visual_selection_text()
  local region = vim.fn.getregion(vim.fn.getpos("v"), vim.fn.getpos("."), { type = vim.fn.mode() })
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
  -- Picker inputs are single-line; if several lines are selected, use the first.
  return region[1] or ""
end

-- <leader><space>: find files, pre-filtered by the selection (matches filename).
map("x", "<leader><space>", function()
  local text = visual_selection_text()
  Snacks.picker.files({ pattern = text })
end, { desc = "Find Files (selection)" })

-- <leader>,: switch buffer, pre-filtered by the selection (matches buffer name).
map("x", "<leader>,", function()
  local text = visual_selection_text()
  Snacks.picker.buffers({ pattern = text })
end, { desc = "Buffers (selection)" })

-- <leader>/: grep the selection literally (regex = false → rg --fixed-strings).
map("x", "<leader>/", function()
  local text = visual_selection_text()
  if text == "" then
    return
  end
  Snacks.picker.grep({ search = text, regex = false, need_search = true })
end, { desc = "Grep (selection)" })
