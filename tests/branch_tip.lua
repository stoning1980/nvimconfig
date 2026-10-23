-- Run: nvim --headless -u NONE -l tests/branch_tip.lua
-- :Pdf opens branch~..branch for a local branch. No argument means "open the
-- picker", so the parsed name is nil.
vim.opt.rtp:prepend(vim.fn.getcwd())

local git_diff = require("config.git_diff")

local function assert_eq(actual, expected, label)
  local a = vim.inspect(actual)
  local e = vim.inspect(expected)
  assert(a == e, (label or "") .. " expected " .. e .. " got " .. a)
end

assert_eq(git_diff.local_branch_arg(nil), nil, "nil arg")
assert_eq(git_diff.local_branch_arg(""), nil, "empty arg")
assert_eq(git_diff.local_branch_arg("   "), nil, "blank arg")
assert_eq(git_diff.local_branch_arg("main"), "main", "plain branch")
assert_eq(git_diff.local_branch_arg("  feature/foo  "), "feature/foo", "trimmed branch")
assert_eq(git_diff.local_branch_arg("(001) feature/foo"), "feature/foo", "completion item")
assert_eq(git_diff.local_branch_arg("  (002) topic  "), "topic", "padded completion item")

assert_eq(git_diff.branch_tip_range("main"), "main~..main", "tip range")
assert_eq(git_diff.branch_tip_range("feature/foo"), "feature/foo~..feature/foo", "nested branch")

print("branch_tip: ok")
