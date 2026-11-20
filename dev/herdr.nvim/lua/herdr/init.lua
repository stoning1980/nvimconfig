local config = require("herdr.config")
local context = require("herdr.context")
local diffview = require("herdr.diffview")
local input = require("herdr.input")
local queue = require("herdr.queue")
local repo = require("herdr.repo")
local submit = require("herdr.submit")
local targets = require("herdr.targets")

local M = {}

local function notify(message, level)
  local highlight = ({
    [vim.log.levels.ERROR] = "ErrorMsg",
    [vim.log.levels.WARN] = "WarningMsg",
  })[level] or "None"
  vim.schedule(function()
    vim.api.nvim_echo({ { "[review] " .. message, highlight } }, false, {})
  end)
end

---@param buf integer
---@param visual boolean
---@return table|nil
local function editor_selection(buf, visual)
  local start_line, start_col, end_line, end_col
  local selection_mode
  if visual then
    local mode = vim.fn.mode()
    local live_modes = {
      v = "v",
      V = "V",
      ["\22"] = "\22",
      s = "v",
      S = "V",
      ["\19"] = "\22",
    }
    selection_mode = live_modes[mode]
    if selection_mode then
      local start = vim.fn.getpos("v")
      local finish = vim.fn.getpos(".")
      start_line, start_col = start[2], math.max(start[3] - 1, 0)
      end_line, end_col = finish[2], math.max(finish[3] - 1, 0)
    else
      local start = vim.api.nvim_buf_get_mark(buf, "<")
      local finish = vim.api.nvim_buf_get_mark(buf, ">")
      start_line, start_col = start[1], start[2]
      end_line, end_col = finish[1], finish[2]
      selection_mode = vim.fn.visualmode()
    end
    if start_line == 0 or end_line == 0 then
      notify("no visual selection to send", vim.log.levels.WARN)
      return nil
    end
    if selection_mode == "\22" then
      start_line, end_line = math.min(start_line, end_line), math.max(start_line, end_line)
      start_col, end_col = math.min(start_col, end_col), math.max(start_col, end_col)
    elseif start_line > end_line or (start_line == end_line and start_col > end_col) then
      start_line, end_line = end_line, start_line
      start_col, end_col = end_col, start_col
    end
  else
    start_line = vim.api.nvim_win_get_cursor(0)[1]
    end_line = start_line
    start_col = 0
    end_col = #vim.api.nvim_buf_get_lines(buf, start_line - 1, start_line, false)[1]
  end

  local text
  if visual and selection_mode == "\22" then
    text = context.block_text(vim.api.nvim_buf_get_lines(buf, start_line - 1, end_line, false), start_col, end_col)
  elseif visual and selection_mode == "V" then
    local lines = vim.api.nvim_buf_get_lines(buf, start_line - 1, end_line, false)
    start_col = 0
    end_col = #(lines[#lines] or "")
    text = table.concat(lines, "\n")
  else
    text = table.concat(
      vim.api.nvim_buf_get_text(buf, start_line - 1, start_col, end_line - 1, end_col + (visual and 1 or 0), {}),
      "\n"
    )
  end
  return {
    start_line = start_line,
    start_col = start_col,
    end_line = end_line,
    end_col = end_col,
    text = text,
  }
end

---@param visual boolean
---@return table|nil
function M.capture(visual)
  local buf = vim.api.nvim_get_current_buf()
  local selection = editor_selection(buf, visual)
  if not selection then
    return nil
  end

  local ok, lib = pcall(require, "diffview.lib")
  local view = ok and lib.get_current_view() or nil
  local current_win = vim.api.nvim_get_current_win()
  if view and diffview.contains_window(view, current_win) then
    local root = view.adapter and view.adapter.ctx and view.adapter.ctx.toplevel
    local info = root and repo.for_root(root) or nil
    if not info then
      notify("Diffview repository context is unavailable", vim.log.levels.WARN)
      return nil
    end
    local captured, err = diffview.snapshot(view, current_win, selection, info)
    if not captured then
      notify(err, vim.log.levels.WARN)
      return nil
    end
    local target_file = view.cur_layout.windows[2].file
    if diffview.is_worktree(target_file) and not diffview.matches_worktree(target_file) then
      notify("right Diffview pane does not match the checked-out file", vim.log.levels.WARN)
      return nil
    end
    return captured
  end

  if vim.bo[buf].buftype ~= "" then
    notify("current buffer is not a file", vim.log.levels.WARN)
    return nil
  end
  local path = vim.api.nvim_buf_get_name(buf)
  local info = repo.for_path(path)
  if not info then
    notify("current file is not in a Git repository", vim.log.levels.WARN)
    return nil
  end
  return context.selection(vim.tbl_extend("force", selection, {
    repo_root = info.root,
    path = path,
    branch = info.branch,
    revision = info.revision,
  }))
end

---@param repo_root string
local function submit_queue(repo_root)
  if queue.count(repo_root) == 0 then
    notify("no queued review comments for this repository", vim.log.levels.WARN)
    return
  end
  targets.discover(repo_root, function(available, err)
    if err then
      notify(err, vim.log.levels.ERROR)
      return
    end
    if #available == 0 then
      notify("no review session is available for this repository or cmux workspace", vim.log.levels.WARN)
      return
    end

    local function send_to(target)
      local item_count = queue.count(repo_root)
      submit.send(repo_root, target, function(ok, send_err)
        if ok then
          notify(string.format("sent %d queued review comment(s) to %s", item_count, targets.label(target)))
        else
          notify(send_err, vim.log.levels.ERROR)
        end
      end)
    end

    if #available == 1 then
      send_to(available[1])
      return
    end

    vim.ui.select(available, {
      prompt = "Submit queued comments to which session?",
      format_item = targets.label,
    }, function(target)
      if not target then
        return
      end
      send_to(target)
    end)
  end)
end

---@param selection table
local function comment(selection)
  local queued = queue.count(selection.repo_root)
  input.open(config.options.input, string.format("Review comment (queued: %d)", queued), {
    items = queue.items(selection.repo_root),
    on_add = function(comment_text)
      queue.add(selection, comment_text)
      notify(string.format("review comment added to queue (%d)", queue.count(selection.repo_root)))
    end,
    on_submit = function(comment_text)
      if comment_text ~= "" then
        queue.add(selection, comment_text)
      end
      submit_queue(selection.repo_root)
    end,
  })
end

---@param visual boolean
function M.comment(visual)
  local selection = M.capture(visual)
  if selection then
    comment(selection)
  end
end

function M.submit_queue()
  local selection = M.capture(false)
  if selection then
    submit_queue(selection.repo_root)
  end
end

function M.pick()
  notify("a single review session is used automatically; multiple sessions are chosen after Submit")
end

function M.refresh()
  M.status()
end

function M.status()
  local selection = M.capture(false)
  if not selection then
    return
  end
  targets.discover(selection.repo_root, function(available, err)
    if err then
      notify(err, vim.log.levels.ERROR)
      return
    end
    if #available == 0 then
      notify(
        string.format("%d queued review comment(s); no review session is available", queue.count(selection.repo_root)),
        vim.log.levels.WARN
      )
      return
    end
    notify(
      string.format(
        "%d queued review comment(s); %d session(s): %s",
        queue.count(selection.repo_root),
        #available,
        table.concat(vim.tbl_map(targets.label, available), ", ")
      )
    )
  end)
end

function M.setup(opts)
  config.setup(opts)
  vim.api.nvim_create_user_command("ReviewComment", function()
    M.comment(false)
  end, { desc = "Queue current line review comment" })
  vim.api.nvim_create_user_command("ReviewCommentVisual", function()
    M.comment(true)
  end, { desc = "Queue visual review comment" })
  vim.api.nvim_create_user_command(
    "ReviewSubmitQueue",
    M.submit_queue,
    { desc = "Choose a session and submit queued review comments" }
  )
  vim.api.nvim_create_user_command("ReviewStatus", M.status, { desc = "Show review queue and session status" })

  -- Compatibility aliases for the original Herdr-only commands.
  vim.api.nvim_create_user_command("HerdrComment", function()
    M.comment(false)
  end, { desc = "Queue current line review comment" })
  vim.api.nvim_create_user_command("HerdrCommentVisual", function()
    M.comment(true)
  end, { desc = "Queue visual review comment" })
  vim.api.nvim_create_user_command(
    "HerdrSubmitQueue",
    M.submit_queue,
    { desc = "Choose a session and submit queued review comments" }
  )
  vim.api.nvim_create_user_command("HerdrPick", M.pick, { desc = "Explain review session selection timing" })
  vim.api.nvim_create_user_command("HerdrRefresh", M.refresh, { desc = "Refresh review sessions for this repository" })
  vim.api.nvim_create_user_command("HerdrStatus", M.status, { desc = "Show review queue and session status" })
end

return M
