-- Run: nvim --headless -u NONE -l tests/ai_tool_excludes.lua
-- <F1> Git status must drop coding-agent directories from the Diffview file
-- list. They must not be passed as path args: Diffview treats those as the
-- diff scope, prints them under "Showing changes for", and then shows nothing.
vim.opt.rtp:prepend(vim.fn.getcwd())
vim.opt.rtp:append(vim.fn.stdpath("data") .. "/lazy/diffview.nvim")
require("diffview").setup({
  git_cmd = { "git", "--no-pager" },
  hooks = {
    view_opened = function(view)
      require("config.git_diff").consume_ai_tool_filter(view)
    end,
  },
})

local git_diff = require("config.git_diff")

local function assert_eq(actual, expected, label)
  assert(actual == expected, (label or "") .. " expected " .. vim.inspect(expected) .. " got " .. vim.inspect(actual))
end

assert_eq(git_diff.is_ai_tool_path(".cursor/hooks/track.js"), true, "root tool dir")
assert_eq(git_diff.is_ai_tool_path("src/.claude/c.txt"), true, "nested tool dir")
assert_eq(git_diff.is_ai_tool_path("sub/.ttadk/a.txt"), true, "nested ttadk")
assert_eq(git_diff.is_ai_tool_path(".agency/keep.txt"), false, "prefix must not match")
assert_eq(git_diff.is_ai_tool_path("src/real.kt"), false, "source file")
assert_eq(git_diff.is_ai_tool_path("cursor/a.txt"), false, "name without a dot")

local dropped = {
  conflicting = { { path = ".cursor/conflict" } },
  working = { { path = "src/real.kt" }, { path = ".claude/b.txt" }, { path = ".agency/keep.txt" } },
  staged = { { path = ".trae/c.txt" }, { path = "src/staged.kt" } },
}
function dropped:set_conflicting(list)
  self.conflicting = list
end
function dropped:set_working(list)
  self.working = list
end
function dropped:set_staged(list)
  self.staged = list
end
function dropped:update_file_trees() end
git_diff.drop_ai_tool_files(dropped)
assert_eq(#dropped.conflicting, 0, "conflicting")
assert_eq(#dropped.working, 2, "working")
assert_eq(dropped.working[1].path, "src/real.kt", "working source")
assert_eq(dropped.working[2].path, ".agency/keep.txt", "working lookalike")
assert_eq(#dropped.staged, 1, "staged")
assert_eq(dropped.staged[1].path, "src/staged.kt", "staged source")

local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")

local function write(path, text)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  vim.fn.writefile({ text }, path)
end

local function git(cwd, ...)
  local out = vim.fn.system({ "git", "-C", cwd, ... })
  assert(vim.v.shell_error == 0, out)
  return out
end

git(root, "init", "-q")
write(root .. "/src/real.kt", "base")
write(root .. "/.cursor/nested/deep.txt", "base")
write(root .. "/src/.claude/c.txt", "base")
write(root .. "/.agency/keep.txt", "base")
git(root, "add", "-A")
git(root, "-c", "user.email=t@example.com", "-c", "user.name=test", "commit", "-q", "-m", "init")
write(root .. "/src/real.kt", "chg")
write(root .. "/.cursor/nested/deep.txt", "chg")
write(root .. "/src/.claude/c.txt", "chg")
write(root .. "/.agency/keep.txt", "chg")

local prev = vim.fn.getcwd()
vim.cmd.cd(root .. "/src")
git_diff.arm_ai_tool_filter()
require("diffview").open()

local view
vim.wait(4000, function()
  view = require("diffview.lib").get_current_view()
  return view and view.files and view.files:len() > 0
end, 50)

assert(view, "Diffview did not open")
assert(
  not view.path_args or #view.path_args == 0,
  "path args leaked into the diff scope: " .. vim.inspect(view.path_args)
)

local paths = {}
for _, entry in ipairs(view.files.working) do
  paths[#paths + 1] = entry.path
end
for _, entry in ipairs(view.files.staged) do
  paths[#paths + 1] = entry.path
end
table.sort(paths)
assert_eq(table.concat(paths, "\n"), ".agency/keep.txt\nsrc/real.kt", "file list")

vim.cmd.cd(prev)
print("PASS: F1 Git status Diffview skips AI tool directories")
vim.cmd("qa!")
