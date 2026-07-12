-- Diffview review commands:
--   :Pdf         compare HEAD with the previous commit
--   :CodeReview  compare HEAD with a local or remote branch (with completion)
local M = {}

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = "Diffview" })
end

-- Remote base branches surfaced at the very top of the list, in this order.
local PRIORITY_REMOTES = { "origin/develop", "origin/master", "origin/main", "origin/dev" }

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
      git_lines({ "git", "for-each-ref", "--sort=-committerdate", "--format=%(refname:short)", "refs/remotes/" }) or {}
    )
  do
    -- Skip the symbolic "origin/HEAD" pointer.
    if r:find("/") and not r:find("HEAD") then
      table.insert(remotes, r)
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
  for _, p in ipairs(PRIORITY_REMOTES) do
    if remote_set[p] then
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

-- Compare HEAD with the previous commit.
function M.diff_previous_commit()
  open("HEAD~1..HEAD")
end

-- Compare HEAD with a branch (from arg or interactive selection).
--
-- Selection goes through the Snacks picker with an index-based sort so our
-- priority ordering (see get_branches) is always preserved; typing only
-- filters the list, it never reorders it. We deliberately avoid cmdline
-- Tab-completion here because blink.cmp fuzzy-sorts those results and cannot be
-- told to honor a custom order per command.
function M.review_code(branch)
  if branch and branch ~= "" then
    open(branch .. "...HEAD")
    return
  end

  local branches = get_branches()
  if #branches == 0 then
    notify("No branches found", vim.log.levels.WARN)
    return
  end

  if not (Snacks and Snacks.picker) then
    vim.ui.select(branches, { prompt = "Review HEAD against branch:" }, function(choice)
      if choice then
        open(choice .. "...HEAD")
      end
    end)
    return
  end

  local items = {}
  for i, b in ipairs(branches) do
    items[i] = { idx = i, text = b }
  end

  Snacks.picker.pick({
    title = "Review HEAD against branch",
    items = items,
    format = "text",
    sort = { fields = { "idx" } },
    layout = { preview = false },
    confirm = function(picker, item)
      picker:close()
      if item and item.text then
        open(item.text .. "...HEAD")
      end
    end,
  })
end

function M.setup()
  vim.api.nvim_create_user_command("Pdf", function()
    M.diff_previous_commit()
  end, { desc = "Diffview: compare HEAD with previous commit" })

  vim.api.nvim_create_user_command("CodeReview", function(opts)
    M.review_code(opts.args)
  end, {
    nargs = "?",
    desc = "Diffview: compare HEAD with a local/remote branch",
  })
end

return M
