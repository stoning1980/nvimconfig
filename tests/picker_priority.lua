-- Run: nvim --headless -u NONE -l tests/picker_priority.lua
-- F1/F2 list at most one of origin/develop, origin/master, origin/main,
-- origin/dev: the tip with the latest committer date.
vim.opt.rtp:prepend(vim.fn.getcwd())

local git_diff = require("config.git_diff")

local function assert_eq(actual, expected, label)
  local a = vim.inspect(actual)
  local e = vim.inspect(expected)
  assert(a == e, (label or "") .. " expected " .. e .. " got " .. a)
end

assert_eq(git_diff.newest_priority_remote(nil), {}, "nil lines")
assert_eq(git_diff.newest_priority_remote({}), {}, "no remotes")
assert_eq(
  git_diff.newest_priority_remote({ "100 origin/develop", "200 origin/master", "150 origin/dev" }),
  { "origin/master" },
  "newest committer date"
)
assert_eq(
  git_diff.newest_priority_remote({ "100 origin/master", "100 origin/develop", "100 origin/main" }),
  { "origin/develop" },
  "tie keeps develop before master before main"
)
assert_eq(git_diff.newest_priority_remote({ "50 origin/dev" }), { "origin/dev" }, "single remote")
assert_eq(
  git_diff.newest_priority_remote({ "junk", "40 upstream/develop", "10 origin/main" }),
  { "origin/main" },
  "ignores refs outside the priority list"
)

local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")

local function git(args, unix)
  local cmd = { "git", "-C", dir }
  vim.list_extend(cmd, args)
  local opts = { text = true }
  if unix then
    opts.env = vim.fn.environ()
    opts.env.GIT_AUTHOR_DATE = unix .. " +0000"
    opts.env.GIT_COMMITTER_DATE = unix .. " +0000"
  end
  local out = vim.system(cmd, opts):wait()
  assert(out.code == 0, table.concat(cmd, " ") .. " failed: " .. (out.stderr or ""))
end

git({ "init", "-b", "localmain" })
git({ "config", "user.email", "t@example.com" })
git({ "config", "user.name", "t" })
vim.fn.writefile({ "a" }, dir .. "/f.txt")
git({ "add", "f.txt" })
git({ "commit", "-m", "old" }, 1700000000)
git({ "update-ref", "refs/remotes/origin/develop", "HEAD" })
vim.fn.writefile({ "b" }, dir .. "/f.txt")
git({ "add", "f.txt" })
git({ "commit", "-m", "new" }, 1700000100)
git({ "update-ref", "refs/remotes/origin/master", "HEAD" })
git({ "update-ref", "refs/remotes/origin/main", "HEAD~1" })

vim.fn.chdir(dir)

local function picker_remotes()
  local got
  git_diff.get_picker_bases_async(function(remotes)
    got = remotes
  end)
  assert(
    vim.wait(5000, function()
      return got ~= nil
    end),
    "picker timed out"
  )
  return got
end

assert_eq(picker_remotes(), { "origin/master" }, "master is newer than develop and main")

git({ "update-ref", "-d", "refs/remotes/origin/master" })
git({ "update-ref", "-d", "refs/remotes/origin/main" })
assert_eq(picker_remotes(), { "origin/develop" }, "only develop remains")

git({ "update-ref", "-d", "refs/remotes/origin/develop" })
assert_eq(picker_remotes(), {}, "no priority remotes")

vim.fn.delete(dir, "rf")
print("PASS: F1/F2 picker keeps the newest priority remote")
