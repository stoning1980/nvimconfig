-- Keymaps are automatically loaded on the VeryLazy event
-- Default keymaps that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/keymaps.lua
-- Add any additional keymaps here
--
-- ┌─ Function key cheatsheet (this file + plugin keys) ──────────────────┐
-- │ F1      : n → toggle Diffview (status / commit / remote vs HEAD)     │
-- │ F2      : all modes → close buffers, open files vs a picked base     │
-- │ S-F1    : n → toggle Diffview file panel (:DiffviewToggleFiles)      │
-- │ S-F2    : n → open current diff's two sides in Beyond Compare        │
-- │ F3      : n → next diff hunk (Diffview only; error else)             │
-- │ S-F3    : n → next file (Diffview; error at end of list)             │
-- │ S-F4    : n → toggle git annotate panel (per-line author/date)       │
-- │ F4      : n → resume last Snacks picker search                       │
-- │ F5      : all modes → local branch, show HEAD, close session         │
-- │ S-F5    : all modes → remote branch, show HEAD, close session        │
-- │ F6      : n/i/t/c → :GitGrep (git-tracked) | v/s → grep selection    │
-- │ F7      : n → grep open buffers  |  v → grep selection in buffers    │
-- │ F8      : v → send selection | n → send buffered files (claudeide)   │
-- │ S-F8    : n → start Claude IDE server (auto_start off)               │
-- │ F9      : n → send file / v → send selection to AI agent (codechat)  │
-- │ S-F9    : n/v/t → close CodeChat window, terminal, and session       │
-- │ F10     : n → mark word / v → mark selection (interestingwords)      │
-- │ S-F10   : n → clear all interestingwords marks                       │
-- │ F11     : n → copy repo-rel path | v → repo-rel path + line range    │
-- │ S-F11   : n/v/i → copy-path menu (abs / rel / name / ~)              │
-- │ F12     : v → send selection | n → copy WORD to clipboard (adb)      │
-- │ S-F12   : n → Adb proxy menu (proxy on / proxy off)                  │
-- │ Note: terminals emit S-Fn as F(n+12): S-F1=F13 S-F12=F24 …           │
-- │ Commands without a key: :DiffviewCycleLayout (side-by-side ↔ stacked)│
-- │                         :DiffviewShowFile (this buffer in Diffview)  │
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
-- The prompt lists the uncommitted changes first, then HEAD against its parent
-- (`HEAD~..HEAD`), then the newest of origin/develop, origin/master,
-- origin/main, and origin/dev (by committer date; omitted when none exist),
-- then 20 recent commits. The first entry opens a working-tree
-- `:DiffviewOpen` that skips AI tool directories (see
-- `config.git_diff.ai_tool_dirs`); the second opens `HEAD~..HEAD`; a branch
-- opens `branch...HEAD`, i.e. what HEAD added since the merge-base.
--
-- The last entry re-opens the prompt with every remote branch. That listing is
-- the one slow query in a big repo (see lua/config/git_diff.lua), so it is kept
-- behind a deliberate choice instead of delaying the prompt for everyone.
--
-- When nvim was launched from the terminal wrapper purely to review a diff
-- (g:dv_from_terminal set by pdf/codereview/dvlc), closing the Diffview should
-- quit nvim entirely rather than drop into an empty session.
local WORKING_TREE = "Git status (uncommitted changes)"
local PREVIOUS_COMMIT = "Compare HEAD with its previous (HEAD~..HEAD)"
-- Matches a commit item from the picker: short hex SHA followed by a space.
local COMMIT_PAT = "^(%x%x%x%x+)%s"

-- The git range a picker choice stands for; nil means the uncommitted changes.
local function base_range(choice)
  if choice == WORKING_TREE then
    return nil
  elseif choice == PREVIOUS_COMMIT then
    return "HEAD~..HEAD"
  end
  local sha = choice:match(COMMIT_PAT)
  if sha then
    return sha .. "^.." .. sha
  end
  return choice .. "...HEAD"
end

-- Preview text for a picker choice. `edit` describes <F2> (open the changed
-- files as buffers) rather than <F1> (open a Diffview).
local function describe_base(choice, edit)
  local title, scope
  if choice == WORKING_TREE then
    title = "Working tree vs index + HEAD"
    local dirs = table.concat(require("config.git_diff").ai_tool_dirs, ", ")
    if edit then
      scope = "Staged, unstaged, and untracked files, leaving out AI tool directories (" .. dirs .. ")."
    else
      scope = "Staged and unstaged changes, leaving out AI tool directories (" .. dirs .. ")."
    end
  elseif choice == PREVIOUS_COMMIT then
    title, scope = "HEAD vs its parent", "The changes made by the last commit."
  else
    local sha = choice:match(COMMIT_PAT)
    if sha then
      title = sha
      scope = choice:sub(#sha + 2) .. "\n\nThe changes introduced by this single commit."
    else
      title, scope = choice .. " vs HEAD", "What HEAD added since its merge-base with " .. choice .. "."
    end
  end
  if edit then
    local body =
      "Closes other open buffers, then opens every changed file. Deleted files and AI tool directories are skipped."
    return ("%s\n\n%s\n\n%s"):format(title, body, scope)
  end
  local range = base_range(choice)
  return ("%s\n\n:DiffviewOpen%s\n\n%s"):format(title, range and (" " .. range) or "", scope)
end

local function open_base(choice)
  local range = base_range(choice)
  if range then
    vim.cmd("DiffviewOpen " .. range)
    return
  end
  local git_diff = require("config.git_diff")
  git_diff.arm_ai_tool_filter()
  local ok, err = pcall(vim.cmd, "DiffviewOpen")
  if not ok then
    git_diff.disarm_ai_tool_filter()
    error(err)
  end
end

-- The <F1>/<F2> base picker: uncommitted changes, HEAD~..HEAD, the newest
-- priority remote (origin/develop, origin/master, origin/main, origin/dev),
-- then 20 recent commits.
---@param opts { title: string, edit?: boolean }
---@param on_base fun(choice: string)
local function pick_base(opts, on_base)
  local idx = 0
  local function item(name)
    idx = idx + 1
    local preview = { text = describe_base(name, opts.edit), loc = false }
    return { text = idx .. " " .. name, item = name, idx = idx, preview = preview }
  end

  Snacks.picker.pick({
    source = "select",
    title = opts.title,
    format = Snacks.picker.format.ui_select({}),
    preview = "preview",
    layout = {
      config = function(layout)
        for _, box in ipairs(layout.layout) do
          if box.win == "list" and not box.height then
            box.height = math.max(math.floor(vim.o.lines * 0.8 - 10), 2)
          end
        end
      end,
    },
    finder = function(_, ctx)
      return function(cb)
        cb(item(WORKING_TREE))
        cb(item(PREVIOUS_COMMIT))
        local remotes, commits
        require("config.git_diff").get_picker_bases_async(function(r, c)
          remotes, commits = r, c
          ctx.async:resume()
        end)
        ctx.async:suspend()
        for _, name in ipairs(remotes or {}) do
          cb(item(name))
        end
        for _, line in ipairs(commits or {}) do
          cb(item(line))
        end
      end
    end,
    confirm = function(picker, it)
      picker:close()
      if it then
        vim.schedule(function()
          on_base(it.item)
        end)
      end
    end,
  })
end

local function toggle_diffview()
  if diffview_view() then
    if vim.g.dv_from_terminal then
      vim.cmd("qa")
    else
      vim.cmd("DiffviewClose")
    end
    return
  end
  pick_base({ title = "Diffview" }, open_base)
end

-- Like <F1>, but instead of a Diffview it closes the other buffers and opens
-- every file that differs from the chosen base as a regular, editable buffer.
-- AI tool directories are skipped for every base, using the same path check as
-- the Git status Diffview. From insert, visual, select, the command line, or a
-- terminal, drop to normal first, the same way <F5> does, then open the picker.
local function edit_changed_files()
  local function open()
    pick_base({ title = "Open changed files", edit = true }, function(choice)
      require("config.git_diff").edit_changed(base_range(choice))
    end)
  end
  if vim.fn.mode() == "n" then
    open()
    return
  end
  local keys = vim.api.nvim_replace_termcodes("<C-\\><C-N>", true, false, true)
  vim.api.nvim_feedkeys(keys, "n", false)
  vim.schedule(open)
end

-- Toggle the current Diffview's layout between side-by-side (left/right) and
-- stacked (top/bottom). On a normal two-file diff, including one opened with
-- F1, that is the whole cycle. Reachable as `:DiffviewCycleLayout`.
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

-- F2: Close the other buffers, then open the files that differ from a picked
-- base. Available in normal, insert, visual, select, command-line, and
-- terminal. The Diffview file panel toggle it used to hold is still
-- `:DiffviewToggleFiles`.
map({ "n", "i", "v", "x", "s", "t", "c" }, "<F2>", edit_changed_files, { desc = "Close buffers, open changed files" })

-- Give Snacks' `vim.ui.select` picker an integral list height, which it
-- otherwise miscomputes and crashes on (see lua/config/ui_select.lua).
require("config.ui_select").setup()

-- Register the `:Pdf` (local branch tip, branch~..branch), `:CompareHead` (HEAD vs a
-- previous commit), and `:EditDiff` (close other buffers, then open the files
-- that differ from a base branch, with branch-name completion, defaults to
-- origin/develop) commands.
require("config.git_diff").setup()

-- Make buffer switches (e.g. `,,`) inside a Diffview tab select that file in
-- the Diffview instead of breaking it, and register `:DiffviewShowFile`.
require("config.diffview_follow").setup()

-- Register the `:Goto` project switcher (recents + autojump.txt list).
require("config.goto").setup()

-- Register `:GitBranch` (local, like shell `lbr`) and `:GitRemoteBranch`
-- (remote, like shell `rbr`). A real checkout closes open files and the session.
require("config.git_branch").setup()

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

-- A diff side worth landing on: a live window that is not showing the empty
-- buffer diffview puts on the missing side of an added or deleted file. That
-- buffer is recognisable only by name — the window's `file.nulled` stays false
-- for it, since the file does exist on the other side of the diff.
local NULL_DIFF_BUF = "diffview://null"

local function diff_win_usable(win)
  if not (win and win.id and vim.api.nvim_win_is_valid(win.id)) then
    return false
  end
  return vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win.id)) ~= NULL_DIFF_BUF
end

-- F3: Jump to the next diff hunk — only inside a Diffview.
-- The ]c motion only works in a diff-mode window, so if focus is on the file
-- panel (or anywhere else) we jump into a diff window first. Land on the right
-- panel (`b`, which is what get_main_win() returns): that side holds HEAD's
-- copy, the one worth reading and the only one you can edit. Deleted files have
-- nothing there, so those fall back to the left panel (`a`).
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
  local ok, main = pcall(function()
    return layout:get_main_win()
  end)
  local win = ok and main or nil
  if not diff_win_usable(win) then
    local left = layout and layout.a
    win = diff_win_usable(left) and left or win
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
-- The last file stays put and reports an error; it does not wrap to the first.
local function index_of(list, item)
  for i, value in ipairs(list) do
    if value == item then
      return i
    end
  end
end

-- Files in panel order, plus the file currently open. Nil list means this view
-- has no file panel we know how to walk.
local function diff_file_list(view)
  local panel = view.panel
  if not panel then
    return nil
  end
  if panel.ordered_file_list then
    return panel:ordered_file_list(), panel.cur_file
  end
  if panel.entries then
    local files = {}
    for _, entry in ipairs(panel.entries) do
      for _, file in ipairs(entry.files or {}) do
        files[#files + 1] = file
      end
    end
    local cur = panel.cur_item and panel.cur_item[2] or nil
    return files, cur
  end
end

local function next_diff_file()
  local view = diffview_view()
  if not view then
    vim.notify("Not in a Diffview", vim.log.levels.ERROR, { title = "Diffview" })
    return
  end
  local files, cur = diff_file_list(view)
  if not files then
    require("diffview.actions").select_next_entry()
    return
  end
  local next_i
  if not cur then
    -- No current file opens the first entry, matching Diffview's own next-file.
    next_i = #files > 0 and 1 or nil
  else
    local i = index_of(files, cur)
    -- A step past the last file does not wrap back to the first.
    next_i = i and i + vim.v.count1 or nil
  end
  if not next_i or next_i > #files then
    vim.notify("End of file list", vim.log.levels.ERROR, { title = "Diffview" })
    return
  end
  view:set_file(files[next_i], false, true)
end
map("n", "<S-F3>", next_diff_file, { desc = "Next File (Diffview)" })
map("n", "<F15>", next_diff_file, { desc = "Next File (Diffview)" })

-- F5: pick a local branch (shell `lbr`) and check it out. Shift+F5 picks a
-- remote branch (shell `rbr`). Each row shows when that branch was last
-- committed and the commit message. The picker title, and the message after
-- checkout, show the HEAD branch name, such as foo. A detached checkout at
-- origin/foo is shown as foo. From insert, visual, or a terminal we first drop to normal
-- with <C-\><C-N>, then open the picker. Terminals emit Shift+F5 as <F17>.
-- A checkout that moves HEAD closes every open file.
local function switch_branch(remote)
  return function()
    local function open()
      require("config.git_branch").pick({ remote = remote })
    end
    if vim.fn.mode() == "n" then
      open()
      return
    end
    local keys = vim.api.nvim_replace_termcodes("<C-\\><C-N>", true, false, true)
    vim.api.nvim_feedkeys(keys, "n", false)
    vim.schedule(open)
  end
end

map({ "n", "i", "v", "x", "s", "t" }, "<F5>", switch_branch(false), { desc = "Switch local git branch" })
map({ "n", "i", "v", "x", "s", "t" }, "<S-F5>", switch_branch(true), { desc = "Switch remote git branch" })
map({ "n", "i", "v", "x", "s", "t" }, "<F17>", switch_branch(true), { desc = "Switch remote git branch" })

-- F6: :GitGrep — live grep over git-tracked files. Normal/insert/terminal/
-- cmdline → empty prompt; visual/select → seeded with the selection (first
-- line, matched literally).
map("n", "<F6>", function()
  require("config.git_grep").open()
end, { desc = "Git Grep" })

map({ "i", "t", "c" }, "<F6>", function()
  -- Leave insert/terminal/cmdline first; scheduled so the cmdline has closed.
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-\\><C-N>", true, false, true), "n", false)
  vim.schedule(function()
    require("config.git_grep").open()
  end)
end, { desc = "Git Grep" })

local select_to_visual = { s = "v", S = "V", ["\19"] = "\22" }
map({ "x", "s" }, "<F6>", function()
  -- Same capture as the visual <F7> below: getregion, then a synchronous <Esc>.
  local mode = vim.fn.mode()
  local region = vim.fn.getregion(vim.fn.getpos("v"), vim.fn.getpos("."), { type = select_to_visual[mode] or mode })
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
  require("config.git_grep").open({ search = region[1] or "" })
end, { desc = "Git Grep selection" })

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

-- Shift+F4: toggle an Android Studio / JetBrains style "Annotate" panel — a
-- scroll-bound left split showing author + date for every line. Press q inside
-- the panel (or Shift+F4 again) to close it. Terminals emit shifted F4 as <F16>,
-- so map both spellings.
local function toggle_git_annotate()
  require("config.git_annotate").toggle()
end
map("n", "<S-F4>", toggle_git_annotate, { desc = "Toggle Git Annotate Panel" })
map("n", "<F16>", toggle_git_annotate, { desc = "Toggle Git Annotate Panel" })

-- Shift+F1: toggle Diffview's file panel. Terminals emit shifted F1 as <F13>.
map("n", "<S-F1>", "<cmd>DiffviewToggleFiles<cr>", { desc = "Toggle Diffview File Panel" })
map("n", "<F13>", "<cmd>DiffviewToggleFiles<cr>", { desc = "Toggle Diffview File Panel" })

-- F7: grep across open buffers (like F6, but scoped to loaded buffers instead
-- of git-tracked files). Normal → prompt for the search string; visual → grep
-- the selection immediately.
-- need_search = true overrides the grep_buffers default (false), which would
-- otherwise grep every line of every buffer with an empty pattern and keep
-- re-ranking that streaming list — that churn resets the selection so <c-n>/
-- <c-p> can't move it. Requiring a term yields a stable list like F6 (:GitGrep).
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
