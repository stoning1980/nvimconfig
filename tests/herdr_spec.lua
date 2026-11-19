local root = vim.fn.getcwd()
package.path = root .. "/dev/herdr.nvim/lua/?.lua;" .. root .. "/dev/herdr.nvim/lua/?/init.lua;" .. package.path

local context = require("herdr.context")
local config = require("herdr.config")
local discovery = require("herdr.discovery")
local diffview = require("herdr.diffview")
local herdr = require("herdr")
local client = require("herdr.client")
local input = require("herdr.input")
local queue = require("herdr.queue")
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

local BASE_SHA = "1111111111111111111111111111111111111111"
local TARGET_SHA = "2222222222222222222222222222222222222222"
local HEAD_SHA = "3333333333333333333333333333333333333333"
local REV = { LOCAL = 1, COMMIT = 2, STAGE = 3, CUSTOM = 4 }

local function scratch_buffer(lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  return buf
end

local function commit_file(path, revision, lines, extra)
  return vim.tbl_extend("force", {
    path = path,
    basename = vim.fs.basename(path),
    rev = { type = REV.COMMIT, commit = revision },
    bufnr = scratch_buffer(lines),
  }, extra or {})
end

local function comparison_view(base_file, target_file, extra_windows)
  local windows = {
    {
      id = 101,
      file = base_file,
      is_file_open = function()
        return true
      end,
    },
    {
      id = 102,
      file = target_file,
      is_file_open = function()
        return true
      end,
    },
  }
  vim.list_extend(windows, extra_windows or {})
  return {
    adapter = { ctx = { toplevel = "/work/app" } },
    cur_layout = { windows = windows },
  }
end

local function version_selection(start_line, end_line, text)
  return {
    start_line = start_line,
    start_col = 0,
    end_line = end_line,
    end_col = #(text:match("[^\n]*$") or ""),
    text = text,
  }
end

local function metadata()
  return { branch = "feature/review", revision = HEAD_SHA }
end

local function test_captures_before_and_current_change_from_right_pane()
  local base = commit_file("lua/old_name.lua", BASE_SHA, { "one", "old", "same" })
  local target = commit_file("lua/new_name.lua", HEAD_SHA, { "one", "new", "same" })
  local selected, err =
    diffview.snapshot(comparison_view(base, target), 102, version_selection(2, 2, "new"), metadata())

  assert(not err, err)
  assert_equal(selected.repo_root, "/work/app")
  assert_equal(selected.path, "lua/new_name.lua")
  assert_equal(selected.revision, HEAD_SHA)
  assert_equal(selected.comparison, nil)
  assert(selected.change.patch:find("%-%-%- before:lua/old_name.lua"))
  assert(selected.change.patch:find("%+%+%+ current:lua/new_name.lua"))
  assert(selected.change.patch:find("%-old"))
  assert(selected.change.patch:find("%+new"))
end

test_captures_before_and_current_change_from_right_pane()

local function test_rejects_left_side_comments()
  local base = commit_file("lua/example.lua", BASE_SHA, { "one", "old", "same" })
  local target = commit_file("lua/example.lua", HEAD_SHA, { "one", "new", "same" })
  local _, err = diffview.snapshot(comparison_view(base, target), 101, version_selection(2, 2, "old"), metadata())

  assert_equal(err, "Herdr Diffview comments must be made from the right/current pane")
end

test_rejects_left_side_comments()

local function test_rejects_historical_right_side()
  local base = commit_file("lua/example.lua", BASE_SHA, { "one", "old", "same" })
  local target = commit_file("lua/example.lua", TARGET_SHA, { "one", "historical", "same" })
  local _, err =
    diffview.snapshot(comparison_view(base, target), 102, version_selection(2, 2, "historical"), metadata())

  assert_equal(err, "right Diffview pane is not the checked-out HEAD or working tree")
end

test_rejects_historical_right_side()

local function test_keeps_only_hunks_overlapping_the_selection()
  local base_lines = { "start", "old-one" }
  local target_lines = { "start", "new-one" }
  for index = 1, 10 do
    base_lines[#base_lines + 1] = "gap-" .. index
    target_lines[#target_lines + 1] = "gap-" .. index
  end
  base_lines[#base_lines + 1] = "old-two"
  target_lines[#target_lines + 1] = "new-two"

  local selected, err = diffview.snapshot(
    comparison_view(
      commit_file("lua/example.lua", BASE_SHA, base_lines),
      commit_file("lua/example.lua", HEAD_SHA, target_lines)
    ),
    102,
    version_selection(2, 2, "new-one"),
    metadata()
  )

  assert(not err, err)
  assert(selected.change.patch:find("old%-one"))
  assert(selected.change.patch:find("new%-one"))
  assert(not selected.change.patch:find("old%-two"))
  assert(not selected.change.patch:find("new%-two"))
end

test_keeps_only_hunks_overlapping_the_selection()

local function test_marks_selection_outside_changed_hunks()
  local base_lines = { "old" }
  local target_lines = { "new" }
  for index = 1, 10 do
    base_lines[#base_lines + 1] = "same-" .. index
    target_lines[#target_lines + 1] = "same-" .. index
  end
  local selected, err = diffview.snapshot(
    comparison_view(
      commit_file("lua/example.lua", BASE_SHA, base_lines),
      commit_file("lua/example.lua", HEAD_SHA, target_lines)
    ),
    102,
    version_selection(11, 11, "same-10"),
    metadata()
  )

  assert(not err, err)
  assert_equal(selected.change.patch, nil)
  assert_equal(selected.change.note, "No changed hunk overlaps the selected current lines.")
end

test_marks_selection_outside_changed_hunks()

local function test_accepts_worktree_as_current_right_side()
  local base = commit_file("lua/example.lua", BASE_SHA, { "staged" }, { rev = { type = REV.STAGE, stage = 0 } })
  local target = commit_file("lua/example.lua", TARGET_SHA, { "working" }, { rev = { type = REV.LOCAL } })
  local selected, err =
    diffview.snapshot(comparison_view(base, target), 102, version_selection(1, 1, "working"), metadata())

  assert(not err, err)
  assert(selected.change.patch:find("%-staged"))
  assert(selected.change.patch:find("%+working"))
end

test_accepts_worktree_as_current_right_side()

local function test_rejects_index_as_current_right_side()
  local base = commit_file("lua/example.lua", BASE_SHA, { "head" })
  local target = commit_file("lua/example.lua", TARGET_SHA, { "staged" }, { rev = { type = REV.STAGE, stage = 0 } })
  local _, err = diffview.snapshot(comparison_view(base, target), 102, version_selection(1, 1, "staged"), metadata())

  assert_equal(err, "right Diffview pane is not the checked-out HEAD or working tree")
end

test_rejects_index_as_current_right_side()

local function test_rejects_custom_revision_as_current_right_side()
  local base = commit_file("lua/example.lua", BASE_SHA, { "before" })
  local target = commit_file("lua/example.lua", TARGET_SHA, { "custom" }, { rev = { type = REV.CUSTOM } })
  local _, err = diffview.snapshot(comparison_view(base, target), 102, version_selection(1, 1, "custom"), metadata())

  assert_equal(err, "right Diffview pane is not the checked-out HEAD or working tree")
end

test_rejects_custom_revision_as_current_right_side()

local function test_treats_null_counterpart_as_empty_for_added_file()
  local base = commit_file("lua/new.lua", BASE_SHA, {}, { nulled = true })
  local target = commit_file("lua/new.lua", HEAD_SHA, { "added" })
  local selected, err =
    diffview.snapshot(comparison_view(base, target), 102, version_selection(1, 1, "added"), metadata())

  assert(not err, err)
  assert(selected.change.patch:find("%+added"))
end

test_treats_null_counterpart_as_empty_for_added_file()

local function test_rejects_unsupported_diffview_states()
  local base = commit_file("lua/example.lua", BASE_SHA, { "old" })
  local target = commit_file("lua/example.lua", HEAD_SHA, { "new" })

  local _, panel_err = diffview.snapshot(comparison_view(base, target), 999, version_selection(1, 1, "new"), metadata())
  assert_equal(panel_err, "current window is not a Diffview file pane")

  local third = { id = 103, file = commit_file("lua/example.lua", HEAD_SHA, { "third" }) }
  local _, layout_err =
    diffview.snapshot(comparison_view(base, target, { third }), 102, version_selection(1, 1, "new"), metadata())
  assert_equal(layout_err, "Herdr comments support only two-way Diffview layouts")

  target.binary = true
  local _, binary_err =
    diffview.snapshot(comparison_view(base, target), 102, version_selection(1, 1, "new"), metadata())
  assert_equal(binary_err, "binary Diffview files cannot be reviewed as text")

  target.binary = false
  target.nulled = true
  local _, null_err = diffview.snapshot(comparison_view(base, target), 102, version_selection(1, 1, "new"), metadata())
  assert_equal(null_err, "the selected Diffview side has no file content")

  target.nulled = false
  local stale_view = comparison_view(base, target)
  stale_view.cur_layout.windows[2].is_nulled = function()
    return true
  end
  local _, stale_err = diffview.snapshot(stale_view, 102, version_selection(1, 1, "new"), metadata())
  assert_equal(stale_err, "the selected Diffview side is displaying the null buffer")

  local conflict_base = commit_file("lua/example.lua", BASE_SHA, { "ours" }, { rev = { type = REV.STAGE, stage = 2 } })
  local conflict_target = commit_file(
    "lua/example.lua",
    HEAD_SHA,
    { "theirs" },
    { rev = { type = REV.STAGE, stage = 3 } }
  )
  local _, conflict_err = diffview.snapshot(
    comparison_view(conflict_base, conflict_target),
    102,
    version_selection(1, 1, "theirs"),
    metadata()
  )
  assert_equal(conflict_err, "conflicting Diffview stages cannot be reviewed as a two-way comparison")

  local replaced_view = comparison_view(base, target)
  replaced_view.cur_layout.windows[2].is_file_open = function()
    return false
  end
  local _, replaced_err = diffview.snapshot(replaced_view, 102, version_selection(1, 1, "new"), metadata())
  assert_equal(replaced_err, "right Diffview pane is not displaying its current file")
end

test_rejects_unsupported_diffview_states()

local function test_detects_when_right_buffer_differs_from_checked_out_file()
  local target = commit_file("lua/example.lua", HEAD_SHA, { "buffer content" })
  local path = vim.fn.tempname()
  vim.fn.writefile({ "checked out content" }, path)
  target.absolute_path = path

  assert_equal(diffview.matches_worktree(target), false)
  vim.fn.writefile({ "buffer content" }, path)
  assert_equal(diffview.matches_worktree(target), true)
  vim.fn.delete(path)
end

test_detects_when_right_buffer_differs_from_checked_out_file()

local function test_captures_nowrite_diffview_buffer_before_file_guard()
  local original_buf = vim.api.nvim_get_current_buf()
  local current_win = vim.api.nvim_get_current_win()
  local base = commit_file("lua/example.lua", BASE_SHA, { "one", "old", "same" })
  local current_revision = repo.for_root(root).revision
  local target = commit_file("lua/example.lua", current_revision, { "one", "new", "same" })
  target.absolute_path = vim.fn.tempname()
  vim.fn.writefile({ "one", "new", "same" }, target.absolute_path)
  vim.bo[target.bufnr].buftype = "nowrite"
  vim.api.nvim_win_set_buf(current_win, target.bufnr)
  vim.api.nvim_win_set_cursor(current_win, { 2, 0 })

  local old_lib = package.loaded["diffview.lib"]
  package.loaded["diffview.lib"] = {
    get_current_view = function()
      return {
        adapter = { ctx = { toplevel = root } },
        cur_layout = {
          windows = {
            {
              id = 987654,
              file = base,
              is_file_open = function()
                return true
              end,
            },
            {
              id = current_win,
              file = target,
              is_file_open = function()
                return true
              end,
            },
          },
        },
      }
    end,
  }

  local selected = herdr.capture(false)

  package.loaded["diffview.lib"] = old_lib
  vim.api.nvim_win_set_buf(current_win, original_buf)
  vim.fn.delete(target.absolute_path)

  assert(selected, "expected Diffview selection")
  assert_equal(selected.path, "lua/example.lua")
  assert_equal(selected.text, "new")
  assert(selected.change.patch:find("%-old"))
  assert(selected.change.patch:find("%+new"))
end

test_captures_nowrite_diffview_buffer_before_file_guard()

local function test_rejects_diffview_buffer_that_differs_from_checked_out_file()
  local original_buf = vim.api.nvim_get_current_buf()
  local current_win = vim.api.nvim_get_current_win()
  local current_revision = repo.for_root(root).revision
  local base = commit_file("lua/example.lua", BASE_SHA, { "old" })
  local target = commit_file("lua/example.lua", current_revision, { "displayed" })
  target.absolute_path = vim.fn.tempname()
  vim.fn.writefile({ "checked out" }, target.absolute_path)
  vim.bo[target.bufnr].buftype = "nowrite"
  vim.api.nvim_win_set_buf(current_win, target.bufnr)

  local old_lib = package.loaded["diffview.lib"]
  package.loaded["diffview.lib"] = {
    get_current_view = function()
      return {
        adapter = { ctx = { toplevel = root } },
        cur_layout = {
          windows = {
            {
              id = 987654,
              file = base,
              is_file_open = function()
                return true
              end,
            },
            {
              id = current_win,
              file = target,
              is_file_open = function()
                return true
              end,
            },
          },
        },
      }
    end,
  }

  local echoed
  local original_echo = vim.api.nvim_echo
  vim.api.nvim_echo = function(chunks)
    echoed = chunks[1][1]
  end
  local selected = herdr.capture(false)
  vim.wait(50, function()
    return echoed ~= nil
  end)
  vim.api.nvim_echo = original_echo

  package.loaded["diffview.lib"] = old_lib
  vim.api.nvim_win_set_buf(current_win, original_buf)
  vim.fn.delete(target.absolute_path)

  assert_equal(selected, nil)
  assert_equal(echoed, "[herdr] right Diffview pane does not match the checked-out file")
end

test_rejects_diffview_buffer_that_differs_from_checked_out_file()

local function test_captures_ordinary_file_in_extra_diffview_tab_split()
  local original_buf = vim.api.nvim_get_current_buf()
  local current_win = vim.api.nvim_get_current_win()
  local file_buf = vim.fn.bufadd(root .. "/init.lua")
  vim.fn.bufload(file_buf)
  vim.api.nvim_win_set_buf(current_win, file_buf)
  vim.api.nvim_win_set_cursor(current_win, { 1, 0 })

  local old_lib = package.loaded["diffview.lib"]
  package.loaded["diffview.lib"] = {
    get_current_view = function()
      return comparison_view(
        commit_file("lua/example.lua", BASE_SHA, { "old" }),
        commit_file("lua/example.lua", repo.for_root(root).revision, { "new" })
      )
    end,
  }

  local selected = herdr.capture(false)

  package.loaded["diffview.lib"] = old_lib
  vim.api.nvim_win_set_buf(current_win, original_buf)

  assert(selected, "expected ordinary file selection")
  assert_equal(selected.path, "init.lua")
  assert_equal(selected.change, nil)
end

test_captures_ordinary_file_in_extra_diffview_tab_split()

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

  assert_equal(
    prompt,
    table.concat({
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
    }, "\n")
  )
end

test_builds_direct_review_prompt()

local function changed_review(path, before, current)
  return {
    repo_root = "/work/app",
    path = path,
    start_line = 12,
    end_line = 12,
    text = current,
    branch = "feature/review",
    revision = HEAD_SHA,
    change = {
      patch = table.concat({
        "--- before:" .. path,
        "+++ current:" .. path,
        "@@ -12 +12 @@",
        "-" .. before,
        "+" .. current,
      }, "\n"),
    },
  }
end

local function test_builds_before_and_current_review_prompt()
  local prompt = client.review_prompt(changed_review("lua/example.lua", "old()", "new()"), "Keep the old behavior.")

  assert(prompt:find("Repository location: lua/example.lua:12", 1, true))
  assert(prompt:find("Revision: " .. HEAD_SHA, 1, true))
  assert(prompt:find("Selected current code:", 1, true))
  assert(prompt:find("Relevant before/current change:", 1, true))
  assert(prompt:find("```diff\n--- before:lua/example.lua", 1, true))
  assert(prompt:find("-old()\n+new()", 1, true))
  assert(not prompt:find("Base:", 1, true))
  assert(not prompt:find("Target:", 1, true))
  assert(not prompt:find("Anchored on:", 1, true))
end

test_builds_before_and_current_review_prompt()

local function test_describes_selection_outside_changed_hunks()
  local selection = changed_review("lua/example.lua", "old()", "new()")
  selection.change.patch = nil
  selection.change.note = "No changed hunk overlaps the selected current lines."

  local prompt = client.review_prompt(selection, "Explain this line.")

  assert(prompt:find("No changed hunk overlaps the selected current lines.", 1, true))
end

test_describes_selection_outside_changed_hunks()

local function test_keeps_each_before_and_current_patch_in_queue_prompt()
  local first = changed_review("lua/first.lua", "old_first()", "new_first()")
  local second = changed_review("lua/second.lua", "old_second()", "new_second()")

  local prompt = client.queue_prompt({
    { selection = first, comment = "First change." },
    { selection = second, comment = "Second change." },
  })

  assert(prompt:find("-old_first()\n+new_first()", 1, true))
  assert(prompt:find("-old_second()\n+new_second()", 1, true))
end

test_keeps_each_before_and_current_patch_in_queue_prompt()

local function test_keeps_review_comments_in_separate_repo_queues()
  queue.clear("/work/app")
  queue.clear("/work/other")
  local selection = {
    repo_root = "/work/app",
    path = "lua/example.lua",
    start_line = 12,
    end_line = 13,
    text = "first()\nsecond()",
    branch = "feature/review",
    revision = "abc123",
  }

  queue.add(selection, "Guard this value.")
  queue.add(vim.tbl_extend("force", {}, selection, { start_line = 20, end_line = 20, text = "third()" }), "Name this.")
  queue.add({
    repo_root = "/work/other",
    path = "main.lua",
    start_line = 1,
    end_line = 1,
    text = "run()",
    branch = "main",
    revision = "def456",
  }, "Add a test.")

  assert_equal(queue.count("/work/app"), 2)
  assert_equal(queue.count("/work/other"), 1)
  assert_equal(queue.items("/work/app")[1].comment, "Guard this value.")
end

test_keeps_review_comments_in_separate_repo_queues()

local function test_builds_one_prompt_from_queued_comments()
  local prompt = client.queue_prompt(queue.items("/work/app"))

  assert(prompt:find("Queued review comments from Neovim %(2%)"))
  assert(prompt:find("Review 1"))
  assert(prompt:find("Repository location: lua/example.lua:12%-13"))
  assert(prompt:find("Guard this value%."))
  assert(prompt:find("Review 2"))
  assert(prompt:find("Repository location: lua/example.lua:20"))
  assert(prompt:find("Name this%."))
end

test_builds_one_prompt_from_queued_comments()

local function test_formats_queued_comments_for_composer_list()
  assert(vim.deep_equal(input.queue_lines(queue.items("/work/app")), {
    "1. lua/example.lua:12-13 — Guard this value.",
    "2. lua/example.lua:20 — Name this.",
  }))
end

test_formats_queued_comments_for_composer_list()

local function test_submits_on_enter_and_queues_on_ctrl_s()
  local source = table.concat(vim.fn.readfile(root .. "/dev/herdr.nvim/lua/herdr/input.lua"), "\n")
  local fallback = source:match("if not ok then(.-)\n  end\n\n  local win")

  assert(source:find('footer = " Enter = Submit all   Ctrl+S = Add to queue', 1, true))
  assert(source:find('vim.keymap.set({ "i", "n" }, "<CR>", submit', 1, true))
  assert(source:find('vim.keymap.set({ "i", "n" }, "<C-s>", add', 1, true))
  assert(fallback and fallback:find("actions.on_submit(comment)", 1, true))
end

test_submits_on_enter_and_queues_on_ctrl_s()

local function test_formats_changed_queue_item_as_current_location()
  local selection = changed_review("lua/example.lua", "old()", "new()")
  local lines = input.queue_lines({ { selection = selection, comment = "Keep this behavior." } })

  assert(vim.deep_equal(lines, {
    "1. lua/example.lua:12 — Keep this behavior.",
  }))
end

test_formats_changed_queue_item_as_current_location()

local function test_resolves_git_context_for_file()
  local info = repo.for_path(root .. "/tests/herdr_spec.lua")

  assert_equal(info.root, root)
  assert_equal(info.relpath, "tests/herdr_spec.lua")
  assert(info.branch and info.branch ~= "", "expected branch")
  assert(info.revision and #info.revision >= 7, "expected revision")
end

test_resolves_git_context_for_file()

local function test_resolves_git_context_for_root()
  local info = repo.for_root(root)

  assert_equal(info.root, root)
  assert(info.branch and info.branch ~= "", "expected branch")
  assert(info.revision and #info.revision == 40, "expected full HEAD revision")
end

test_resolves_git_context_for_root()

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

local function test_exposes_a_submit_queue_command()
  local herdr_spec = table.concat(vim.fn.readfile(root .. "/lua/plugins/herdr.lua"), "\n")
  assert(herdr_spec:find('"HerdrSubmitQueue"', 1, true), "Herdr must expose queue submission")
end

test_exposes_a_submit_queue_command()

local function test_uses_messages_instead_of_toast_notifications()
  local herdr_init = table.concat(vim.fn.readfile(root .. "/dev/herdr.nvim/lua/herdr/init.lua"), "\n")
  assert(not herdr_init:find("vim.notify(", 1, true), "Herdr feedback must not create toast notifications")
end

test_uses_messages_instead_of_toast_notifications()
print("herdr_spec: all tests passed")
