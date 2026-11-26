local root = vim.fn.getcwd()
package.path = root
  .. "/dev/reviewbuddy.nvim/lua/?.lua;"
  .. root
  .. "/dev/reviewbuddy.nvim/lua/?/init.lua;"
  .. package.path

local context = require("reviewbuddy.context")
local app = require("reviewbuddy.app")
local cmux = require("reviewbuddy.cmux")
local config = require("reviewbuddy.config")
local discovery = require("reviewbuddy.discovery")
local diffview = require("reviewbuddy.diffview")
local herdr_backend = require("reviewbuddy.backends.herdr")
local reviewbuddy = require("reviewbuddy")
local client = require("reviewbuddy.client")
local input = require("reviewbuddy.input")
local queue = require("reviewbuddy.queue")
local repo = require("reviewbuddy.repo")
local submit = require("reviewbuddy.submit")
local targets = require("reviewbuddy.targets")

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

local function test_includes_complete_multibyte_character_at_block_selection_endpoint()
  assert_equal(context.block_text({ "a界b" }, 1, 1), "界")
end

test_includes_complete_multibyte_character_at_block_selection_endpoint()

local function test_captures_first_live_visual_selection_before_marks_exist()
  local original_buf = vim.api.nvim_get_current_buf()
  local current_win = vim.api.nvim_get_current_win()
  local file_buf = vim.fn.bufadd(root .. "/tests/reviewbuddy_spec.lua")
  vim.fn.bufload(file_buf)
  vim.api.nvim_win_set_buf(current_win, file_buf)
  pcall(vim.api.nvim_buf_del_mark, file_buf, "<")
  pcall(vim.api.nvim_buf_del_mark, file_buf, ">")
  vim.api.nvim_win_set_cursor(current_win, { 1, 0 })
  vim.cmd("normal! v4l")

  local selected = reviewbuddy.capture(true)

  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
  vim.api.nvim_win_set_buf(current_win, original_buf)
  assert(selected, "expected live visual selection")
  assert_equal(selected.start_line, 1)
  assert_equal(selected.start_col, 0)
  assert_equal(selected.end_line, 1)
  assert_equal(selected.end_col, 4)
  assert_equal(selected.text, "local")
end

test_captures_first_live_visual_selection_before_marks_exist()

local function test_captures_complete_multibyte_character_selection()
  local original_buf = vim.api.nvim_get_current_buf()
  local current_win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_create_buf(false, false)
  vim.api.nvim_buf_set_name(buf, root .. "/tests/multibyte-selection-fixture.lua")
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "a界b" })
  vim.api.nvim_win_set_buf(current_win, buf)
  vim.api.nvim_win_set_cursor(current_win, { 1, 1 })
  vim.cmd("normal! v")

  local selected = reviewbuddy.capture(true)

  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
  vim.api.nvim_win_set_buf(current_win, original_buf)
  vim.api.nvim_buf_delete(buf, { force = true })
  assert(selected, "expected multibyte project selection")
  assert_equal(selected.text, "界")
end

test_captures_complete_multibyte_character_selection()

local function test_normalizes_reverse_blockwise_selection_columns_independently()
  local original_buf = vim.api.nvim_get_current_buf()
  local current_win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_create_buf(false, false)
  vim.api.nvim_buf_set_name(buf, root .. "/tests/block-selection-fixture.lua")
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "abcdef", "uvwxyz", "123456" })
  vim.api.nvim_win_set_buf(current_win, buf)
  vim.api.nvim_win_set_cursor(current_win, { 3, 1 })
  vim.cmd("normal! \22" .. "2k3l")

  local selected = reviewbuddy.capture(true)

  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
  vim.api.nvim_win_set_buf(current_win, original_buf)
  vim.api.nvim_buf_delete(buf, { force = true })
  assert(selected, "expected reverse blockwise selection")
  assert_equal(selected.start_line, 1)
  assert_equal(selected.start_col, 1)
  assert_equal(selected.end_line, 3)
  assert_equal(selected.end_col, 4)
  assert_equal(selected.text, "bcde\nvwxy\n2345")
end

test_normalizes_reverse_blockwise_selection_columns_independently()

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

  assert_equal(err, "Review comments must be made from the right/current Diffview pane")
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
  local base = commit_file("lua/new.lua", BASE_SHA, {}, { nulled = true, binary = true })
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
  assert_equal(layout_err, "Review comments support only two-way Diffview layouts")

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

  local selected = reviewbuddy.capture(false)

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
  local base = commit_file("lua/example.lua", BASE_SHA, { "old" })
  local target = commit_file("lua/example.lua", TARGET_SHA, { "displayed" }, { rev = { type = REV.LOCAL } })
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
  local selected = reviewbuddy.capture(false)
  vim.wait(50, function()
    return echoed ~= nil
  end)
  vim.api.nvim_echo = original_echo

  package.loaded["diffview.lib"] = old_lib
  vim.api.nvim_win_set_buf(current_win, original_buf)
  vim.fn.delete(target.absolute_path)

  assert_equal(selected, nil)
  assert_equal(echoed, "[review] right Diffview pane does not match the checked-out file")
end

test_rejects_diffview_buffer_that_differs_from_checked_out_file()

local function test_accepts_head_commit_when_worktree_has_moved_on()
  local original_buf = vim.api.nvim_get_current_buf()
  local current_win = vim.api.nvim_get_current_win()
  local current_revision = repo.for_root(root).revision
  local base = commit_file("lua/example.lua", BASE_SHA, { "old" })
  local target = commit_file("lua/example.lua", current_revision, { "head version" })
  target.absolute_path = vim.fn.tempname()
  vim.fn.writefile({ "worktree version" }, target.absolute_path)
  vim.bo[target.bufnr].buftype = "nowrite"
  vim.api.nvim_win_set_buf(current_win, target.bufnr)
  vim.api.nvim_win_set_cursor(current_win, { 1, 0 })

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

  local selected = reviewbuddy.capture(false)

  package.loaded["diffview.lib"] = old_lib
  vim.api.nvim_win_set_buf(current_win, original_buf)
  vim.fn.delete(target.absolute_path)

  assert(selected, "expected HEAD commit selection")
  assert_equal(selected.path, "lua/example.lua")
  assert_equal(selected.text, "head version")
  assert(selected.change.patch:find("%-old"))
  assert(selected.change.patch:find("%+head version"))
end

test_accepts_head_commit_when_worktree_has_moved_on()

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

  local selected = reviewbuddy.capture(false)

  package.loaded["diffview.lib"] = old_lib
  vim.api.nvim_win_set_buf(current_win, original_buf)

  assert(selected, "expected ordinary file selection")
  assert_equal(selected.path, "init.lua")
  assert_equal(selected.change, nil)
end

test_captures_ordinary_file_in_extra_diffview_tab_split()

local function capture_project_file(project_root, file_path, lines, changed_cwd)
  local original_buf = vim.api.nvim_get_current_buf()
  local original_cwd = vim.fn.getcwd()
  local original_repo_for_path = repo.for_path
  local current_win = vim.api.nvim_get_current_win()
  vim.fn.mkdir(vim.fs.dirname(file_path), "p")
  vim.fn.writefile(lines, file_path)
  local buf = vim.api.nvim_create_buf(false, false)
  vim.api.nvim_buf_set_name(buf, file_path)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = "lua"
  vim.api.nvim_win_set_buf(current_win, buf)
  vim.api.nvim_win_set_cursor(current_win, { 2, 0 })
  config.setup({ project_root = project_root })
  if changed_cwd then
    vim.cmd.cd(changed_cwd)
  end
  repo.for_path = function()
    error("ordinary project capture must not query Git")
  end

  local ok, selected = xpcall(function()
    return reviewbuddy.capture(false)
  end, debug.traceback)

  repo.for_path = original_repo_for_path
  vim.api.nvim_win_set_buf(current_win, original_buf)
  vim.api.nvim_buf_delete(buf, { force = true })
  vim.cmd.cd(original_cwd)
  config.setup({})
  if not ok then
    error(selected)
  end
  return selected
end

local function test_captures_nested_repo_file_against_immutable_project_root_without_git()
  local temp = vim.fn.tempname()
  local project_root = temp .. "/project"
  local nested_repo = project_root .. "/apps/video"
  local changed_cwd = temp .. "/other"
  vim.fn.mkdir(nested_repo .. "/.git", "p")
  vim.fn.mkdir(changed_cwd, "p")
  project_root = assert(vim.uv.fs_realpath(project_root))
  nested_repo = project_root .. "/apps/video"

  local selected = capture_project_file(
    project_root,
    nested_repo .. "/src/example.lua",
    { "local first = 1", "return first" },
    changed_cwd
  )

  vim.fn.delete(temp, "rf")
  assert(selected, "expected project editor selection")
  assert_equal(selected.context_kind, "project")
  assert_equal(selected.repo_root, project_root)
  assert_equal(selected.project_root, project_root)
  assert_equal(selected.path, "apps/video/src/example.lua")
  assert_equal(selected.project_relative_path, "apps/video/src/example.lua")
  assert_equal(selected.absolute_path, project_root .. "/apps/video/src/example.lua")
  assert_equal(selected.filetype, "lua")
  assert_equal(selected.selection_kind, "file")
  assert_equal(selected.start_line, nil)
  assert_equal(selected.end_line, nil)
  assert_equal(selected.text, nil)
  assert_equal(selected.branch, nil)
  assert_equal(selected.revision, nil)
end

test_captures_nested_repo_file_against_immutable_project_root_without_git()

local function test_captures_file_outside_startup_project_root()
  local temp = vim.fn.tempname()
  local project_root = temp .. "/project"
  vim.fn.mkdir(project_root, "p")
  temp = assert(vim.uv.fs_realpath(temp))
  project_root = temp .. "/project"
  local outside_file = temp .. "/shared/example.lua"

  local selected = capture_project_file(project_root, outside_file, { "local first = 1", "return first" })

  vim.fn.delete(temp, "rf")
  assert(selected, "expected outside project editor selection")
  assert_equal(selected.context_kind, "project")
  assert_equal(selected.repo_root, project_root)
  assert_equal(selected.project_relative_path, nil)
  assert_equal(selected.path, outside_file)
  assert_equal(selected.absolute_path, outside_file)
  assert_equal(selected.selection_kind, "file")
end

test_captures_file_outside_startup_project_root()

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
          { agent = "claude", agent_status = "idle", cwd = "/work/app", pane_id = "w1:p1", workspace_id = "w1" },
          {
            agent = "cursor",
            agent_status = "working",
            foreground_cwd = "/work/app/subdir",
            pane_id = "w1:p2",
            workspace_id = "w1",
          },
          { agent = "codex", agent_status = "idle", cwd = "/work/app", pane_id = "w2:p1", workspace_id = "w2" },
          { agent = "codex", agent_status = "idle", cwd = "/elsewhere", pane_id = "w1:p3", workspace_id = "w1" },
        },
      },
    },
  }, "/work/app", "w1")

  assert_equal(#agents, 2)
  assert_equal(agents[1].pane_id, "w1:p1")
  assert_equal(agents[2].pane_id, "w1:p2")
end

test_matches_agents_by_workspace_path()

local function test_uses_snapshot_command_without_json_flag()
  assert_equal(table.concat(discovery.snapshot_command(), " "), "herdr api snapshot")
end

test_uses_snapshot_command_without_json_flag()

local function test_excludes_herdr_agent_without_stable_identity()
  local mapped = targets.herdr({
    {
      agent = "cursor",
      agent_status = "idle",
      pane_id = "w1:p1",
      workspace_id = "w1",
    },
  })

  assert_equal(#mapped, 0)
end

test_excludes_herdr_agent_without_stable_identity()

local function herdr_process_info(pane_id, process_group_id, process_id)
  return {
    code = 0,
    stdout = vim.json.encode({
      id = "cli:pane:process_info",
      result = {
        process_info = {
          foreground_process_group_id = process_group_id,
          foreground_processes = {
            {
              argv = { "codex", "--dangerously-bypass-approvals-and-sandbox" },
              argv0 = "codex",
              cmdline = "codex --dangerously-bypass-approvals-and-sandbox",
              cwd = "/work/app",
              name = "codex",
              pid = process_id,
            },
          },
          pane_id = pane_id,
          shell_pid = 99,
        },
        type = "pane_process_info",
      },
    }),
    stderr = "",
  }
end

local function test_discovers_fresh_herdr_agent_by_foreground_process()
  local original_system = vim.system
  local original_discover = discovery.for_repo
  local original_workspace = vim.env.HERDR_WORKSPACE_ID
  vim.env.HERDR_WORKSPACE_ID = "w1"
  discovery.for_repo = function(repo_root, callback)
    assert_equal(repo_root, "/work/app")
    callback({
      {
        agent = "codex",
        agent_status = "idle",
        cwd = "/work/app",
        foreground_cwd = "/work/app",
        pane_id = "w1:p1",
        terminal_id = "term-1",
        workspace_id = "w1",
      },
    }, nil)
  end
  vim.system = function(command, options, callback)
    assert_equal(table.concat(command, " "), "herdr pane process-info --pane w1:p1")
    assert_equal(options.text, true)
    callback(herdr_process_info("w1:p1", 100, 101))
  end

  local discovered, discovery_error
  herdr_backend.discover("/work/app", function(found, err)
    discovered, discovery_error = found, err
  end)
  vim.wait(100, function()
    return discovered ~= nil or discovery_error ~= nil
  end)

  vim.system = original_system
  discovery.for_repo = original_discover
  vim.env.HERDR_WORKSPACE_ID = original_workspace
  assert_equal(discovery_error, nil)
  assert_equal(#discovered, 1)
  assert_equal(discovered[1].id, "w1:p1")
  assert(vim.startswith(discovered[1].identity, "process:"), "expected foreground process identity")
end

test_discovers_fresh_herdr_agent_by_foreground_process()

local function test_matches_herdr_app_agents_in_same_space_and_repository()
  local matched = app.targets({
    {
      address = "t1",
      agent = "cursor",
      created_ms = 10,
      foreground = { cwd = "/work/app", name = "cursor-agent", pid = 101 },
      labels = { ["herdr.space"] = "space-1" },
      state = "live",
      status = "idle",
    },
    {
      address = "t2",
      agent = "nvim",
      created_ms = 20,
      foreground = { cwd = "/work/app", name = "nvim", pid = 202 },
      labels = { ["herdr.space"] = "space-1" },
      state = "live",
    },
    {
      address = "t3",
      agent = "codex",
      foreground = { cwd = "/work/app/subdir", name = "codex", pid = 303 },
      labels = { ["herdr.space"] = "space-2" },
      state = "live",
      status = "working",
    },
    {
      address = "t4",
      agent = "claude",
      foreground = { cwd = "/work/other", name = "claude", pid = 404 },
      labels = { ["herdr.space"] = "space-1" },
      state = "live",
      status = "idle",
    },
  }, "t2", "space-1", "/work/app")

  assert_equal(#matched, 1)
  assert_equal(matched[1].backend, "herdr_app")
  assert_equal(matched[1].id, "t1")
  assert_equal(matched[1].agent, "cursor")
  assert_equal(matched[1].space_id, "space-1")
  assert_equal(matched[1].terminal_created_ms, 10)
  assert_equal(matched[1].foreground_pid, 101)
end

test_matches_herdr_app_agents_in_same_space_and_repository()

local function test_matches_unreported_cursor_in_herdr_app_space()
  local matched = app.targets({
    {
      address = "t1",
      agent = "bash",
      created_ms = 10,
      foreground = {
        argv = {
          "/Users/test/.local/bin/agent",
          "--disable-sigusr1",
          "/Users/test/.local/share/cursor-agent/versions/current/index.js",
        },
        cwd = "/work/app",
        name = "node",
        pid = 101,
      },
      labels = { ["herdr.space"] = "space-1" },
      reported = false,
      state = "live",
    },
  }, "t2", "space-1", "/work/app")

  assert_equal(#matched, 1)
  assert_equal(matched[1].agent, "Cursor Agent")
  assert_equal(matched[1].status, "paste + submit")
end

test_matches_unreported_cursor_in_herdr_app_space()

local function test_excludes_unreported_shell_with_json_null_status()
  local terminal = vim.json.decode(vim.json.encode({
    address = "t5",
    agent = "bash",
    foreground = { argv = { "/bin/bash", "-l" }, cwd = "/work/app", name = "bash", pid = 505 },
    labels = { ["herdr.space"] = "space-1" },
    state = "live",
    status = vim.NIL,
  }))

  assert_equal(#app.targets({ terminal }, "t2", "space-1", "/work/app"), 0)
end

test_excludes_unreported_shell_with_json_null_status()

local function test_discovers_herdr_app_agents_from_current_space()
  local original_system = vim.system
  local original_terminal = vim.env.HC_TERMINAL_ID
  local commands = {}
  vim.env.HC_TERMINAL_ID = "t2"
  vim.system = function(command, _, callback)
    commands[#commands + 1] = table.concat(command, " ")
    if command[2] == "get" and command[3] == "t2" then
      callback({
        code = 0,
        stdout = vim.json.encode({
          address = "t2",
          created_ms = 20,
          labels = { ["herdr.space"] = "space-1" },
          state = "live",
        }),
        stderr = "",
      })
    elseif command[2] == "ls" then
      callback({
        code = 0,
        stdout = vim.json.encode({
          terminals = {
            { address = "t1", agent = "bash" },
            { address = "t2", agent = "bash" },
          },
        }),
        stderr = "",
      })
    else
      callback({
        code = 0,
        stdout = vim.json.encode({
          address = "t1",
          created_ms = 10,
          foreground = {
            argv = {
              "/Users/test/.local/bin/agent",
              "/Users/test/.local/share/cursor-agent/versions/current/index.js",
            },
            cwd = "/work/app",
            name = "node",
            pid = 101,
          },
          labels = { ["herdr.space"] = "space-1" },
          reported = false,
          state = "live",
        }),
        stderr = "",
      })
    end
  end

  local discovered, discovery_error
  app.discover("/work/app", function(result, err)
    discovered, discovery_error = result, err
  end)
  vim.wait(100, function()
    return discovered ~= nil or discovery_error ~= nil
  end)

  vim.system = original_system
  vim.env.HC_TERMINAL_ID = original_terminal
  assert_equal(discovery_error, nil)
  assert_equal(#discovered, 1)
  assert_equal(discovered[1].id, "t1")
  assert_equal(discovered[1].agent, "Cursor Agent")
  assert_equal(discovered[1].status, "paste + submit")
  assert_equal(discovered[1].caller_id, "t2")
  assert_equal(discovered[1].caller_created_ms, 20)
  assert_equal(commands[1], "hc get t2 --json")
  assert_equal(commands[2], "hc ls --json --label herdr.space=space-1")
  assert_equal(commands[3], "hc get t1 --json")
end

test_discovers_herdr_app_agents_from_current_space()

local function test_labels_herdr_and_cmux_picker_targets()
  local herdr_targets = targets.herdr({
    { agent = "cursor", agent_status = "working", agent_id = "agent-1" },
  })
  local cmux_targets = cmux.targets({
    sessions = {
      {
        agent = "claude",
        agent_display_name = "Claude Code",
        agent_lifecycle = "idle",
        active_for_surface = true,
        session_id = "session-claude",
        surface_id = "surface-claude",
      },
    },
  }, "Review workspace")

  assert_equal(targets.label(herdr_targets[1]), "[Herdr] cursor [working] agent-1")
  assert_equal(
    targets.label({ backend = "herdr_app", agent = "Cursor", status = "idle", id = "t7" }),
    "[Herdr app] Cursor [idle] t7"
  )
  assert_equal(targets.label(cmux_targets[1]), "[cmux] Claude Code [idle] Review workspace")
  assert_equal(
    targets.label({
      backend = "cmux_terminal",
      agent = "Cursor Agent",
      workspace = "Review workspace",
    }),
    "[cmux terminal] Cursor Agent [paste + submit] Review workspace"
  )
end

test_labels_herdr_and_cmux_picker_targets()

local function test_uses_only_herdr_inside_herdr()
  local original_herdr = discovery.for_repo
  local original_cmux = cmux.discover
  local original_herdr_env = vim.env.HERDR_ENV
  local original_herdr_workspace = vim.env.HERDR_WORKSPACE_ID
  local original_cmux_surface = vim.env.CMUX_SURFACE_ID
  local herdr_called, cmux_called
  vim.env.HERDR_ENV = "1"
  vim.env.HERDR_WORKSPACE_ID = "w1"
  vim.env.CMUX_SURFACE_ID = "surface-cmux"
  discovery.for_repo = function(_, callback)
    herdr_called = true
    callback({ { agent = "cursor", agent_status = "working", agent_id = "agent-1" } }, nil)
  end
  cmux.discover = function(_, callback)
    cmux_called = true
    callback({
      {
        backend = "cmux",
        id = "surface-claude",
        agent = "Claude Code",
        status = "idle",
        workspace = "Review workspace",
      },
    }, nil)
  end

  local discovered, discovery_error
  targets.discover("/work/app", function(result, err)
    discovered, discovery_error = result, err
  end)

  discovery.for_repo = original_herdr
  cmux.discover = original_cmux
  vim.env.HERDR_ENV = original_herdr_env
  vim.env.HERDR_WORKSPACE_ID = original_herdr_workspace
  vim.env.CMUX_SURFACE_ID = original_cmux_surface
  assert_equal(discovery_error, nil)
  assert_equal(herdr_called, true)
  assert_equal(cmux_called, nil)
  assert_equal(#discovered, 1)
  assert_equal(discovered[1].backend, "herdr")
end

test_uses_only_herdr_inside_herdr()

local function test_uses_only_herdr_app_inside_herdr_app()
  local original_app = app.discover
  local original_cmux = cmux.discover
  local original_herdr_env = vim.env.HERDR_ENV
  local original_hc_terminal = vim.env.HC_TERMINAL_ID
  local original_cmux_surface = vim.env.CMUX_SURFACE_ID
  local app_called, cmux_called
  vim.env.HERDR_ENV = nil
  vim.env.HC_TERMINAL_ID = "t2"
  vim.env.CMUX_SURFACE_ID = "surface-cmux"
  app.discover = function(repo_root, callback)
    app_called = repo_root
    callback({
      {
        backend = "herdr_app",
        id = "t1",
        agent = "Cursor",
        status = "idle",
        space_id = "space-1",
      },
    }, nil)
  end
  cmux.discover = function()
    cmux_called = true
  end

  local discovered, discovery_error
  targets.discover("/work/app", function(result, err)
    discovered, discovery_error = result, err
  end)

  app.discover = original_app
  cmux.discover = original_cmux
  vim.env.HERDR_ENV = original_herdr_env
  vim.env.HC_TERMINAL_ID = original_hc_terminal
  vim.env.CMUX_SURFACE_ID = original_cmux_surface
  assert_equal(discovery_error, nil)
  assert_equal(app_called, "/work/app")
  assert_equal(cmux_called, nil)
  assert_equal(#discovered, 1)
  assert_equal(discovered[1].backend, "herdr_app")
end

test_uses_only_herdr_app_inside_herdr_app()

local function test_uses_only_cmux_inside_cmux()
  local original_herdr = discovery.for_repo
  local original_cmux = cmux.discover
  local original_herdr_env = vim.env.HERDR_ENV
  local original_hc_terminal = vim.env.HC_TERMINAL_ID
  local original_cmux_surface = vim.env.CMUX_SURFACE_ID
  local herdr_called, cmux_called
  vim.env.HERDR_ENV = nil
  vim.env.HC_TERMINAL_ID = nil
  vim.env.CMUX_SURFACE_ID = "surface-cmux"
  discovery.for_repo = function(_, callback)
    herdr_called = true
    callback({ { agent = "cursor", agent_status = "working", agent_id = "agent-1" } }, nil)
  end
  cmux.discover = function(_, callback)
    cmux_called = true
    callback({
      {
        backend = "cmux",
        id = "surface-claude",
        agent = "Claude Code",
        status = "idle",
        workspace = "Review workspace",
      },
    }, nil)
  end

  local discovered, discovery_error
  targets.discover("/work/app", function(result, err)
    discovered, discovery_error = result, err
  end)

  discovery.for_repo = original_herdr
  cmux.discover = original_cmux
  vim.env.HERDR_ENV = original_herdr_env
  vim.env.HC_TERMINAL_ID = original_hc_terminal
  vim.env.CMUX_SURFACE_ID = original_cmux_surface
  assert_equal(discovery_error, nil)
  assert_equal(herdr_called, nil)
  assert_equal(cmux_called, true)
  assert_equal(#discovered, 1)
  assert_equal(discovered[1].backend, "cmux")
end

test_uses_only_cmux_inside_cmux()

local function test_discovers_supported_active_cmux_sessions()
  local targets = cmux.targets({
    sessions = {
      {
        agent = "claude",
        agent_display_name = "Claude Code",
        agent_lifecycle = "idle",
        active_for_surface = true,
        cwd = "/work/app",
        session_id = "session-claude",
        surface_id = "surface-claude",
        workspace_id = "workspace-current",
      },
      {
        agent = "codex",
        agent_display_name = "Codex",
        agent_lifecycle = "idle",
        active_for_surface = true,
        cwd = "/work/other",
        session_id = "session-other-repo",
        surface_id = "surface-other-repo",
        workspace_id = "workspace-current",
      },
      {
        agent = "cursor",
        agent_display_name = "Cursor",
        agent_lifecycle = "running",
        active_for_surface = true,
        surface_id = "surface-cursor",
        workspace_id = "workspace-current",
      },
      {
        agent = "codex",
        agent_display_name = "Codex",
        agent_lifecycle = "running",
        active_for_surface = false,
        surface_id = "surface-stale",
        workspace_id = "workspace-current",
      },
    },
  }, "Current workspace", nil, "/work/app")

  assert_equal(#targets, 1)
  assert_equal(targets[1].backend, "cmux")
  assert_equal(targets[1].id, "surface-claude")
  assert_equal(targets[1].agent, "Claude Code")
  assert_equal(targets[1].status, "idle")
  assert_equal(targets[1].workspace, "Current workspace")
end

test_discovers_supported_active_cmux_sessions()

local function test_builds_cmux_discovery_from_caller_workspace()
  local context_info = cmux.workspace({
    caller = { workspace_id = "workspace-current", workspace_ref = "workspace:7" },
    windows = {
      {
        workspaces = {
          { id = "workspace-other", title = "Other workspace" },
          { id = "workspace-current", title = "Review workspace" },
        },
      },
    },
  })

  assert_equal(context_info.id, "workspace-current")
  assert_equal(context_info.ref, "workspace:7")
  assert_equal(context_info.title, "Review workspace")
  assert_equal(
    table.concat(cmux.sessions_command(context_info.id), " "),
    "cmux sessions list --workspace workspace-current --json"
  )
end

test_builds_cmux_discovery_from_caller_workspace()

local function test_finds_only_sibling_terminals_in_callers_cmux_workspace()
  local tree = {
    caller = {
      workspace_id = "workspace-current",
      workspace_ref = "workspace:7",
      surface_ref = "surface:caller",
    },
    windows = {
      {
        workspaces = {
          {
            id = "workspace-current",
            title = "Review workspace",
            panes = {
              { surfaces = { { ref = "surface:caller", type = "terminal", title = "Neovim" } } },
              { surfaces = { { ref = "surface:agent", type = "terminal", title = "Cursor Agent" } } },
              { surfaces = { { ref = "surface:other-repo", type = "terminal", title = "Other Repo Agent" } } },
              { surfaces = { { ref = "surface:shell", type = "terminal", title = "Shell" } } },
              { surfaces = { { ref = "surface:ambiguous", type = "terminal", title = "Ambiguous" } } },
              { surfaces = { { ref = "surface:browser", type = "browser", title = "Browser" } } },
            },
          },
          {
            id = "workspace-other",
            title = "Other workspace",
            panes = {
              { surfaces = { { ref = "surface:other", type = "terminal", title = "Other Agent" } } },
            },
          },
        },
      },
    },
  }
  local processes = {
    windows = {
      {
        workspaces = {
          {
            id = "workspace-current",
            panes = {
              {
                surfaces = {
                  {
                    ref = "surface:agent",
                    foreground_pgids = { 42 },
                    processes = {
                      {
                        name = "node",
                        path = "/Users/test/.local/share/cursor-agent/versions/current/node",
                        cwd = "/work/app",
                        pid = 42,
                        pgid = 42,
                        children = {},
                      },
                    },
                  },
                },
              },
              {
                surfaces = {
                  {
                    ref = "surface:other-repo",
                    foreground_pgids = { 43 },
                    processes = {
                      {
                        name = "codex",
                        path = "/usr/local/bin/codex",
                        cwd = "/work/other",
                        pid = 43,
                        pgid = 43,
                        children = {},
                      },
                    },
                  },
                },
              },
              {
                surfaces = {
                  {
                    ref = "surface:shell",
                    foreground_pgids = { 7 },
                    processes = {
                      {
                        name = "bash",
                        path = "/bin/bash",
                        pid = 7,
                        pgid = 7,
                        children = {
                          {
                            name = "node",
                            path = "/Users/test/.local/share/cursor-agent/versions/current/node",
                            pid = 99,
                            pgid = 99,
                            children = {},
                          },
                        },
                      },
                    },
                  },
                },
              },
              {
                surfaces = {
                  {
                    ref = "surface:ambiguous",
                    foreground_pgids = { 50 },
                    processes = {
                      {
                        name = "claude",
                        path = "/usr/local/bin/claude",
                        pid = 50,
                        pgid = 50,
                        children = {},
                      },
                      {
                        name = "codex",
                        path = "/usr/local/bin/codex",
                        pid = 51,
                        pgid = 50,
                        children = {},
                      },
                    },
                  },
                },
              },
            },
          },
        },
      },
    },
  }
  local workspace = cmux.workspace(tree)
  local terminal_targets = cmux.terminal_targets(tree, workspace, processes, "/work/app")

  assert_equal(#terminal_targets, 1)
  assert_equal(terminal_targets[1].backend, "cmux_terminal")
  assert_equal(terminal_targets[1].id, "surface:agent")
  assert_equal(terminal_targets[1].agent, "Cursor")
  assert_equal(terminal_targets[1].workspace, "Review workspace")
  assert_equal(terminal_targets[1].process_id, 42)
end

test_finds_only_sibling_terminals_in_callers_cmux_workspace()

local function test_discovers_cmux_targets_in_callers_workspace()
  local original_system = vim.system
  local original_surface = vim.env.CMUX_SURFACE_ID
  local calls = {}
  vim.env.CMUX_SURFACE_ID = "surface-caller"
  vim.system = function(command, _, callback)
    calls[#calls + 1] = table.concat(command, " ")
    if command[2] == "tree" then
      callback({
        code = 0,
        stdout = vim.json.encode({
          caller = { workspace_id = "workspace-current", workspace_ref = "workspace:7" },
          windows = { { workspaces = { { id = "workspace-current", title = "Review workspace" } } } },
        }),
        stderr = "",
      })
    else
      callback({
        code = 0,
        stdout = vim.json.encode({
          sessions = {
            {
              agent = "claude",
              agent_display_name = "Claude Code",
              agent_lifecycle = "idle",
              active_for_surface = true,
              cwd = "/work/app",
              session_id = "session-claude",
              surface_id = "surface-claude",
            },
          },
        }),
        stderr = "",
      })
    end
  end

  local discovered, discovery_error
  cmux.discover("/work/app", function(targets, err)
    discovered, discovery_error = targets, err
  end)
  vim.wait(100, function()
    return discovered ~= nil or discovery_error ~= nil
  end)

  vim.system = original_system
  vim.env.CMUX_SURFACE_ID = original_surface
  assert_equal(discovery_error, nil)
  assert_equal(#discovered, 1)
  assert_equal(discovered[1].id, "surface-claude")
  assert(vim.deep_equal(calls, {
    "cmux tree --all --json",
    "cmux sessions list --workspace workspace-current --json",
  }))
end

test_discovers_cmux_targets_in_callers_workspace()

local function test_falls_back_to_sibling_terminal_when_cmux_has_no_message_receiver()
  local original_system = vim.system
  local original_surface = vim.env.CMUX_SURFACE_ID
  vim.env.CMUX_SURFACE_ID = "surface-caller"
  vim.system = function(command, _, callback)
    if command[2] == "tree" then
      callback({
        code = 0,
        stdout = vim.json.encode({
          caller = {
            workspace_id = "workspace-current",
            workspace_ref = "workspace:7",
            surface_ref = "surface:caller",
          },
          windows = {
            {
              workspaces = {
                {
                  id = "workspace-current",
                  title = "Review workspace",
                  panes = {
                    { surfaces = { { ref = "surface:caller", type = "terminal", title = "Neovim" } } },
                    { surfaces = { { ref = "surface:cursor", type = "terminal", title = "Cursor Agent" } } },
                  },
                },
              },
            },
          },
        }),
        stderr = "",
      })
    elseif command[2] == "sessions" then
      callback({ code = 0, stdout = vim.json.encode({ sessions = {} }), stderr = "" })
    else
      assert_equal(table.concat(command, " "), "cmux top --workspace workspace-current --processes --json")
      callback({
        code = 0,
        stdout = vim.json.encode({
          windows = {
            {
              workspaces = {
                {
                  id = "workspace-current",
                  panes = {
                    {
                      surfaces = {
                        {
                          ref = "surface:cursor",
                          foreground_pgids = { 42 },
                          processes = {
                            {
                              name = "node",
                              path = "/Users/test/.local/share/cursor-agent/versions/current/node",
                              cwd = "/work/app",
                              pid = 42,
                              pgid = 42,
                              children = {},
                            },
                          },
                        },
                      },
                    },
                  },
                },
              },
            },
          },
        }),
        stderr = "",
      })
    end
  end

  local discovered, discovery_error
  cmux.discover("/work/app", function(found, err)
    discovered, discovery_error = found, err
  end)
  vim.wait(100, function()
    return discovered ~= nil or discovery_error ~= nil
  end)

  vim.system = original_system
  vim.env.CMUX_SURFACE_ID = original_surface
  assert_equal(discovery_error, nil)
  assert_equal(#discovered, 1)
  assert_equal(discovered[1].backend, "cmux_terminal")
  assert_equal(discovered[1].id, "surface:cursor")
end

test_falls_back_to_sibling_terminal_when_cmux_has_no_message_receiver()

local function test_rejects_cmux_target_that_moved_out_of_callers_workspace()
  local original_system = vim.system
  vim.system = function(command, _, callback)
    assert_equal(table.concat(command, " "), "cmux tree --all --json")
    callback({
      code = 0,
      stdout = vim.json.encode({
        caller = {
          workspace_id = "workspace-current",
          workspace_ref = "workspace:7",
          surface_ref = "surface:caller",
        },
        windows = {
          {
            workspaces = {
              {
                id = "workspace-current",
                title = "Review workspace",
                panes = {
                  { surfaces = { { ref = "surface:caller", type = "terminal", title = "Neovim" } } },
                },
              },
              {
                id = "workspace-other",
                title = "Other workspace",
                panes = {
                  { surfaces = { { ref = "surface:agent", type = "terminal", title = "Moved Agent" } } },
                },
              },
            },
          },
        },
      }),
      stderr = "",
    })
  end

  local current_target, revalidation_error
  cmux.revalidate("/work/app", {
    backend = "cmux_terminal",
    id = "surface:agent",
    workspace_id = "workspace-current",
  }, function(target, err)
    current_target, revalidation_error = target, err
  end)
  vim.wait(100, function()
    return current_target ~= nil or revalidation_error ~= nil
  end)

  vim.system = original_system
  assert_equal(current_target, nil)
  assert_equal(revalidation_error, "cmux target is no longer in Neovim's workspace")
end

test_rejects_cmux_target_that_moved_out_of_callers_workspace()

local function test_rejects_replaced_agent_on_same_cmux_surface()
  local original_system = vim.system
  vim.system = function(command, _, callback)
    if command[2] == "tree" then
      callback({
        code = 0,
        stdout = vim.json.encode({
          caller = {
            workspace_id = "workspace-current",
            workspace_ref = "workspace:7",
            surface_ref = "surface:caller",
          },
          windows = {
            {
              workspaces = {
                {
                  id = "workspace-current",
                  title = "Review workspace",
                  panes = {
                    { surfaces = { { ref = "surface:caller", type = "terminal", title = "Neovim" } } },
                    { surfaces = { { ref = "surface:agent", type = "terminal", title = "Cursor Agent" } } },
                  },
                },
              },
            },
          },
        }),
        stderr = "",
      })
    else
      callback({
        code = 0,
        stdout = vim.json.encode({
          windows = {
            {
              workspaces = {
                {
                  id = "workspace-current",
                  panes = {
                    {
                      surfaces = {
                        {
                          ref = "surface:agent",
                          foreground_pgids = { 43 },
                          processes = {
                            {
                              name = "node",
                              path = "/Users/test/.local/share/cursor-agent/versions/current/node",
                              cwd = "/work/app",
                              pid = 43,
                              pgid = 43,
                              children = {},
                            },
                          },
                        },
                      },
                    },
                  },
                },
              },
            },
          },
        }),
        stderr = "",
      })
    end
  end

  local current_target, revalidation_error
  cmux.revalidate("/work/app", {
    backend = "cmux_terminal",
    id = "surface:agent",
    agent = "Cursor",
    workspace_id = "workspace-current",
    process_id = 42,
    process_pgid = 42,
    process_path = "/Users/test/.local/share/cursor-agent/versions/current/node",
  }, function(target, err)
    current_target, revalidation_error = target, err
  end)
  vim.wait(100, function()
    return current_target ~= nil or revalidation_error ~= nil
  end)

  vim.system = original_system
  assert_equal(current_target, nil)
  assert_equal(revalidation_error, "cmux target agent changed before delivery")
end

test_rejects_replaced_agent_on_same_cmux_surface()

local function test_rejects_cmux_agent_that_left_repository()
  local original_system = vim.system
  vim.system = function(command, _, callback)
    if command[2] == "tree" then
      callback({
        code = 0,
        stdout = vim.json.encode({
          caller = {
            workspace_id = "workspace-current",
            workspace_ref = "workspace:7",
            surface_ref = "surface:caller",
          },
          windows = {
            {
              workspaces = {
                { id = "workspace-current", title = "Review workspace" },
              },
            },
          },
        }),
        stderr = "",
      })
    else
      callback({
        code = 0,
        stdout = vim.json.encode({
          sessions = {
            {
              agent = "claude",
              agent_display_name = "Claude Code",
              agent_lifecycle = "idle",
              active_for_surface = true,
              cwd = "/work/other",
              session_id = "session-claude",
              surface_id = "surface-claude",
              workspace_id = "workspace-current",
            },
          },
        }),
        stderr = "",
      })
    end
  end

  local current_target, revalidation_error
  cmux.revalidate("/work/app", {
    backend = "cmux",
    id = "surface-claude",
    session_id = "session-claude",
    workspace_id = "workspace-current",
  }, function(target, err)
    current_target, revalidation_error = target, err
  end)
  vim.wait(100, function()
    return current_target ~= nil or revalidation_error ~= nil
  end)

  vim.system = original_system
  assert_equal(current_target, nil)
  assert_equal(revalidation_error, "cmux target is no longer active in this repository and workspace")
end

test_rejects_cmux_agent_that_left_repository()

local function test_rejects_herdr_target_that_left_repo_or_workspace()
  local original_discover = discovery.for_repo
  local original_herdr_env = vim.env.HERDR_ENV
  local original_herdr_workspace = vim.env.HERDR_WORKSPACE_ID
  vim.env.HERDR_ENV = "1"
  vim.env.HERDR_WORKSPACE_ID = "w1"
  discovery.for_repo = function(repo_root, callback)
    assert_equal(repo_root, "/work/app")
    callback({
      { agent = "cursor", agent_status = "idle", agent_id = "different-agent", workspace_id = "w1" },
    }, nil)
  end

  local current_target, revalidation_error
  targets.revalidate("/work/app", {
    backend = "herdr",
    id = "original-agent",
    workspace_id = "w1",
  }, function(target, err)
    current_target, revalidation_error = target, err
  end)

  discovery.for_repo = original_discover
  vim.env.HERDR_ENV = original_herdr_env
  vim.env.HERDR_WORKSPACE_ID = original_herdr_workspace
  assert_equal(current_target, nil)
  assert_equal(revalidation_error, "Herdr target is no longer in this repository and workspace")
end

test_rejects_herdr_target_that_left_repo_or_workspace()

local function test_rejects_replaced_fresh_herdr_agent_process()
  local original_system = vim.system
  local original_discover = discovery.for_repo
  local original_workspace = vim.env.HERDR_WORKSPACE_ID
  vim.env.HERDR_WORKSPACE_ID = "w1"
  discovery.for_repo = function(repo_root, callback)
    assert_equal(repo_root, "/work/app")
    callback({
      {
        agent = "codex",
        agent_status = "idle",
        cwd = "/work/app",
        foreground_cwd = "/work/app",
        pane_id = "w1:p1",
        terminal_id = "term-1",
        workspace_id = "w1",
      },
    }, nil)
  end
  local process_query_count = 0
  vim.system = function(_, _, callback)
    process_query_count = process_query_count + 1
    callback(
      herdr_process_info("w1:p1", process_query_count == 1 and 100 or 200, process_query_count == 1 and 101 or 201)
    )
  end

  local discovered
  herdr_backend.discover("/work/app", function(found)
    discovered = found
  end)
  vim.wait(100, function()
    return discovered ~= nil
  end)
  local current_target, revalidation_error
  herdr_backend.revalidate("/work/app", discovered[1], function(target, err)
    current_target, revalidation_error = target, err
  end)
  vim.wait(100, function()
    return current_target ~= nil or revalidation_error ~= nil
  end)

  vim.system = original_system
  discovery.for_repo = original_discover
  vim.env.HERDR_WORKSPACE_ID = original_workspace
  assert_equal(current_target, nil)
  assert_equal(revalidation_error, "Herdr target agent changed before delivery")
end

test_rejects_replaced_fresh_herdr_agent_process()

local function test_rejects_replaced_agent_in_same_herdr_app_terminal()
  local original_discover = app.discover
  local original_terminal = vim.env.HC_TERMINAL_ID
  vim.env.HC_TERMINAL_ID = "t2"
  app.discover = function(repo_root, callback)
    assert_equal(repo_root, "/work/app")
    callback({
      {
        backend = "herdr_app",
        id = "t1",
        agent = "cursor",
        space_id = "space-1",
        terminal_created_ms = 10,
        foreground_pid = 999,
        caller_id = "t2",
        caller_created_ms = 20,
      },
    }, nil)
  end

  local current_target, revalidation_error
  app.revalidate("/work/app", {
    backend = "herdr_app",
    id = "t1",
    agent = "cursor",
    space_id = "space-1",
    terminal_created_ms = 10,
    foreground_pid = 101,
    caller_id = "t2",
    caller_created_ms = 20,
  }, function(target, err)
    current_target, revalidation_error = target, err
  end)

  app.discover = original_discover
  vim.env.HC_TERMINAL_ID = original_terminal
  assert_equal(current_target, nil)
  assert_equal(revalidation_error, "Herdr app target agent changed before delivery")
end

test_rejects_replaced_agent_in_same_herdr_app_terminal()

local function test_revalidates_herdr_app_target_with_app_backend()
  local original_revalidate = app.revalidate
  local original_herdr_env = vim.env.HERDR_ENV
  local original_terminal = vim.env.HC_TERMINAL_ID
  local called
  vim.env.HERDR_ENV = nil
  vim.env.HC_TERMINAL_ID = "t2"
  app.revalidate = function(repo_root, target, callback)
    called = { repo_root = repo_root, target = target }
    callback(target, nil)
  end

  local current_target, revalidation_error
  targets.revalidate("/work/app", {
    backend = "herdr_app",
    id = "t1",
    caller_id = "t2",
  }, function(target, err)
    current_target, revalidation_error = target, err
  end)

  app.revalidate = original_revalidate
  vim.env.HERDR_ENV = original_herdr_env
  vim.env.HC_TERMINAL_ID = original_terminal
  assert_equal(revalidation_error, nil)
  assert_equal(called.repo_root, "/work/app")
  assert_equal(called.target.id, "t1")
  assert_equal(current_target.id, "t1")
end

test_revalidates_herdr_app_target_with_app_backend()

local function test_rejects_cmux_target_after_moving_to_herdr_app()
  local original_revalidate = cmux.revalidate
  local original_herdr_env = vim.env.HERDR_ENV
  local original_terminal = vim.env.HC_TERMINAL_ID
  local original_cmux_surface = vim.env.CMUX_SURFACE_ID
  local cmux_called
  vim.env.HERDR_ENV = nil
  vim.env.HC_TERMINAL_ID = "t2"
  vim.env.CMUX_SURFACE_ID = "surface-cmux"
  cmux.revalidate = function()
    cmux_called = true
  end

  local revalidation_error
  targets.revalidate("/work/app", {
    backend = "cmux",
    id = "surface-agent",
  }, function(_, err)
    revalidation_error = err
  end)

  cmux.revalidate = original_revalidate
  vim.env.HERDR_ENV = original_herdr_env
  vim.env.HC_TERMINAL_ID = original_terminal
  vim.env.CMUX_SURFACE_ID = original_cmux_surface
  assert_equal(cmux_called, nil)
  assert_equal(revalidation_error, "Neovim is no longer running exclusively inside cmux")
end

test_rejects_cmux_target_after_moving_to_herdr_app()

local function test_revalidation_fails_when_host_identity_changes()
  local original_herdr_env = vim.env.HERDR_ENV
  local original_herdr_workspace = vim.env.HERDR_WORKSPACE_ID
  local original_cmux_surface = vim.env.CMUX_SURFACE_ID
  local original_herdr_discover = discovery.for_repo
  local original_cmux_revalidate = cmux.revalidate
  local herdr_discovered, cmux_revalidated
  discovery.for_repo = function()
    herdr_discovered = true
  end
  cmux.revalidate = function()
    cmux_revalidated = true
  end

  vim.env.HERDR_ENV = nil
  vim.env.HERDR_WORKSPACE_ID = nil
  vim.env.CMUX_SURFACE_ID = "surface-cmux"
  local _, herdr_error
  targets.revalidate("/work/app", {
    backend = "herdr",
    id = "agent-1",
    workspace_id = "w1",
  }, function(_, err)
    herdr_error = err
  end)

  vim.env.HERDR_ENV = "1"
  vim.env.HERDR_WORKSPACE_ID = "w1"
  local _, cmux_error
  targets.revalidate("/work/app", {
    backend = "cmux_terminal",
    id = "surface:agent",
    workspace_id = "workspace-current",
  }, function(_, err)
    cmux_error = err
  end)

  discovery.for_repo = original_herdr_discover
  cmux.revalidate = original_cmux_revalidate
  vim.env.HERDR_ENV = original_herdr_env
  vim.env.HERDR_WORKSPACE_ID = original_herdr_workspace
  vim.env.CMUX_SURFACE_ID = original_cmux_surface
  assert_equal(herdr_discovered, nil)
  assert_equal(cmux_revalidated, nil)
  assert_equal(herdr_error, "Neovim is no longer running inside Herdr")
  assert_equal(cmux_error, "Neovim is no longer running exclusively inside cmux")
end

test_revalidation_fails_when_host_identity_changes()

local function test_cmux_revalidation_itself_fails_after_host_change()
  local original_herdr_env = vim.env.HERDR_ENV
  local original_cmux_surface = vim.env.CMUX_SURFACE_ID
  local original_system = vim.system
  local system_called
  vim.env.HERDR_ENV = "1"
  vim.env.CMUX_SURFACE_ID = "surface-cmux"
  vim.system = function()
    system_called = true
  end

  local current_target, revalidation_error
  cmux.revalidate("/work/app", {
    backend = "cmux_terminal",
    id = "surface:agent",
    workspace_id = "workspace-current",
  }, function(target, err)
    current_target, revalidation_error = target, err
  end)

  vim.system = original_system
  vim.env.HERDR_ENV = original_herdr_env
  vim.env.CMUX_SURFACE_ID = original_cmux_surface
  assert_equal(system_called, nil)
  assert_equal(current_target, nil)
  assert_equal(revalidation_error, "Neovim is no longer running exclusively inside cmux")
end

test_cmux_revalidation_itself_fails_after_host_change()

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

local function test_builds_ai_friendly_project_editor_prompt()
  local prompt = client.review_prompt({
    context_kind = "project",
    selection_kind = "selection",
    repo_root = "/work/project",
    project_root = "/work/project",
    path = "apps/video/src/example.lua",
    project_relative_path = "apps/video/src/example.lua",
    absolute_path = "/work/project/apps/video/src/example.lua",
    filetype = "lua",
    start_line = 12,
    end_line = 14,
    text = "local fence = ```\nreturn fence",
  }, "Explain whether this fence is safe.")

  assert_equal(
    prompt,
    table.concat({
      "Code context from Neovim",
      "File: apps/video/src/example.lua:12-14",
      "",
      "Selected code:",
      "````lua",
      "local fence = ```",
      "return fence",
      "````",
      "",
      "Comment:",
      "Explain whether this fence is safe.",
    }, "\n")
  )
  assert(not prompt:find("Branch:", 1, true))
  assert(not prompt:find("Revision:", 1, true))
  assert(not prompt:find("Repository location:", 1, true))
  assert(not prompt:find("Project root:", 1, true))
  assert(not prompt:find("Absolute file:", 1, true))
  assert(not prompt:find("Filetype:", 1, true))
end

test_builds_ai_friendly_project_editor_prompt()

local function test_marks_project_editor_file_outside_project_root()
  local prompt = client.review_prompt({
    context_kind = "project",
    selection_kind = "selection",
    repo_root = "/work/project",
    project_root = "/work/project",
    path = "/shared/example.txt",
    project_relative_path = nil,
    absolute_path = "/shared/example.txt",
    filetype = nil,
    start_line = 3,
    end_line = 3,
    text = "outside",
  }, "Review this external file.")

  assert(prompt:find("File: /shared/example.txt:3", 1, true))
  assert(not prompt:find("Project root:", 1, true))
  assert(not prompt:find("outside project root", 1, true))
end

test_marks_project_editor_file_outside_project_root()

local function test_builds_file_only_project_editor_prompt_without_code()
  local prompt = client.review_prompt({
    context_kind = "project",
    selection_kind = "file",
    repo_root = "/work/project",
    project_root = "/work/project",
    path = "apps/video/src/example.lua",
    project_relative_path = "apps/video/src/example.lua",
    absolute_path = "/work/project/apps/video/src/example.lua",
    filetype = "lua",
  }, "Review this file.")

  assert_equal(
    prompt,
    table.concat({
      "Code context from Neovim",
      "File: apps/video/src/example.lua",
      "",
      "Comment:",
      "Review this file.",
    }, "\n")
  )
  assert(not prompt:find("Selected code:", 1, true))
end

test_builds_file_only_project_editor_prompt_without_code()

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
  assert(not prompt:find("Context: project editor", 1, true))
  assert(not prompt:find("Project root:", 1, true))
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

local function test_sends_herdr_app_queue_to_exact_core_terminal()
  local original_system = vim.system
  local command_seen, options_seen
  vim.system = function(command, options, callback)
    command_seen, options_seen = command, options
    callback({ code = 0, stdout = vim.json.encode({ status = "sent" }), stderr = "" })
  end

  local ok_result, error_result
  app.send_queue({ id = "t7" }, {
    {
      selection = {
        path = "lua/example.lua",
        start_line = 12,
        end_line = 12,
        text = "run()",
        branch = "main",
        revision = "abc123",
      },
      comment = "Please review this.",
    },
  }, function(ok, err)
    ok_result, error_result = ok, err
  end)
  vim.wait(100, function()
    return ok_result ~= nil
  end)

  vim.system = original_system
  assert_equal(ok_result, true)
  assert_equal(error_result, nil)
  assert_equal(command_seen[1], "hc")
  assert_equal(command_seen[2], "send")
  assert_equal(command_seen[3], "--json")
  assert_equal(command_seen[4], "t7")
  assert(command_seen[5]:find("Please review this.", 1, true))
  assert_equal(options_seen.text, true)
end

test_sends_herdr_app_queue_to_exact_core_terminal()

local function test_sends_cmux_queue_to_exact_agent_surface()
  local original_system = vim.system
  local command_seen, options_seen
  vim.system = function(command, options, callback)
    command_seen, options_seen = command, options
    callback({ code = 0, stdout = vim.json.encode({ recipient_has_agent = true }), stderr = "" })
  end

  local ok_result, error_result
  cmux.send_queue({ id = "surface-claude" }, {
    {
      selection = {
        path = "lua/example.lua",
        start_line = 12,
        end_line = 12,
        text = "run()",
        branch = "main",
        revision = "abc123",
      },
      comment = "Please review this.",
    },
  }, function(ok, err)
    ok_result, error_result = ok, err
  end)
  vim.wait(100, function()
    return ok_result ~= nil
  end)

  vim.system = original_system
  assert_equal(ok_result, true)
  assert_equal(error_result, nil)
  assert_equal(table.concat(command_seen, " "), "cmux agent message surface-claude --from Neovim --json -")
  assert(options_seen.stdin:find("Please review this.", 1, true))
end

test_sends_cmux_queue_to_exact_agent_surface()

local function test_submits_queue_to_sibling_terminal()
  local original_system = vim.system
  local command_seen, options_seen
  vim.system = function(command, options, callback)
    command_seen, options_seen = command, options
    callback({ code = 0, stdout = "OK", stderr = "" })
  end

  local ok_result, error_result
  cmux.send_queue({ backend = "cmux_terminal", id = "surface:cursor", workspace_id = "workspace-current" }, {
    {
      selection = {
        path = "lua/example.lua",
        start_line = 12,
        end_line = 12,
        text = "run()",
        branch = "main",
        revision = "abc123",
      },
      comment = "Please review this.",
    },
  }, function(ok, err)
    ok_result, error_result = ok, err
  end)
  vim.wait(100, function()
    return ok_result ~= nil
  end)

  vim.system = original_system
  assert_equal(ok_result, true)
  assert_equal(error_result, nil)
  assert_equal(
    table.concat(command_seen, " "),
    "cmux paste --workspace workspace-current --surface surface:cursor --submit -"
  )
  assert(vim.tbl_contains(command_seen, "--submit"))
  assert(options_seen.stdin:find("Please review this.", 1, true))
end

test_submits_queue_to_sibling_terminal()

local function test_chunks_large_cmux_terminal_prompt_before_submitting()
  local original_system = vim.system
  local original_revalidate = cmux.revalidate
  local calls = {}
  vim.system = function(command, options, callback)
    calls[#calls + 1] = { command = command, stdin = options.stdin }
    callback({ code = 0, stdout = "OK", stderr = "" })
  end
  cmux.revalidate = function(_, target, callback)
    callback(target, nil)
  end

  local items = {
    {
      selection = {
        path = "lua/example.lua",
        start_line = 12,
        end_line = 12,
        text = "run()",
        branch = "main",
        revision = "abc123",
      },
      comment = string.rep('review "界" \\\\ this line\n', 300),
    },
  }
  local expected_prompt = client.queue_prompt(items)
  local ok_result, error_result
  cmux.send_queue(
    {
      backend = "cmux_terminal",
      id = "surface:cursor",
      agent = "Cursor",
      workspace_id = "workspace-current",
      process_id = 42,
      process_pgid = 42,
      process_path = "/Users/test/.local/share/cursor-agent/versions/current/node",
    },
    items,
    function(ok, err)
      ok_result, error_result = ok, err
    end
  )
  vim.wait(1000, function()
    return ok_result ~= nil
  end)

  vim.system = original_system
  cmux.revalidate = original_revalidate
  assert_equal(ok_result, true)
  assert_equal(error_result, nil)
  assert(#calls > 1, "expected a large prompt to use multiple cmux requests")
  local chunks = {}
  for index, call in ipairs(calls) do
    chunks[#chunks + 1] = call.stdin
    assert(#call.stdin <= 1400, "cmux paste chunk exceeded safe request size")
    assert(pcall(vim.str_utfindex, call.stdin), "cmux paste chunk split a UTF-8 character")
    assert_equal(vim.tbl_contains(call.command, "--force"), index > 1)
    assert_equal(vim.tbl_contains(call.command, "--submit"), index == #calls)
  end
  assert_equal(table.concat(chunks), expected_prompt)
end

test_chunks_large_cmux_terminal_prompt_before_submitting()

local function test_stops_chunked_paste_when_agent_changes_mid_transfer()
  local original_system = vim.system
  local original_revalidate = cmux.revalidate
  local paste_count, revalidate_count = 0, 0
  vim.system = function(command, _, callback)
    assert_equal(command[2], "paste")
    paste_count = paste_count + 1
    callback({ code = 0, stdout = "OK", stderr = "" })
  end
  cmux.revalidate = function(_, _, callback)
    revalidate_count = revalidate_count + 1
    callback(nil, "cmux target agent changed before delivery")
  end

  local ok_result, error_result
  cmux.send_queue({
    backend = "cmux_terminal",
    id = "surface:cursor",
    agent = "Cursor",
    workspace_id = "workspace-current",
    process_id = 42,
    process_pgid = 42,
    process_path = "/Users/test/.local/share/cursor-agent/versions/current/node",
  }, {
    {
      selection = { path = "lua/example.lua", start_line = 1, text = "run()" },
      comment = string.rep("large review comment\n", 300),
    },
  }, function(ok, err)
    ok_result, error_result = ok, err
  end)
  vim.wait(1000, function()
    return ok_result ~= nil
  end)

  vim.system = original_system
  cmux.revalidate = original_revalidate
  assert_equal(ok_result, false)
  assert_equal(error_result, "cmux target agent changed before delivery")
  assert_equal(paste_count, 1)
  assert_equal(revalidate_count, 1)
end

test_stops_chunked_paste_when_agent_changes_mid_transfer()

local function test_falls_back_to_chunked_paste_for_large_cmux_agent_message()
  local original_system = vim.system
  local original_revalidate = cmux.revalidate
  local calls = {}
  vim.system = function(command, options, callback)
    calls[#calls + 1] = { command = command, stdin = options.stdin }
    callback({ code = 0, stdout = "OK", stderr = "" })
  end
  cmux.revalidate = function(_, target, callback)
    callback(target, nil)
  end

  local items = {
    {
      selection = {
        path = "lua/example.lua",
        start_line = 1,
        text = "run()",
        branch = "main",
        revision = "abc123",
      },
      comment = string.rep("large review comment\n", 300),
    },
  }
  local ok_result, error_result
  cmux.send_queue(
    {
      backend = "cmux",
      id = "surface-agent-uuid",
      workspace_id = "workspace-current",
      session_id = "session-agent",
    },
    items,
    function(ok, err)
      ok_result, error_result = ok, err
    end
  )
  vim.wait(1000, function()
    return ok_result ~= nil
  end)

  vim.system = original_system
  cmux.revalidate = original_revalidate
  assert_equal(ok_result, true)
  assert_equal(error_result, nil)
  assert(#calls > 1, "expected large agent message to use chunked paste")
  for index, call in ipairs(calls) do
    assert_equal(call.command[2], "paste")
    assert_equal(vim.tbl_contains(call.command, "--force"), index > 1)
    assert_equal(vim.tbl_contains(call.command, "--submit"), index == #calls)
  end
end

test_falls_back_to_chunked_paste_for_large_cmux_agent_message()

local function test_rejects_cmux_surface_without_live_agent()
  local original_system = vim.system
  vim.system = function(_, _, callback)
    callback({ code = 0, stdout = vim.json.encode({ recipient_has_agent = false }), stderr = "" })
  end

  local ok_result, error_result
  cmux.send_queue({ id = "surface-shell" }, {
    {
      selection = { path = "lua/example.lua", start_line = 1, text = "run()" },
      comment = "Review this.",
    },
  }, function(ok, err)
    ok_result, error_result = ok, err
  end)
  vim.wait(100, function()
    return ok_result ~= nil
  end)

  vim.system = original_system
  assert_equal(ok_result, false)
  assert_equal(error_result, "cmux target no longer has a live agent; queued comments were kept")
end

test_rejects_cmux_surface_without_live_agent()

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

local function test_project_queue_spans_nested_repos_but_stays_separate_from_diffview_queue()
  local project_root = "/work/project"
  local diffview_root = "/work/project/apps/video"
  queue.clear(project_root)
  queue.clear(diffview_root)
  queue.add(
    context.project_selection({
      path = "/work/project/apps/video/src/video.lua",
      start_line = 1,
      text = "video()",
    }, project_root, "lua"),
    "Review video."
  )
  queue.add(
    context.project_selection({
      path = "/work/project/apps/live/src/live.lua",
      start_line = 2,
      text = "live()",
    }, project_root, "lua"),
    "Review live."
  )
  queue.add({
    repo_root = diffview_root,
    path = "src/video.lua",
    start_line = 1,
    text = "changed_video()",
    branch = "feature/video",
    revision = HEAD_SHA,
    change = { note = "No changed hunk overlaps the selected current lines." },
  }, "Review the diff.")

  assert_equal(queue.count(project_root), 2)
  assert_equal(queue.items(project_root)[1].selection.path, "apps/video/src/video.lua")
  assert_equal(queue.items(project_root)[2].selection.path, "apps/live/src/live.lua")
  assert_equal(queue.count(diffview_root), 1)
  assert_equal(queue.items(diffview_root)[1].selection.context_kind, nil)

  queue.clear(project_root)
  queue.clear(diffview_root)
end

test_project_queue_spans_nested_repos_but_stays_separate_from_diffview_queue()

local function test_clears_queue_only_after_successful_delivery()
  local root_path = "/work/submit"
  queue.clear(root_path)
  queue.add({
    repo_root = root_path,
    path = "lua/example.lua",
    start_line = 1,
    text = "run()",
  }, "Review this.")

  local failure
  submit.send(root_path, { backend = "cmux", id = "surface-agent" }, function(ok, err)
    failure = { ok = ok, err = err }
  end, {
    send_queue = function(_, _, callback)
      callback(false, "delivery failed")
    end,
  })
  assert_equal(failure.ok, false)
  assert_equal(queue.count(root_path), 1)

  local success
  submit.send(root_path, { backend = "cmux", id = "surface-agent" }, function(ok, err)
    success = { ok = ok, err = err }
  end, {
    send_queue = function(_, _, callback)
      callback(true, nil)
    end,
  })
  assert_equal(success.ok, true)
  assert_equal(queue.count(root_path), 0)
end

test_clears_queue_only_after_successful_delivery()

local function test_success_removes_only_submitted_queue_snapshot()
  local root_path = "/work/queue-snapshot"
  local finish
  queue.clear(root_path)
  queue.add({
    repo_root = root_path,
    path = "lua/first.lua",
    start_line = 1,
    text = "first()",
  }, "First review.")

  submit.send(root_path, { backend = "cmux_terminal", id = "surface:cursor" }, function() end, {
    send_queue = function(_, _, callback)
      finish = callback
    end,
  })
  queue.add({
    repo_root = root_path,
    path = "lua/second.lua",
    start_line = 2,
    text = "second()",
  }, "Second review.")
  finish(true, nil)

  assert_equal(queue.count(root_path), 1)
  assert_equal(queue.items(root_path)[1].comment, "Second review.")
end

test_success_removes_only_submitted_queue_snapshot()

local function test_serializes_submissions_per_repository()
  local root_path = "/work/serialized-submit"
  local finish
  local send_count = 0
  local transport = {
    send_queue = function(_, _, callback)
      send_count = send_count + 1
      finish = callback
    end,
  }
  queue.clear(root_path)
  queue.add({
    repo_root = root_path,
    path = "lua/example.lua",
    start_line = 1,
    text = "run()",
  }, "Review this.")

  submit.send(root_path, { backend = "cmux_terminal", id = "surface:cursor" }, function() end, transport)
  local second_result
  submit.send(root_path, { backend = "cmux_terminal", id = "surface:cursor" }, function(ok, err)
    second_result = { ok = ok, err = err }
  end, transport)

  assert_equal(send_count, 1)
  assert_equal(second_result.ok, false)
  assert_equal(second_result.err, "review comments are already being submitted for this repository")
  finish(false, "test cleanup")
end

test_serializes_submissions_per_repository()

local function test_dispatches_herdr_app_target_to_core_transport()
  local root_path = "/work/herdr-app"
  local original_send = app.send_queue
  local original_revalidate = targets.revalidate
  local dispatched
  queue.clear(root_path)
  queue.add({
    repo_root = root_path,
    path = "lua/example.lua",
    start_line = 1,
    text = "run()",
  }, "Review this.")
  app.send_queue = function(target, _, callback)
    dispatched = target
    callback(true, nil)
  end
  targets.revalidate = function(_, target, callback)
    callback(target, nil)
  end

  local result
  submit.send(root_path, { backend = "herdr_app", id = "t7" }, function(ok, err)
    result = { ok = ok, err = err }
  end)

  app.send_queue = original_send
  targets.revalidate = original_revalidate
  assert_equal(result.ok, true)
  assert_equal(result.err, nil)
  assert_equal(dispatched.id, "t7")
  assert_equal(queue.count(root_path), 0)
end

test_dispatches_herdr_app_target_to_core_transport()

local function test_dispatches_cmux_terminal_target_to_cmux_transport()
  local root_path = "/work/cmux-terminal"
  local original_send = cmux.send_queue
  local original_revalidate = targets.revalidate
  local dispatched
  queue.clear(root_path)
  queue.add({
    repo_root = root_path,
    path = "lua/example.lua",
    start_line = 1,
    text = "run()",
  }, "Review this.")
  cmux.send_queue = function(target, _, callback)
    dispatched = target
    callback(true, nil)
  end
  targets.revalidate = function(_, target, callback)
    callback(target, nil)
  end

  local result
  submit.send(root_path, { backend = "cmux_terminal", id = "surface:cursor" }, function(ok, err)
    result = { ok = ok, err = err }
  end)

  cmux.send_queue = original_send
  targets.revalidate = original_revalidate
  assert_equal(result.ok, true)
  assert_equal(result.err, nil)
  assert_equal(dispatched.id, "surface:cursor")
  assert_equal(queue.count(root_path), 0)
end

test_dispatches_cmux_terminal_target_to_cmux_transport()

local function test_picks_between_multiple_targets_before_submitting()
  local root_path = "/work/picker"
  local original_capture = reviewbuddy.capture
  local original_targets_discover = targets.discover
  local original_herdr_discover = discovery.for_repo
  local original_select = vim.ui.select
  local original_send = submit.send
  local picker_opened, selected_target

  queue.clear(root_path)
  queue.add({
    repo_root = root_path,
    path = "lua/example.lua",
    start_line = 1,
    text = "run()",
  }, "Review this.")
  reviewbuddy.capture = function()
    return { repo_root = root_path }
  end
  targets.discover = function(_, callback)
    callback({
      {
        backend = "cmux",
        id = "surface-claude",
        agent = "Claude Code",
        status = "idle",
        workspace = "Review workspace",
      },
      {
        backend = "cmux_terminal",
        id = "surface-cursor",
        agent = "Cursor Agent",
        status = "paste + submit",
        workspace = "Review workspace",
      },
    }, nil)
  end
  discovery.for_repo = function(_, callback)
    callback({}, nil)
  end
  vim.ui.select = function(items, options, callback)
    picker_opened = options.format_item(items[1])
    callback(items[2], 2)
  end
  submit.send = function(_, target, callback)
    selected_target = target
    callback(true, nil)
  end

  reviewbuddy.submit_queue()

  reviewbuddy.capture = original_capture
  targets.discover = original_targets_discover
  discovery.for_repo = original_herdr_discover
  vim.ui.select = original_select
  submit.send = original_send
  assert_equal(picker_opened, "[cmux] Claude Code [idle] Review workspace")
  assert_equal(selected_target.id, "surface-cursor")
end

test_picks_between_multiple_targets_before_submitting()

local function test_skips_picker_for_single_target()
  local root_path = "/work/single-target"
  local original_capture = reviewbuddy.capture
  local original_targets_discover = targets.discover
  local original_select = vim.ui.select
  local original_send = submit.send
  local picker_opened, selected_target

  queue.clear(root_path)
  queue.add({
    repo_root = root_path,
    path = "lua/example.lua",
    start_line = 1,
    text = "run()",
  }, "Review this.")
  reviewbuddy.capture = function()
    return { repo_root = root_path }
  end
  targets.discover = function(_, callback)
    callback({
      {
        backend = "cmux_terminal",
        id = "surface-cursor",
        agent = "Cursor Agent",
        status = "paste + submit",
        workspace = "Review workspace",
      },
    }, nil)
  end
  vim.ui.select = function()
    picker_opened = true
  end
  submit.send = function(_, target, callback)
    selected_target = target
    callback(true, nil)
  end

  reviewbuddy.submit_queue()

  reviewbuddy.capture = original_capture
  targets.discover = original_targets_discover
  vim.ui.select = original_select
  submit.send = original_send
  assert_equal(picker_opened, nil)
  assert_equal(selected_target.id, "surface-cursor")
end

test_skips_picker_for_single_target()

local function test_does_not_request_manual_submit_for_cmux_terminal()
  local source = table.concat(vim.fn.readfile(root .. "/dev/reviewbuddy.nvim/lua/reviewbuddy/init.lua"), "\n")
  assert(not source:find("submit it manually", 1, true))
end

test_does_not_request_manual_submit_for_cmux_terminal()

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

local function test_formats_file_only_project_context_without_line_number()
  assert(vim.deep_equal(
    input.queue_lines({
      {
        selection = {
          context_kind = "project",
          selection_kind = "file",
          path = "apps/video/src/example.lua",
        },
        comment = "Review this file.",
      },
    }),
    {
      "1. apps/video/src/example.lua — Review this file.",
    }
  ))
end

test_formats_file_only_project_context_without_line_number()

local function test_deletes_one_queued_comment_without_closing_composer()
  local root_path = "/work/delete-one"
  local original_snacks = package.loaded["snacks"]
  local original_keymap_set = vim.keymap.set
  local mappings = {}
  local windows = {}
  queue.clear(root_path)
  queue.add({
    repo_root = root_path,
    path = "lua/first.lua",
    start_line = 1,
    text = "first()",
  }, "First review.")
  queue.add({
    repo_root = root_path,
    path = "lua/second.lua",
    start_line = 2,
    text = "second()",
  }, "Second review.")

  package.loaded["snacks"] = {
    win = function(options)
      local buf = vim.api.nvim_create_buf(false, true)
      local win_id = vim.api.nvim_open_win(buf, options.enter == true, {
        relative = "editor",
        row = #windows,
        col = 0,
        width = 60,
        height = 4,
        style = "minimal",
      })
      local fake = { buf = buf, win = win_id, closed = false }
      function fake:close()
        self.closed = true
        if vim.api.nvim_win_is_valid(self.win) then
          vim.api.nvim_win_close(self.win, true)
        end
      end
      function fake:focus()
        vim.api.nvim_set_current_win(self.win)
      end
      function fake:set_title(title)
        self.title = title
      end
      windows[#windows + 1] = fake
      return fake
    end,
  }
  vim.keymap.set = function(mode, lhs, rhs, options)
    if type(rhs) == "function" and options and options.buffer then
      mappings[options.buffer] = mappings[options.buffer] or {}
      mappings[options.buffer][lhs] = rhs
    end
    original_keymap_set(mode, lhs, rhs, options)
  end

  local ok, err = xpcall(function()
    input.open({ width = 0.7, height = 0.3 }, "Review comment", {
      items = queue.items(root_path),
      on_add = function() end,
      on_submit = function() end,
      on_delete = function(item)
        queue.remove(root_path, { item })
      end,
    })

    local composer = windows[1]
    local queue_list = windows[2]
    vim.api.nvim_buf_set_lines(composer.buf, 0, -1, false, { "Keep this draft." })
    mappings[composer.buf]["<C-d>"]()
    mappings[queue_list.buf]["<Esc>"]()
    assert_equal(queue.count(root_path), 2)
    assert_equal(vim.api.nvim_get_current_win(), composer.win)
    assert_equal(vim.api.nvim_buf_get_lines(composer.buf, 0, -1, false)[1], "Keep this draft.")

    mappings[composer.buf]["<C-d>"]()
    vim.api.nvim_win_set_cursor(queue_list.win, { 2, 0 })
    mappings[queue_list.buf]["<CR>"]()

    assert_equal(queue.count(root_path), 1)
    assert_equal(queue.items(root_path)[1].comment, "First review.")
    assert_equal(composer.closed, false)
    assert_equal(vim.api.nvim_get_current_win(), composer.win)
    assert_equal(vim.api.nvim_buf_get_lines(composer.buf, 0, -1, false)[1], "Keep this draft.")
  end, debug.traceback)

  vim.keymap.set = original_keymap_set
  package.loaded["snacks"] = original_snacks
  for _, window in ipairs(windows) do
    if vim.api.nvim_win_is_valid(window.win) then
      vim.api.nvim_win_close(window.win, true)
    end
    if vim.api.nvim_buf_is_valid(window.buf) then
      vim.api.nvim_buf_delete(window.buf, { force = true })
    end
  end
  queue.clear(root_path)
  if not ok then
    error(err)
  end
end

test_deletes_one_queued_comment_without_closing_composer()

local function test_submits_on_enter_and_queues_on_ctrl_s()
  local source = table.concat(vim.fn.readfile(root .. "/dev/reviewbuddy.nvim/lua/reviewbuddy/input.lua"), "\n")
  local fallback = source:match("if not ok then(.-)\n  end\n\n  local win")

  assert(source:find('footer = " Enter Submit all   Ctrl+S Queue   Ctrl+D Delete one', 1, true))
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
  local info = repo.for_path(root .. "/tests/reviewbuddy_spec.lua")

  assert_equal(info.root, root)
  assert_equal(info.relpath, "tests/reviewbuddy_spec.lua")
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

  local info = repo.for_path(linked_root .. "/tests/reviewbuddy_spec.lua")
  vim.fn.delete(temp, "rf")

  assert_equal(info.root, root)
  assert_equal(info.relpath, "tests/reviewbuddy_spec.lua")
end

test_resolves_git_context_for_symlinked_file()

local function test_reserves_f8_for_reviewbuddy()
  local reviewbuddy_spec = table.concat(vim.fn.readfile(root .. "/lua/plugins/reviewbuddy.lua"), "\n")

  assert(reviewbuddy_spec:find('"<F8>"', 1, true), "ReviewBuddy must own F8")
  assert(not reviewbuddy_spec:find('":<C-u>ReviewCommentVisual<cr>"', 1, true), "Visual F8 must not open command line")
  assert(reviewbuddy_spec:find('"<cmd>ReviewCommentVisual<cr>"', 1, true), "Visual F8 must use <cmd>")
end

test_reserves_f8_for_reviewbuddy()

local function test_exposes_a_submit_queue_command()
  local reviewbuddy_spec = table.concat(vim.fn.readfile(root .. "/lua/plugins/reviewbuddy.lua"), "\n")
  local reviewbuddy_init = table.concat(vim.fn.readfile(root .. "/dev/reviewbuddy.nvim/lua/reviewbuddy/init.lua"), "\n")
  assert(reviewbuddy_spec:find('"ReviewSubmitQueue"', 1, true), "ReviewSubmitQueue must be lazy-loaded")
  assert(reviewbuddy_spec:find('"ReviewPick"', 1, true), "ReviewPick must be lazy-loaded")
  assert(reviewbuddy_spec:find('"ReviewRefresh"', 1, true), "ReviewRefresh must be lazy-loaded")
  assert(reviewbuddy_init:find('"ReviewSubmitQueue"', 1, true), "ReviewSubmitQueue must submit the unified queue")
  assert(reviewbuddy_spec:find('"HerdrSubmitQueue"', 1, true), "Herdr must expose queue submission")
end

test_exposes_a_submit_queue_command()

local function test_uses_messages_instead_of_toast_notifications()
  local reviewbuddy_init = table.concat(vim.fn.readfile(root .. "/dev/reviewbuddy.nvim/lua/reviewbuddy/init.lua"), "\n")
  assert(not reviewbuddy_init:find("vim.notify(", 1, true), "ReviewBuddy feedback must not create toast notifications")
end

test_uses_messages_instead_of_toast_notifications()

local function test_registers_review_commands_and_all_legacy_aliases()
  reviewbuddy.setup({})
  for _, command in ipairs({
    "ReviewComment",
    "ReviewCommentVisual",
    "ReviewSubmitQueue",
    "ReviewPick",
    "ReviewRefresh",
    "ReviewStatus",
    "HerdrComment",
    "HerdrCommentVisual",
    "HerdrSubmitQueue",
    "HerdrPick",
    "HerdrRefresh",
    "HerdrStatus",
  }) do
    assert_equal(vim.fn.exists(":" .. command), 2, command .. " must be registered")
  end
end

test_registers_review_commands_and_all_legacy_aliases()
print("reviewbuddy_spec: all tests passed")
