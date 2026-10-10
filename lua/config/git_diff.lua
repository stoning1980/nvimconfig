-- Diffview review commands:
--   :Pdf          show one commit's own changes (Tab: last 20 commits incl. HEAD)
--   :CompareHead  compare HEAD with a previous commit (Tab: last 20 ancestors)
--   :EditDiff     open every file differing from a base branch as a buffer
--                 (Tab: ordered branches, defaults to origin/develop;
--                 confirms past 20 files)
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
local PRIORITY_ARGS = { "git", "for-each-ref", "--format=%(refname:short)" }
for _, p in ipairs(PRIORITY_REMOTES) do
  table.insert(PRIORITY_ARGS, "refs/remotes/" .. p)
end

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

  local function run(args, done)
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
      -- vim.system calls back in a fast event context, where most of the API
      -- (and our notify) is off limits.
      vim.schedule(function()
        done(lines)
      end)
    end)
  end

  run(LOCALS_ARGS, collect("locals"))
  run(PRIORITY_ARGS, collect("priority"))
  if want_remotes then
    run(REMOTES_ARGS, collect("remotes"))
  end
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

-- Above this many files, ask before opening them all — picking the wrong base
-- branch easily matches hundreds of unrelated files.
local EDIT_DIFF_CONFIRM_AT = 20

-- Base branch used when :EditDiff or :DiffThisFile is called without an argument.
local DEFAULT_BASE = "origin/develop"

-- Open every file that differs from a base branch as an editable buffer (as
-- opposed to the <F1> branch picker, which opens the same set in a read-only
-- Diffview).
--
-- The argument is a "(NN) <branch>" completion item (see complete_branches) or a
-- raw branch name; with no argument the base is origin/develop. The file set
-- comes from the same three-dot range <F1> diffs: files changed on
-- HEAD's side since the merge-base. `--diff-filter=d` drops files deleted on
-- HEAD, which would only open empty buffers. Files are added with :badd (cheap,
-- no LSP/Treesitter attach) and only the first is actually opened.
function M.edit_diff(branch)
  -- Strip the "(NN) " prefix from a completion item, if present.
  local name = DEFAULT_BASE
  if branch and branch ~= "" then
    name = branch:match("^%(%d+%)%s+(.+)$") or branch:match("^%S+")
  end

  local root = repo_root()
  if not root then
    notify("Not a git repo", vim.log.levels.ERROR)
    return
  end

  local files = git_lines({ "git", "diff", "--name-only", "--diff-filter=d", name .. "...HEAD" })
  if not files then
    notify("Failed to diff against " .. name .. " (unknown branch?)", vim.log.levels.ERROR)
    return
  end
  if #files == 0 then
    notify("No files differ from " .. name)
    return
  end

  if #files > EDIT_DIFF_CONFIRM_AT then
    local prompt = string.format("%d files differ from %s. Open all of them?", #files, name)
    if vim.fn.confirm(prompt, "&Yes\n&No", 2) ~= 1 then
      return
    end
  end

  for _, rel in ipairs(files) do
    vim.cmd("badd " .. vim.fn.fnameescape(root .. "/" .. rel))
  end
  vim.cmd("edit " .. vim.fn.fnameescape(root .. "/" .. files[1]))
  notify(string.format("Opened %d file(s) differing from %s", #files, name))
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
  -- give the whole width to the diff. :DiffviewToggleFiles (<F2>) brings it
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
    desc = "Open all files differing from a base branch as buffers",
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
