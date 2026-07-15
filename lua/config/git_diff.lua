-- Diffview review commands:
--   :Pdf         compare HEAD with a previous commit (Tab: last 20 ancestors)
--   :CodeReview  compare HEAD with a local or remote branch (Tab: ordered branches)
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
    ipairs(
      git_lines({
        "git",
        "for-each-ref",
        "--sort=-committerdate",
        "--count=" .. (MAX_REMOTES + 5),
        "--format=%(refname:short)",
        "refs/remotes/",
      }) or {}
    )
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

-- Completion for `:Pdf` — the last 20 ancestor commits of HEAD (HEAD itself
-- excluded), newest first. Each item is prefixed with a zero-padded index like
-- "(01)" so blink.cmp's cmdline completion keeps them in git-log order (it
-- sorts candidates alphabetically, and "(01)" < "(02)" < ... < "(20)").
function M.complete_commits()
  local out = git_lines({ "git", "log", "--skip=1", "--max-count=20", "--format=%h %s", "HEAD" })
  if not out then
    return {}
  end
  local items = {}
  for i, line in ipairs(out) do
    items[i] = string.format("(%02d) %s", i, line)
  end
  return items
end

-- Compare HEAD with a previous commit.
--
-- With no argument, diffs HEAD against its immediate parent (HEAD~1..HEAD).
-- Otherwise the argument is a "(NN) <sha> <subject>" completion item (see
-- complete_commits) or a raw revision, and HEAD is diffed against that commit.
function M.diff_previous_commit(arg)
  local rev
  if arg and arg ~= "" then
    -- Prefer the sha from a "(NN) <sha> <subject>" item; fall back to the index
    -- (HEAD~N) if only "(NN)" survived, then to a raw revision token.
    rev = arg:match("^%(%d+%)%s+(%x%x%x%x+)")
    if not rev then
      local n = arg:match("^%(%s*(%d+)%s*%)")
      rev = n and ("HEAD~" .. tonumber(n)) or arg:match("^%S+")
    end
  end
  open((rev or "HEAD~1") .. "..HEAD")
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

function M.setup()
  vim.api.nvim_create_user_command("Pdf", function(opts)
    M.diff_previous_commit(opts.args)
  end, {
    nargs = "*",
    complete = function()
      return M.complete_commits()
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
end

return M
