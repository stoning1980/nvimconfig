-- Run: nvim --headless -u NONE -l tests/git_branch.lua
-- Remote checkout names follow the shell `rbr` sed:
--   sed "s:.* remotes/origin/::" | sed "s:.* ::"
-- Picker rows are for-each-ref lines: name, relative time, subject.
vim.opt.rtp:prepend(vim.fn.getcwd())

local git_branch = require("config.git_branch")

local function assert_eq(actual, expected, label)
  local a = vim.inspect(actual)
  local e = vim.inspect(expected)
  assert(a == e, (label or "") .. " expected " .. e .. " got " .. a)
end

assert_eq(git_branch.remote_checkout_name("  origin/develop"), "origin/develop", "plain remote")
assert_eq(git_branch.remote_checkout_name("  origin/feature/foo"), "origin/feature/foo", "nested remote")
assert_eq(git_branch.remote_checkout_name("  origin/HEAD -> origin/main"), "origin/main", "HEAD alias keeps the target")
assert_eq(
  git_branch.remote_checkout_name("  remotes/origin/feature/bar"),
  "feature/bar",
  "remotes/origin prefix is stripped"
)
assert_eq(git_branch.remote_checkout_name("   "), nil, "blank line")
assert_eq(git_branch.remote_checkout_name(nil), nil, "nil line")

assert_eq(
  git_branch.parse_ref_line("main\t2 hours ago\tFix bug"),
  { branch = "main", when = "2 hours ago", subject = "Fix bug" },
  "splits name, time, and subject"
)
assert_eq(git_branch.parse_ref_line("main"), nil, "a name alone is not a row")
assert_eq(git_branch.parse_ref_line(nil), nil, "nil row")

assert_eq(
  git_branch.format_branch({ branch = "main", when = "2 hours ago", subject = "Fix bug" }, true, 9),
  "* main       2 hours ago       Fix bug",
  "pads the branch and the relative time"
)

assert_eq(
  git_branch.branch_items({
    "origin/HEAD\t1 hour ago\tpointer",
    "origin/main\t2 days ago\tRelease",
    "origin/develop\t3 hours ago\tBump version",
  }, { remote = true, head = "develop", upstream = "origin/develop" }),
  {
    {
      text = "  origin/main     2 days ago        Release",
      branch = "origin/main",
      idx = 1,
    },
    {
      text = "* origin/develop  3 hours ago       Bump version",
      branch = "origin/develop",
      idx = 2,
    },
  },
  "remote list skips HEAD, marks upstream, and keeps time plus subject"
)

assert_eq(
  git_branch.branch_items({
    "feature/a\t1 day ago\tAdd feature",
    "main\t2 hours ago\tFix bug",
    "feature/a\t1 day ago\tAdd feature",
  }, { remote = false, head = "main" }),
  {
    {
      text = "  feature/a  1 day ago         Add feature",
      branch = "feature/a",
      idx = 1,
    },
    {
      text = "* main       2 hours ago       Fix bug",
      branch = "main",
      idx = 2,
    },
  },
  "local list de-duplicates, marks HEAD, and shows time plus subject"
)

assert_eq(
  git_branch.parse_branch_status({
    "# branch.oid abc",
    "# branch.head main",
    "# branch.upstream origin/main",
    "# branch.ab +0 -0",
  }),
  { head = "main", upstream = "origin/main" },
  "status names the local branch and its remote"
)
assert_eq(
  git_branch.parse_branch_status({ "# branch.head (detached)", "# branch.oid abc" }),
  { head = "HEAD", upstream = nil },
  "a detached HEAD is HEAD"
)
assert_eq(
  git_branch.prefer_remote_ref({ "upstream/topic", "origin/HEAD", "origin/topic" }),
  "origin/topic",
  "prefer origin"
)
assert_eq(git_branch.prefer_remote_ref({ "origin/HEAD" }), nil, "symbolic HEAD is not a branch")
assert_eq(
  git_branch.head_summary({ head = "main", upstream = "origin/main" }),
  "main → origin/main",
  "local branch and its remote"
)
assert_eq(git_branch.head_summary({ head = "topic" }), "topic", "local branch with no remote")
assert_eq(
  git_branch.head_summary({ head = "HEAD", detached_at = "origin/topic" }),
  "detached at origin/topic",
  "detached at a remote branch"
)
assert_eq(git_branch.head_summary({ head = "HEAD" }), "detached", "detached with no remote name")
assert_eq(git_branch.head_summary({}), nil, "unknown HEAD")

print("ok")
