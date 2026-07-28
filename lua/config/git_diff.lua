-- Diffview review commands:
--   :Pdf          show one commit's own changes (Tab: last 20 commits incl. HEAD)
--   :CompareHead  compare HEAD with a previous commit (Tab: last 20 ancestors)
--   :CodeReview   compare HEAD with a local or remote branch (Tab: ordered branches)
--   :CompareFiles diff two repo files picked from a fuzzy list (Tab to select two)
--   :CompareVersionFile pick a version (Tab to complete), then a file, to diff
--                 HEAD's copy of that file against the chosen version's copy
local M = {}

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = "Diffview" })
end

-- Remote base branches surfaced at the very top of the list, in this order.
local PRIORITY_REMOTES = { "origin/develop", "origin/master", "origin/main", "origin/dev" }

-- Cap on remote branches to list (after the priority ones). Keeps the picker
-- fast in repos with thousands of remote branches.
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

-- Return branch names ordered for quick review selection:
--   1-4. origin/develop, origin/master, origin/main, origin/dev (if present)
--   5.   the 3 most-recently-committed local branches (newest first)
--   6.   everything else: remaining remote branches, then remaining locals
--        (each newest-committed first)
--
-- Only the MAX_REMOTES most-recently-committed remote branches are listed, so
-- the query stays fast in repos with very many remote branches. We ask git for
-- a few extra to absorb the "origin/HEAD" pointer we filter out below.
local function get_branches()
  local locals =
    git_lines({ "git", "for-each-ref", "--sort=-committerdate", "--format=%(refname:short)", "refs/heads/" })
  if not locals then
    notify("Failed to list branches (not a git repo?)", vim.log.levels.ERROR)
    return {}
  end

  local remotes = {}
  for _, r in
    ipairs(git_lines({
      "git",
      "for-each-ref",
      "--sort=-committerdate",
      "--count=" .. (MAX_REMOTES + 5),
      "--format=%(refname:short)",
      "refs/remotes/",
    }) or {})
  do
    -- Skip the symbolic "origin/HEAD" pointer.
    if r:find("/") and not r:find("HEAD") then
      table.insert(remotes, r)
      if #remotes >= MAX_REMOTES then
        break
      end
    end
  end

  local seen = {}
  local ordered = {}
  local function add(name)
    if name and name ~= "" and not seen[name] then
      seen[name] = true
      table.insert(ordered, name)
    end
  end

  local remote_set = {}
  for _, r in ipairs(remotes) do
    remote_set[r] = true
  end
  -- Surface priority remotes first. If one fell outside the MAX_REMOTES window
  -- fetched above, verify it directly so it still shows.
  for _, p in ipairs(PRIORITY_REMOTES) do
    if remote_set[p] then
      add(p)
    elseif vim.fn.system({ "git", "rev-parse", "--verify", "--quiet", "refs/remotes/" .. p }) ~= "" then
      add(p)
    end
  end

  for i = 1, math.min(3, #locals) do
    add(locals[i])
  end

  for _, r in ipairs(remotes) do
    add(r)
  end
  for _, l in ipairs(locals) do
    add(l)
  end

  return ordered
end

M.get_branches = get_branches

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

-- Completion for `:CodeReview` — the ordered branch list (see get_branches).
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

-- Compare HEAD with a branch.
--
-- The argument is a "(NN) <branch>" completion item (see complete_branches) or
-- a raw branch name, and HEAD is diffed against that branch (branch...HEAD).
function M.review_code(branch)
  if branch and branch ~= "" then
    -- Strip the "(NN) " prefix from a completion item, if present.
    local name = branch:match("^%(%d+%)%s+(.+)$") or branch:match("^%S+")
    open(name .. "...HEAD")
    return
  end

  local branches = get_branches()
  if #branches == 0 then
    notify("No branches found", vim.log.levels.WARN)
    return
  end
  notify("Provide a branch (Tab to complete)", vim.log.levels.WARN)
end

-- Absolute path of the current repo root, or nil when not in a git repo.
local function repo_root()
  local out = git_lines({ "git", "rev-parse", "--show-toplevel" })
  return out and out[1] or nil
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
-- Flow mirrors :CodeReview then :CompareFiles — the argument is a "(NN)
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

  vim.api.nvim_create_user_command("CodeReview", function(opts)
    M.review_code(opts.args)
  end, {
    nargs = "*",
    complete = function()
      return M.complete_branches()
    end,
    desc = "Diffview: compare HEAD with a local/remote branch",
  })

  vim.api.nvim_create_user_command("CompareFiles", function()
    M.compare_files()
  end, {
    nargs = 0,
    desc = "Diff two working-tree files from this repo (picker)",
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
