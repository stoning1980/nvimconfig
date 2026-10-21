-- Diffview review commands:
--   :Pdf          show one commit's own changes (Tab: last 20 commits incl. HEAD)
--   :CompareHead  compare HEAD with a previous commit (Tab: last 20 ancestors)
--   :EditDiff     close other buffers, then open every file differing from a
--                 base branch (Tab: ordered branches, defaults to origin/develop;
--                 confirms past 20 files; skips AI tool directories)
--   :CompareFiles diff two repo files picked from a fuzzy list (Tab to select two)
--   :DiffThisFile diff the focused file against a version (same branch list as
--                 :EditDiff, defaults to origin/develop)
--   :CompareVersionFile pick a version (Tab to complete), then a file, to diff
--                 HEAD's copy of that file against the chosen version's copy
local M = {}

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = "Diffview" })
end

-- Remote base branches surfaced at the very top of the list, in this order.
local PRIORITY_REMOTES = { "origin/develop", "origin/master", "origin/main", "origin/dev" }

-- Cap on remote branches to list (after the priority ones), when the full
-- listing is asked for. Keeps the picker manageable in repos with thousands of
-- remote branches.
local MAX_REMOTES = 100

local function git_lines(args)
  local out = vim.fn.systemlist(args)
  if vim.v.shell_error ~= 0 then
    return nil
  end
  local res = {}
  for _, line in ipairs(out) do
    line = vim.trim(line)
    if line ~= "" then
      table.insert(res, line)
    end
  end
  return res
end

-- Local branches, newest-committed first. Cheap: a repo has few of them.
local LOCALS_ARGS = { "git", "for-each-ref", "--sort=-committerdate", "--format=%(refname:short)", "refs/heads/" }

-- Which PRIORITY_REMOTES exist. Asking for those refs by name keeps this to one
-- cheap for-each-ref no matter how many remote branches the repo has.
local PRIORITY_REFS = {}
for _, p in ipairs(PRIORITY_REMOTES) do
  table.insert(PRIORITY_REFS, "refs/remotes/" .. p)
end

local function for_each_priority(format)
  local args = { "git", "for-each-ref", "--format=" .. format }
  for _, ref in ipairs(PRIORITY_REFS) do
    table.insert(args, ref)
  end
  return args
end

local PRIORITY_ARGS = for_each_priority("%(refname:short)")
-- Same refs, with the tip's committer time, so the F1/F2 picker can keep only
-- the most recently updated one.
local PRIORITY_DATE_ARGS = for_each_priority("%(committerdate:unix) %(refname:short)")

-- Every remote branch, newest-committed first. This is the slow listing:
-- `--sort=-committerdate` makes git read a commit object for every remote ref,
-- which takes ~5s in a repo with 13k of them (unsorted, the same refs take
-- 40ms). Callers opt into it explicitly; see get_branches. We ask for a few
-- extra refs to absorb the symbolic "origin/HEAD" pointer filtered out below.
local REMOTES_ARGS = {
  "git",
  "for-each-ref",
  "--sort=-committerdate",
  "--count=" .. (MAX_REMOTES + 5),
  "--format=%(refname:short)",
  "refs/remotes/",
}

-- The 20 commits after HEAD, for the F1/F2 picker. skip=1 drops HEAD itself
-- (already shown as "HEAD~ .. HEAD" in the picker).
local RECENT_COMMITS_ARGS = {
  "git",
  "log",
  "--skip=1",
  "--max-count=20",
  "--format=%h %s",
  "HEAD",
}

local function filter_remotes(lines)
  local remotes = {}
  for _, r in ipairs(lines or {}) do
    if r:find("/") and not r:find("HEAD") then
      table.insert(remotes, r)
      if #remotes >= MAX_REMOTES then
        break
      end
    end
  end
  return remotes
end

local function as_set(lines)
  local set = {}
  for _, l in ipairs(lines or {}) do
    set[l] = true
  end
  return set
end

-- Branch names ordered for quick review selection:
--   1-4. origin/develop, origin/master, origin/main, origin/dev (if present)
--   5.   local branches, newest-committed first
-- With remotes supplied, the 3 newest locals come first, then the remotes, then
-- the remaining locals.
local function order_branches(locals, priority, remotes)
  local seen = {}
  local ordered = {}
  local function add(name)
    if name and name ~= "" and not seen[name] then
      seen[name] = true
      table.insert(ordered, name)
    end
  end

  for _, p in ipairs(PRIORITY_REMOTES) do
    if priority[p] then
      add(p)
    end
  end
  for i = 1, math.min(3, #locals) do
    add(locals[i])
  end
  for _, r in ipairs(remotes or {}) do
    add(r)
  end
  for _, l in ipairs(locals) do
    add(l)
  end

  return ordered
end

-- List branches, blocking until git answers.
--
-- The two queries behind the default list are cheap, so Tab completion (which
-- has to return a value synchronously) can afford them. The remote branches
-- beyond the priority ones are the expensive listing, so they are left out
-- unless `opts.all_remotes` asks for them. Nothing is lost by leaving them out:
-- every command here also takes a raw branch name, which needs no listing.
---@param opts? { all_remotes?: boolean }
local function get_branches(opts)
  local locals = git_lines(LOCALS_ARGS)
  if not locals then
    notify("Failed to list branches (not a git repo?)", vim.log.levels.ERROR)
    return {}
  end
  local remotes = opts and opts.all_remotes and filter_remotes(git_lines(REMOTES_ARGS)) or {}
  return order_branches(locals, as_set(git_lines(PRIORITY_ARGS)), remotes)
end

M.get_branches = get_branches

-- Run a git command asynchronously. The callback receives the trimmed output
-- lines (nil on failure) in a vim.schedule context.
local function git_async(args, done)
  vim.system(args, { text = true }, function(res)
    local lines = nil
    if res.code == 0 then
      lines = {}
      for _, line in ipairs(vim.split(res.stdout or "", "\n")) do
        line = vim.trim(line)
        if line ~= "" then
          table.insert(lines, line)
        end
      end
    end
    vim.schedule(function()
      done(lines)
    end)
  end)
end

-- List branches without blocking, handing the same ordered list to `cb`.
--
-- Prefer this wherever a callback will do. Even though the queries themselves
-- are quick, `git` can take tens of seconds to so much as print its version
-- when something outside this config is wrong with it — a trace2 log directory
-- grown to 60k files did exactly that here — and a frozen editor makes that
-- look like Neovim's fault. Running the queries concurrently also means the
-- slow all_remotes listing costs no more than its own query.
---@param opts? { all_remotes?: boolean }
---@param cb fun(branches: string[])
function M.get_branches_async(opts, cb)
  local want_remotes = opts and opts.all_remotes or false
  local results = {}
  local pending = want_remotes and 3 or 2

  local function collect(key)
    return function(out)
      results[key] = out
      pending = pending - 1
      if pending > 0 then
        return
      end
      if not results.locals then
        notify("Failed to list branches (not a git repo?)", vim.log.levels.ERROR)
        cb({})
        return
      end
      cb(order_branches(results.locals, as_set(results.priority), filter_remotes(results.remotes)))
    end
  end

  git_async(LOCALS_ARGS, collect("locals"))
  git_async(PRIORITY_ARGS, collect("priority"))
  if want_remotes then
    git_async(REMOTES_ARGS, collect("remotes"))
  end
end

-- The single newest PRIORITY_REMOTES tip, by committer date. Lines are
-- `for-each-ref` output: "<unix> <refname>". A tie keeps PRIORITY_REMOTES
-- order (develop, then master, main, then dev). Missing refs are absent
-- from the output, so one existing remote is returned as-is.
---@param lines string[]?
---@return string[]
function M.newest_priority_remote(lines)
  local rank = {}
  for i, name in ipairs(PRIORITY_REMOTES) do
    rank[name] = i
  end
  local best_name, best_date, best_rank
  for _, line in ipairs(lines or {}) do
    local date_s, name = line:match("^(%d+)%s+(%S+)$")
    local date = date_s and tonumber(date_s)
    local r = name and rank[name]
    if date and r and (not best_date or date > best_date or (date == best_date and r < best_rank)) then
      best_name, best_date, best_rank = name, date, r
    end
  end
  if best_name then
    return { best_name }
  end
  return {}
end

-- The newest priority remote (if any) plus 20 recent commits, for the F1/F2
-- picker. Both queries run concurrently; `cb(remotes, commits)` fires on
-- completion. `remotes` has at most one entry: when several of
-- origin/develop, origin/master, origin/main, and origin/dev exist, only the
-- most recently committed tip is listed.
---@param cb fun(remotes: string[], commits: string[])
function M.get_picker_bases_async(cb)
  local results = {}
  local pending = 2
  local function collect(key)
    return function(out)
      results[key] = out
      pending = pending - 1
      if pending > 0 then
        return
      end
      cb(M.newest_priority_remote(results.priority), results.commits or {})
    end
  end
  git_async(PRIORITY_DATE_ARGS, collect("priority"))
  git_async(RECENT_COMMITS_ARGS, collect("commits"))
end

local function open(rev)
  vim.cmd("DiffviewOpen " .. rev)
end

-- The last 20 commits reachable from HEAD, newest first, each prefixed with a
-- zero-padded index like "(01)" so blink.cmp's cmdline completion keeps them in
-- git-log order (it sorts candidates alphabetically, and "(01)" < "(02)" <
-- ... < "(20)"). `skip` drops that many commits from the top, so skip = 1 hides
-- HEAD itself and the list starts at HEAD~1.
local function commit_items(skip)
  local out = git_lines({ "git", "log", "--skip=" .. skip, "--max-count=20", "--format=%h %s", "HEAD" })
  if not out then
    return {}
  end
  local items = {}
  for i, line in ipairs(out) do
    items[i] = string.format("(%02d) %s", i, line)
  end
  return items
end

-- Resolve a commit argument to a revision. The argument is a "(NN) <sha>
-- <subject>" completion item (see commit_items) or a raw revision. When only
-- the "(NN)" prefix survived, fall back to HEAD~N — `skip` must match the value
-- the list was built with, since index 1 is HEAD~skip.
local function parse_commit(arg, skip)
  local rev = arg:match("^%(%d+%)%s+(%x%x%x%x+)")
  if rev then
    return rev
  end
  local n = arg:match("^%(%s*(%d+)%s*%)")
  if n then
    return "HEAD~" .. (tonumber(n) - 1 + skip)
  end
  return arg:match("^%S+")
end

-- Completion for `:Pdf` — the last 20 commits, HEAD included.
function M.complete_commits()
  return commit_items(0)
end

-- Show a single commit's own changes, i.e. its parent diffed against it.
--
-- With no argument, uses HEAD (HEAD~1..HEAD).
function M.diff_commit(arg)
  local rev = (arg and arg ~= "" and parse_commit(arg, 0)) or "HEAD"
  open(rev .. "~1.." .. rev)
end

-- Completion for `:CompareHead` — the last 20 ancestor commits of HEAD (HEAD
-- itself excluded), so every entry is something HEAD can be compared against.
function M.complete_ancestor_commits()
  return commit_items(1)
end

-- Compare HEAD with a previous commit.
--
-- With no argument, diffs HEAD against its immediate parent (HEAD~1..HEAD).
function M.diff_against_head(arg)
  local rev = (arg and arg ~= "" and parse_commit(arg, 1)) or "HEAD~1"
  open(rev .. "..HEAD")
end

-- Completion for the branch-taking commands (`:EditDiff`, `:DiffThisFile`,
-- `:CompareVersionFile`) — the ordered branch list (see get_branches).
-- Each item is prefixed with a zero-padded index like "(001)" so blink.cmp's
-- cmdline completion preserves our priority ordering (it sorts candidates
-- alphabetically, and "(001)" < "(002)" < ... < "(100)"). Three digits keep the
-- order correct past 99, since e.g. "(100)" would sort before "(99)".
function M.complete_branches()
  local branches = get_branches()
  local items = {}
  for i, b in ipairs(branches) do
    items[i] = string.format("(%03d) %s", i, b)
  end
  return items
end

-- Absolute path of the current repo root, or nil when not in a git repo.
local function repo_root()
  local out = git_lines({ "git", "rev-parse", "--show-toplevel" })
  return out and out[1] or nil
end

-- Dot-directories owned by coding agents. They are tool state, not changes
-- to review, and a match is any path segment (`.agent` does not match
-- `.agency`), at the repo root or nested.
--
-- <F1> drops them from the "Git status" Diffview file list after Git returns
-- it. Passing the same paths as Diffview path args makes them the diff scope:
-- the panel says "Showing changes for" those globs and the real changes
-- disappear. A commit or branch Diffview still shows a change that landed
-- inside one of these directories.
--
-- <F2> and :EditDiff drop them from every list of files they open as buffers.
M.ai_tool_dirs = {
  ".agent",
  ".agents",
  ".aider",
  ".amazonq",
  ".augment",
  ".claude",
  ".cline",
  ".codeium",
  ".codex",
  ".continue",
  ".copilot",
  ".cursor",
  ".gemini",
  ".kilocode",
  ".opencode",
  ".roo",
  ".trae",
  ".ttadk",
  ".windsurf",
}

local ai_tool_dir_set = {}
for _, dir in ipairs(M.ai_tool_dirs) do
  ai_tool_dir_set[dir] = true
end

-- True when any path segment is an AI tool directory. `.agent` does not match
-- `.agency`.
function M.is_ai_tool_path(path)
  if not path or path == "" then
    return false
  end
  for segment in path:gmatch("[^/\\]+") do
    if ai_tool_dir_set[segment] then
      return true
    end
  end
  return false
end

local function without_ai_tool_files(entries)
  local kept = {}
  for _, entry in ipairs(entries) do
    if not M.is_ai_tool_path(entry.path) then
      kept[#kept + 1] = entry
    end
  end
  return kept
end

local function without_ai_tool_paths(paths)
  local kept = {}
  for _, path in ipairs(paths) do
    if not M.is_ai_tool_path(path) then
      kept[#kept + 1] = path
    end
  end
  return kept
end

-- Drop AI tool entries from a Diffview FileDict. The current path is what the
-- panel lists; a rename out of a tool directory into the tree still shows.
function M.drop_ai_tool_files(files)
  files:set_conflicting(without_ai_tool_files(files.conflicting))
  files:set_working(without_ai_tool_files(files.working))
  files:set_staged(without_ai_tool_files(files.staged))
  files:update_file_trees()
end

-- Set just before the working-tree :DiffviewOpen from <F1>. The view_opened
-- hook consumes it so a later branch diff is left alone.
local filter_working_tree = false

function M.arm_ai_tool_filter()
  filter_working_tree = true
end

function M.disarm_ai_tool_filter()
  filter_working_tree = false
end

function M.consume_ai_tool_filter(view)
  if not filter_working_tree then
    return
  end
  filter_working_tree = false
  if not view or not view.get_updated_files then
    return
  end

  local async = require("diffview.async")
  local orig = view.get_updated_files
  view.get_updated_files = async.wrap(function(self, callback)
    local err, files = async.await(orig(self))
    if files then
      M.drop_ai_tool_files(files)
    end
    callback(err, files)
  end)
end

-- Above this many files, ask before opening them all — picking the wrong base
-- branch easily matches hundreds of unrelated files.
local EDIT_DIFF_CONFIRM_AT = 20

-- Stable absolute path for comparing a git path with a buffer name. A missing
-- file has no realpath; normalize still makes the two spellings match.
local function canonical(path)
  if not path or path == "" then
    return nil
  end
  local abs = vim.fn.fnamemodify(path, ":p")
  return vim.uv.fs_realpath(abs) or vim.fs.normalize(abs)
end

-- An existing buffer for `path`, matched by real path so a /var vs /private/var
-- spelling does not open a second copy and drop unsaved edits.
local function buffer_for(path)
  local want = canonical(path)
  if not want then
    return nil
  end
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) and canonical(vim.api.nvim_buf_get_name(buf)) == want then
      return buf
    end
  end
  return nil
end

local function is_kept_buf(buf, keep)
  local name = vim.api.nvim_buf_get_name(buf)
  if name == "" or name:find("^%a[%w+.-]*://") then
    return false
  end
  local c = canonical(name)
  return c ~= nil and keep[c] == true
end

-- Listed buffers that are not part of the diff about to be opened.
local function other_listed(keep)
  local bufs = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].buflisted and not is_kept_buf(buf, keep) then
      bufs[#bufs + 1] = buf
    end
  end
  return bufs
end

-- File buffers whose text would be lost. Terminals, help, and URI views
-- (diffview://, …) are closed with the rest and are not unsaved work.
local function unsaved_outside(keep)
  local n = 0
  for _, buf in ipairs(other_listed(keep)) do
    if vim.bo[buf].modified then
      local bt = vim.bo[buf].buftype
      if bt == "" or bt == "acwrite" then
        n = n + 1
      end
    end
  end
  return n
end

local function stop_codechat()
  local term = package.loaded["codechat.terminal"]
  if type(term) == "table" and type(term.stop_all) == "function" then
    pcall(term.stop_all)
  end
end

local function stop_terminals()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].buftype == "terminal" then
      local job = vim.b[buf].terminal_job_id
      if type(job) == "number" and job > 0 then
        pcall(vim.fn.jobstop, job)
      end
    end
  end
end

-- Close ordinary windows showing a buffer we are about to delete. A window
-- that already shows one of the diff files stays. Never closes the current
-- window, which would quit Neovim when it is the last one.
local function close_windows_of(buf)
  local current = vim.api.nvim_get_current_win()
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    if win ~= current and vim.api.nvim_win_is_valid(win) then
      local cfg = vim.api.nvim_win_get_config(win)
      if cfg.relative == "" then
        pcall(vim.api.nvim_win_close, win, true)
      end
    end
  end
end

local function wipe_other_listed(scratch, keep)
  local function wipe_once()
    for _, buf in ipairs(other_listed(keep)) do
      if buf ~= scratch and vim.api.nvim_buf_is_valid(buf) then
        close_windows_of(buf)
        if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_get_current_buf() ~= buf then
          pcall(vim.api.nvim_buf_delete, buf, { force = true })
        end
      end
    end
  end
  wipe_once()
  wipe_once()
end

-- Close every listed buffer that is not one of `paths`, so the buffer list is
-- only the diff about to be opened. A modified file outside that set is
-- discarded only after a confirm. Returns false when the user declines.
-- When the current window is showing one of those buffers, `scratch` is an
-- unlisted buffer parked there so the wipe cannot quit Neovim. The caller
-- opens the diff files and then deletes it.
---@param paths string[]
---@return boolean ok
---@return integer? scratch
local function close_other_buffers(paths)
  local keep = {}
  for _, path in ipairs(paths) do
    local c = canonical(path)
    if c then
      keep[c] = true
    end
  end
  if #other_listed(keep) == 0 then
    return true, nil
  end

  local discard = unsaved_outside(keep)
  if discard > 0 then
    local noun = discard == 1 and "1 unsaved buffer" or (discard .. " unsaved buffers")
    if vim.fn.confirm(noun .. " will be discarded. Open changed files?", "&Yes\n&No", 2) ~= 1 then
      return false, nil
    end
  end

  if vim.fn.exists(":DiffviewClose") == 2 then
    pcall(vim.cmd, "silent! DiffviewClose")
  end
  stop_codechat()
  stop_terminals()

  local saved_hidden = vim.o.hidden
  local saved_eventignore = vim.o.eventignore
  local function restore()
    vim.o.hidden = saved_hidden
    if vim.o.eventignore ~= saved_eventignore then
      vim.o.eventignore = saved_eventignore
    end
  end

  vim.o.hidden = true
  -- File explorers and the Diffview follow hook rebuild windows on every
  -- close. Silence them until the diff files are what remains.
  vim.o.eventignore = "all"

  local scratch
  local ok, err = pcall(function()
    local current = vim.api.nvim_get_current_buf()
    if vim.api.nvim_buf_is_valid(current) and not is_kept_buf(current, keep) then
      scratch = vim.api.nvim_create_buf(false, true)
      local win = vim.api.nvim_get_current_win()
      if not pcall(vim.api.nvim_win_set_buf, win, scratch) then
        error("could not switch away from the current buffer")
      end
    end
    wipe_other_listed(scratch, keep)
  end)

  restore()
  if not ok then
    if scratch and vim.api.nvim_buf_is_valid(scratch) and vim.api.nvim_get_current_buf() ~= scratch then
      pcall(vim.api.nvim_buf_delete, scratch, { force = true })
    end
    notify("Could not close open buffers: " .. tostring(err), vim.log.levels.ERROR)
    return false, nil
  end
  return true, scratch
end

-- Base branch used when :EditDiff or :DiffThisFile is called without an argument.
local DEFAULT_BASE = "origin/develop"

-- Repo-relative paths of the files changed in `range` (e.g. "HEAD~..HEAD" or
-- "<branch>...HEAD"), or of the uncommitted ones — staged, unstaged and
-- untracked — when `range` is nil. `--diff-filter=d` drops files deleted on
-- HEAD's side, which would only open empty buffers. Nil when git fails.
local function changed_files(root, range)
  if range then
    return git_lines({ "git", "-C", root, "diff", "--name-only", "--diff-filter=d", range })
  end
  local files = git_lines({ "git", "-C", root, "diff", "--name-only", "--diff-filter=d", "HEAD" })
  if not files then
    return nil
  end
  vim.list_extend(files, git_lines({ "git", "-C", root, "ls-files", "--others", "--exclude-standard" }) or {})
  return files
end

-- Open every file changed in `range` (see changed_files; nil = uncommitted
-- changes) as an editable buffer, as opposed to <F1>, which shows the same set
-- in a read-only Diffview. Paths under M.ai_tool_dirs are left out, same as
-- the Git status Diffview. Other listed buffers are closed first, so the
-- buffer list is only these files; a buffer already showing one of them is
-- kept, including unsaved edits. Files are added with bufadd (cheap, no
-- LSP/Treesitter attach) and only the first is actually shown.
function M.edit_changed(range)
  local what = range and ("changed in " .. range) or "with uncommitted changes"
  local root = repo_root()
  if not root then
    notify("Not a git repo", vim.log.levels.ERROR)
    return
  end

  local files = changed_files(root, range)
  if not files then
    notify("Failed to list files " .. what .. " (unknown revision?)", vim.log.levels.ERROR)
    return
  end
  local listed = #files
  files = without_ai_tool_paths(files)
  if #files == 0 then
    if listed > 0 then
      notify("No files " .. what .. " outside AI tool directories")
    else
      notify("No files " .. what)
    end
    return
  end

  if #files > EDIT_DIFF_CONFIRM_AT then
    local prompt = string.format("%d files %s. Open all of them?", #files, what)
    if vim.fn.confirm(prompt, "&Yes\n&No", 2) ~= 1 then
      return
    end
  end

  local paths = {}
  for _, rel in ipairs(files) do
    paths[#paths + 1] = root .. "/" .. rel
  end
  local closed, scratch = close_other_buffers(paths)
  if not closed then
    return
  end

  -- 'hidden' lets us leave a modified diff file without discarding its text.
  -- :badd of that same buffer raises E37, so list the files through bufadd.
  local saved_hidden = vim.o.hidden
  vim.o.hidden = true
  local opened, open_err = pcall(function()
    local first
    for _, path in ipairs(paths) do
      local buf = buffer_for(path) or vim.fn.bufadd(path)
      vim.bo[buf].buflisted = true
      if not first then
        first = buf
      end
    end
    if first and vim.api.nvim_buf_is_valid(first) then
      vim.api.nvim_set_current_buf(first)
    end
  end)
  vim.o.hidden = saved_hidden
  if not opened then
    notify("Could not open changed files: " .. tostring(open_err), vim.log.levels.ERROR)
    return
  end
  if scratch and vim.api.nvim_buf_is_valid(scratch) and vim.api.nvim_get_current_buf() ~= scratch then
    pcall(vim.api.nvim_buf_delete, scratch, { force = true })
  end
  notify(string.format("Opened %d file(s) %s", #files, what))
end

-- Open every file that differs from a base branch as an editable buffer.
--
-- The argument is a "(NN) <branch>" completion item (see complete_branches) or a
-- raw branch name; with no argument the base is origin/develop. The file set
-- comes from the same three-dot range <F1> diffs: files changed on HEAD's side
-- since the merge-base.
function M.edit_diff(branch)
  -- Strip the "(NN) " prefix from a completion item, if present.
  local name = DEFAULT_BASE
  if branch and branch ~= "" then
    name = branch:match("^%(%d+%)%s+(.+)$") or branch:match("^%S+")
  end
  M.edit_changed(name .. "...HEAD")
end

-- Absolute path of a Snacks picker item (git_files gives item.file relative to
-- item.cwd). Prefer the picker's own resolver when present.
local function item_path(item)
  local util = Snacks.picker and Snacks.picker.util
  if util and util.path then
    return util.path(item)
  end
  local f = item.file or item.text or ""
  if f:sub(1, 1) == "/" then
    return f
  end
  return (item.cwd or vim.uv.cwd()) .. "/" .. f
end

-- Open two files side by side in a fresh tab, in diff mode.
local function open_diff(pa, pb)
  vim.cmd("tabnew " .. vim.fn.fnameescape(pa))
  vim.cmd("diffthis")
  vim.cmd("vertical diffsplit " .. vim.fn.fnameescape(pb))
end

-- Compare two files from the current repo side by side.
--
-- Opens a Snacks git_files picker scoped to the repo (tracked + new/untracked
-- files), limited to .kt/.java/.xml sources: type to filter, press Tab to
-- toggle-select files, then confirm. Exactly two files must be selected; on
-- confirm they open in a new tab as a vertical diff.
function M.compare_files()
  if not (Snacks and Snacks.picker) then
    notify("Snacks picker not available", vim.log.levels.ERROR)
    return
  end
  local root = repo_root()
  if not root then
    notify("Not a git repo", vim.log.levels.ERROR)
    return
  end

  local allowed = { kt = true, java = true, xml = true }

  Snacks.picker.git_files({
    cwd = root,
    untracked = true,
    title = "Compare Files (Tab: select two, Enter: diff)",
    transform = function(item)
      local ext = (item.file or item.text or ""):match("%.([%w]+)$")
      if ext and allowed[ext:lower()] then
        return item
      end
      return false
    end,
    confirm = function(picker)
      local sel = picker:selected({ fallback = true })
      if #sel ~= 2 then
        notify("Select exactly two files (Tab to toggle)", vim.log.levels.WARN)
        return
      end
      picker:close()
      open_diff(item_path(sel[1]), item_path(sel[2]))
    end,
  })
end

-- Compare a single file's HEAD copy against its copy at a chosen version.
--
-- Flow mirrors a <F1> branch pick then :CompareFiles — the argument is a "(NN)
-- <branch>" completion item (see complete_branches) or a raw revision, used as
-- the version. A Snacks git_files picker (same .kt/.java/.xml scope as
-- compare_files) then selects one file; on confirm Diffview opens rev..HEAD
-- limited to that file, so the left side is the version and the right is HEAD.
function M.compare_version_file(arg)
  if not (Snacks and Snacks.picker) then
    notify("Snacks picker not available", vim.log.levels.ERROR)
    return
  end
  local root = repo_root()
  if not root then
    notify("Not a git repo", vim.log.levels.ERROR)
    return
  end
  if not arg or arg == "" then
    notify("Provide a version (Tab to complete)", vim.log.levels.WARN)
    return
  end

  -- Strip the "(NN) " prefix from a completion item, if present.
  local rev = arg:match("^%(%d+%)%s+(.+)$") or arg:match("^%S+")

  local allowed = { kt = true, java = true, xml = true }

  Snacks.picker.git_files({
    cwd = root,
    untracked = true,
    title = "Compare " .. rev .. " vs HEAD (Enter: diff file)",
    transform = function(item)
      local ext = (item.file or item.text or ""):match("%.([%w]+)$")
      if ext and allowed[ext:lower()] then
        return item
      end
      return false
    end,
    confirm = function(picker, item)
      if not item then
        notify("Select a file", vim.log.levels.WARN)
        return
      end
      picker:close()
      vim.cmd("DiffviewOpen " .. rev .. "..HEAD -- " .. vim.fn.fnameescape(item_path(item)))
    end,
  })
end

-- Absolute path of the file to act on: the current buffer when it holds a real
-- file, else the first file shown in any other window of this tab page. The
-- fallback keeps the command usable when focus sits on a non-file window (file
-- panel, terminal, outline). URI-scheme buffers (diffview://, fugitive://, …)
-- are skipped since they are views of a revision, not editable files.
local function focused_file()
  local function path_of(buf)
    if vim.bo[buf].buftype ~= "" then
      return nil
    end
    local name = vim.api.nvim_buf_get_name(buf)
    if name == "" or name:find("^%a[%w+.-]*://") then
      return nil
    end
    return vim.fn.fnamemodify(name, ":p")
  end

  local cur = path_of(vim.api.nvim_get_current_buf())
  if cur then
    return cur
  end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local path = path_of(vim.api.nvim_win_get_buf(win))
    if path then
      return path
    end
  end
  return nil
end

-- Diff the focused file against a version, in Diffview.
--
-- Like a <F1> branch pick narrowed to one file, and like :CompareVersionFile without
-- the file picker: the file is the one already in front of you. The argument is
-- a "(NN) <branch>" completion item (see complete_branches) or a raw revision;
-- with no argument the base is origin/develop. Diffview opens rev...HEAD
-- limited to that file, so the left side is the merge-base with rev and the
-- right side is HEAD.
function M.diff_this_file(arg)
  local root = repo_root()
  if not root then
    notify("Not a git repo", vim.log.levels.ERROR)
    return
  end

  local file = focused_file()
  if not file then
    notify("No file to diff in this tab", vim.log.levels.WARN)
    return
  end
  if file:sub(1, #root + 1) ~= root .. "/" then
    notify("File is outside the repo: " .. file, vim.log.levels.WARN)
    return
  end

  -- Strip the "(NN) " prefix from a completion item, if present.
  local rev = DEFAULT_BASE
  if arg and arg ~= "" then
    rev = arg:match("^%(%d+%)%s+(.+)$") or arg:match("^%S+")
  end

  vim.cmd("DiffviewOpen " .. rev .. "...HEAD -- " .. vim.fn.fnameescape(file))

  -- The file panel only ever lists the one file we asked for, so close it and
  -- give the whole width to the diff. :DiffviewToggleFiles brings it
  -- back. The panel is up by the time :DiffviewOpen returns.
  local view = require("diffview.lib").get_current_view()
  if view and view.panel and view.panel:is_open() then
    view.panel:close()
  end
end

function M.setup()
  vim.api.nvim_create_user_command("Pdf", function(opts)
    M.diff_commit(opts.args)
  end, {
    nargs = "*",
    complete = function()
      return M.complete_commits()
    end,
    desc = "Diffview: show a commit's own changes (parent vs commit)",
  })

  vim.api.nvim_create_user_command("CompareHead", function(opts)
    M.diff_against_head(opts.args)
  end, {
    nargs = "*",
    complete = function()
      return M.complete_ancestor_commits()
    end,
    desc = "Diffview: compare HEAD with a previous commit",
  })

  vim.api.nvim_create_user_command("EditDiff", function(opts)
    M.edit_diff(opts.args)
  end, {
    nargs = "*",
    complete = function()
      return M.complete_branches()
    end,
    desc = "Close other buffers, then open files differing from a base branch",
  })

  vim.api.nvim_create_user_command("CompareFiles", function()
    M.compare_files()
  end, {
    nargs = 0,
    desc = "Diff two working-tree files from this repo (picker)",
  })

  vim.api.nvim_create_user_command("DiffThisFile", function(opts)
    M.diff_this_file(opts.args)
  end, {
    nargs = "*",
    complete = function()
      return M.complete_branches()
    end,
    desc = "Diffview: diff the focused file against a version (default origin/develop)",
  })

  vim.api.nvim_create_user_command("CompareVersionFile", function(opts)
    M.compare_version_file(opts.args)
  end, {
    nargs = "*",
    complete = function()
      return M.complete_branches()
    end,
    desc = "Diffview: diff HEAD's file against a chosen version's file",
  })
end

return M
