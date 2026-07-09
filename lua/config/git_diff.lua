-- Diffview review commands:
--   :Pdf         compare HEAD with the previous commit
--   :CodeReview  compare HEAD with a local or remote branch (with completion)
local M = {}

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = "Diffview" })
end

-- Return local + remote branch names (e.g. "develop", "origin/master").
local function get_branches()
  local out = vim.fn.systemlist({ "git", "branch", "-a", "--format=%(refname:short)" })
  if vim.v.shell_error ~= 0 then
    notify("Failed to list branches (not a git repo?)", vim.log.levels.ERROR)
    return {}
  end

  local branches = {}
  for _, line in ipairs(out) do
    line = vim.trim(line)
    -- Skip the symbolic "origin/HEAD -> origin/main" entry.
    if line ~= "" and not line:find("%->") then
      table.insert(branches, line)
    end
  end
  return branches
end

M.get_branches = get_branches

local function open(rev)
  vim.cmd("DiffviewOpen " .. rev)
end

-- Compare HEAD with the previous commit.
function M.diff_previous_commit()
  open("HEAD~1..HEAD")
end

-- Completion for `:CodeReview` — filter branch names by the current arg.
function M.complete_branches(arg_lead)
  local branches = get_branches()
  if arg_lead == "" then
    return branches
  end
  return vim.tbl_filter(function(b)
    return b:find(arg_lead, 1, true) == 1
  end, branches)
end

-- Compare HEAD with a branch (from arg or interactive selection).
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
  vim.ui.select(branches, { prompt = "Review HEAD against branch:" }, function(choice)
    if choice then
      open(choice .. "...HEAD")
    end
  end)
end

function M.setup()
  vim.api.nvim_create_user_command("Pdf", function()
    M.diff_previous_commit()
  end, { desc = "Diffview: compare HEAD with previous commit" })

  vim.api.nvim_create_user_command("CodeReview", function(opts)
    M.review_code(opts.args)
  end, {
    nargs = "?",
    complete = function(arg_lead)
      return M.complete_branches(arg_lead)
    end,
    desc = "Diffview: compare HEAD with a local/remote branch",
  })
end

return M
