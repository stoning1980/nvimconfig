local client = require("herdr.client")
local config = require("herdr.config")
local context = require("herdr.context")
local discovery = require("herdr.discovery")
local diffview = require("herdr.diffview")
local input = require("herdr.input")
local queue = require("herdr.queue")
local repo = require("herdr.repo")

local M = {}
local active_agents = {}

local function notify(message, level)
  local highlight = ({
    [vim.log.levels.ERROR] = "ErrorMsg",
    [vim.log.levels.WARN] = "WarningMsg",
  })[level] or "None"
  vim.schedule(function()
    vim.api.nvim_echo({ { "[herdr] " .. message, highlight } }, false, {})
  end)
end

---@param buf integer
---@param visual boolean
---@return table|nil
local function editor_selection(buf, visual)
  local start_line, start_col, end_line, end_col
  if visual then
    local start = vim.api.nvim_buf_get_mark(buf, "<")
    local finish = vim.api.nvim_buf_get_mark(buf, ">")
    start_line, start_col = start[1], start[2]
    end_line, end_col = finish[1], finish[2]
    if start_line == 0 or end_line == 0 then
      notify("no visual selection to send", vim.log.levels.WARN)
      return nil
    end
    if start_line > end_line or (start_line == end_line and start_col > end_col) then
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
  if visual and vim.fn.visualmode() == "\22" then
    text = context.block_text(vim.api.nvim_buf_get_lines(buf, start_line - 1, end_line, false), start_col, end_col)
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
    if not diffview.matches_worktree(view.cur_layout.windows[2].file) then
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

local function label(agent)
  return string.format(
    "%s  [%s]  %s",
    agent.agent or "agent",
    agent.agent_status or agent.status or "unknown",
    agent.agent_id or agent.pane_id or "?"
  )
end

---@param selection table
---@param agents table[]
local function choose_agent(selection, agents)
  local remembered = active_agents[selection.repo_root]
  for _, agent in ipairs(agents) do
    if remembered and (agent.agent_id == remembered or agent.pane_id == remembered) then
      return agent
    end
  end
  if #agents == 1 then
    return agents[1]
  end
  return nil
end

---@param repo_root string
---@param agent table
local function send_queue(agent, repo_root)
  local items = queue.items(repo_root)
  if #items == 0 then
    notify("no queued review comments for this repository", vim.log.levels.WARN)
    return
  end
  client.send_queue(agent, items, function(ok, err)
    if ok then
      queue.clear(repo_root)
      notify(string.format("sent %d queued review comment(s) to %s", #items, label(agent)))
    else
      notify(err, vim.log.levels.ERROR)
    end
  end)
end

---@param repo_root string
---@param agents table[]
local function route_queue(repo_root, agents)
  if #agents == 0 then
    notify("no Herdr agent is running for this repository", vim.log.levels.WARN)
    return
  end
  local agent = choose_agent({ repo_root = repo_root }, agents)
  if agent then
    send_queue(agent, repo_root)
    return
  end
  local labels = vim.tbl_map(label, agents)
  vim.ui.select(labels, { prompt = "Submit queued comments to which Herdr agent?" }, function(_, index)
    if index then
      local selected = agents[index]
      active_agents[repo_root] = selected.agent_id or selected.pane_id
      send_queue(selected, repo_root)
    end
  end)
end

---@param repo_root string
local function submit_queue(repo_root)
  if queue.count(repo_root) == 0 then
    notify("no queued review comments for this repository", vim.log.levels.WARN)
    return
  end
  discovery.for_repo(repo_root, function(agents, err)
    if err then
      notify(err, vim.log.levels.ERROR)
      return
    end
    route_queue(repo_root, agents)
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
  local selection = M.capture(false)
  if not selection then
    return
  end
  discovery.for_repo(selection.repo_root, function(agents, err)
    if err then
      notify(err, vim.log.levels.ERROR)
      return
    end
    if #agents == 0 then
      notify("no Herdr agent is running for this repository", vim.log.levels.WARN)
      return
    end
    vim.ui.select(vim.tbl_map(label, agents), { prompt = "Choose Herdr agent" }, function(_, index)
      if index then
        local agent = agents[index]
        active_agents[selection.repo_root] = agent.agent_id or agent.pane_id
        notify("active agent: " .. label(agent))
      end
    end)
  end)
end

function M.refresh()
  local selection = M.capture(false)
  if selection then
    active_agents[selection.repo_root] = nil
  end
  M.status()
end

function M.status()
  local selection = M.capture(false)
  if not selection then
    return
  end
  discovery.for_repo(selection.repo_root, function(agents, err)
    if err then
      notify(err, vim.log.levels.ERROR)
      return
    end
    if #agents == 0 then
      notify(
        string.format("%d queued review comment(s); no Herdr agent is running", queue.count(selection.repo_root)),
        vim.log.levels.WARN
      )
      return
    end
    notify(
      string.format(
        "%d queued review comment(s); %d Herdr agent(s): %s",
        queue.count(selection.repo_root),
        #agents,
        table.concat(vim.tbl_map(label, agents), ", ")
      )
    )
  end)
end

function M.setup(opts)
  config.setup(opts)
  vim.api.nvim_create_user_command("HerdrComment", function()
    M.comment(false)
  end, { desc = "Queue current line review comment for Herdr agent" })
  vim.api.nvim_create_user_command("HerdrCommentVisual", function()
    M.comment(true)
  end, { desc = "Queue visual review comment for Herdr agent" })
  vim.api.nvim_create_user_command(
    "HerdrSubmitQueue",
    M.submit_queue,
    { desc = "Submit queued review comments to Herdr agent" }
  )
  vim.api.nvim_create_user_command("HerdrPick", M.pick, { desc = "Choose Herdr agent for this repository" })
  vim.api.nvim_create_user_command("HerdrRefresh", M.refresh, { desc = "Refresh Herdr agents for this repository" })
  vim.api.nvim_create_user_command("HerdrStatus", M.status, { desc = "Show Herdr agent status for this repository" })
end

return M
