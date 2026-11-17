local root = vim.fn.getcwd()
package.path = root .. "/dev/herdr.nvim/lua/?.lua;" .. root .. "/dev/herdr.nvim/lua/?/init.lua;" .. package.path

local context = require("herdr.context")
local config = require("herdr.config")
local discovery = require("herdr.discovery")
local client = require("herdr.client")
local repo = require("herdr.repo")

local function assert_equal(actual, expected, message)
  if actual ~= expected then
    error((message or "values differ") .. ": expected " .. vim.inspect(expected) .. ", got " .. vim.inspect(actual))
  end
end

local function test_normalizes_visual_context()
  local selected = context.selection({
    repo_root = "/work/app",
    path = "/work/app/lua/example.lua",
    start_line = 12,
    start_col = 4,
    end_line = 13,
    end_col = 8,
    text = "first()\nsecond()",
    branch = "feature/review",
    revision = "abc123",
  })

  assert_equal(selected.path, "lua/example.lua")
  assert_equal(selected.repo_root, "/work/app")
  assert_equal(selected.start_line, 12)
  assert_equal(selected.end_line, 13)
  assert_equal(selected.text, "first()\nsecond()")
  assert_equal(selected.branch, "feature/review")
  assert_equal(selected.revision, "abc123")
end

test_normalizes_visual_context()

local function test_extracts_only_visual_block_columns()
  assert_equal(context.block_text({ "abcde", "12", "vwxyz" }, 1, 3), "bcd\n2\nwxy")
end

test_extracts_only_visual_block_columns()

local function test_merges_user_options_with_defaults()
  local options = config.setup({ input = { width = 0.75 } })

  assert_equal(options.input.width, 0.75)
  assert_equal(options.input.height, 0.3)
end

test_merges_user_options_with_defaults()

local function test_matches_agents_by_workspace_path()
  local agents = discovery.match_agents({
    result = {
      snapshot = {
        agents = {
          { agent = "claude", agent_status = "idle", cwd = "/work/app", pane_id = "w1:p1" },
          { agent = "cursor", agent_status = "working", foreground_cwd = "/work/app/subdir", pane_id = "w1:p2" },
          { agent = "codex", agent_status = "idle", cwd = "/elsewhere", pane_id = "w2:p1" },
        },
      },
    },
  }, "/work/app")

  assert_equal(#agents, 2)
  assert_equal(agents[1].pane_id, "w1:p1")
  assert_equal(agents[2].pane_id, "w1:p2")
end

test_matches_agents_by_workspace_path()

local function test_uses_snapshot_command_without_json_flag()
  assert_equal(table.concat(discovery.snapshot_command(), " "), "herdr api snapshot")
end

test_uses_snapshot_command_without_json_flag()

local function test_builds_direct_review_prompt()
  local prompt = client.review_prompt({
    path = "lua/example.lua",
    start_line = 12,
    end_line = 13,
    text = "first()\nsecond()",
    branch = "feature/review",
    revision = "abc123",
  }, "Please guard this nil value.")

  assert_equal(prompt, table.concat({
    "Review comment from Neovim",
    "Repository location: lua/example.lua:12-13",
    "Branch: feature/review",
    "Revision: abc123",
    "",
    "Selected code:",
    "```",
    "first()",
    "second()",
    "```",
    "",
    "Comment:",
    "Please guard this nil value.",
  }, "\n"))
end

test_builds_direct_review_prompt()

local function test_resolves_git_context_for_file()
  local info = repo.for_path(root .. "/tests/herdr_spec.lua")

  assert_equal(info.root, root)
  assert_equal(info.relpath, "tests/herdr_spec.lua")
  assert(info.branch and info.branch ~= "", "expected branch")
  assert(info.revision and #info.revision >= 7, "expected revision")
end

test_resolves_git_context_for_file()

local function test_resolves_git_context_for_symlinked_file()
  local temp = vim.fn.tempname()
  vim.fn.mkdir(temp, "p")
  local linked_root = temp .. "/repo"
  assert(vim.uv.fs_symlink(root, linked_root))

  local info = repo.for_path(linked_root .. "/tests/herdr_spec.lua")
  vim.fn.delete(temp, "rf")

  assert_equal(info.root, root)
  assert_equal(info.relpath, "tests/herdr_spec.lua")
end

test_resolves_git_context_for_symlinked_file()

local function test_reserves_f8_for_herdr_not_claudeide()
  local claudeide_spec = table.concat(vim.fn.readfile(root .. "/lua/plugins/claudeide.lua"), "\n")
  local herdr_spec = table.concat(vim.fn.readfile(root .. "/lua/plugins/herdr.lua"), "\n")

  assert(not claudeide_spec:find('"<F8>"', 1, true), "Claude IDE must not own F8")
  assert(not claudeide_spec:find('"<S-F8>"', 1, true), "Claude IDE must not own Shift+F8")
  assert(herdr_spec:find('"<F8>"', 1, true), "Herdr must own F8")
end

test_reserves_f8_for_herdr_not_claudeide()
print("herdr_spec: all tests passed")
