local client = require("herdr.client")
local config = require("herdr.config")
local context = require("herdr.context")
local discovery = require("herdr.discovery")
local input = require("herdr.input")
local repo = require("herdr.repo")

local M = {}
local active_agents = {}

local function notify(message, level)
  vim.notify("[herdr] " .. message, level or vim.log.levels.INFO)
end

---@param visual boolean
---@return table|nil
local function capture(visual)
  local buf = vim.api.nvim_get_current_buf()
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
  return context.selection({
    repo_root = info.root,
    path = path,
    start_line = start_line,
    start_col = start_col,
    end_line = end_line,
    end_col = end_col,
    text = text,
    branch = info.branch,
    revision = info.revision,
  })
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

---@param selection table
---@param agent table
local function comment(agent, selection)
  input.open(config.options.input, "Review comment → " .. label(agent), function(comment_text)
    client.send_review(agent, selection, comment_text, function(ok, err)
      if ok then
        notify("review comment sent to " .. label(agent))
      else
        notify(err, vim.log.levels.ERROR)
      end
    end)
  end)
end

---@param selection table
---@param agents table[]
local function route_comment(selection, agents)
  if #agents == 0 then
    notify("no Herdr agent is running for this repository", vim.log.levels.WARN)
    return
  end
  local agent = choose_agent(selection, agents)
  if agent then
    comment(agent, selection)
    return
  end
  local labels = vim.tbl_map(label, agents)
  vim.ui.select(labels, { prompt = "Send review comment to which Herdr agent?" }, function(_, index)
    if not index then
      return
    end
    local selected = agents[index]
    active_agents[selection.repo_root] = selected.agent_id or selected.pane_id
    comment(selected, selection)
  end)
end

---@param visual boolean
function M.comment(visual)
  local selection = capture(visual)
  if not selection then
    return
  end
  discovery.for_repo(selection.repo_root, function(agents, err)
    if err then
      notify(err, vim.log.levels.ERROR)
      return
    end
    route_comment(selection, agents)
  end)
end

function M.pick()
  local selection = capture(false)
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
  local selection = capture(false)
  if selection then
    active_agents[selection.repo_root] = nil
  end
  M.status()
end

function M.status()
  local selection = capture(false)
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
    notify(string.format("%d Herdr agent(s): %s", #agents, table.concat(vim.tbl_map(label, agents), ", ")))
  end)
end

function M.setup(opts)
  config.setup(opts)
  vim.api.nvim_create_user_command("HerdrComment", function()
    M.comment(false)
  end, { desc = "Send current line review comment to Herdr agent" })
  vim.api.nvim_create_user_command("HerdrCommentVisual", function()
    M.comment(true)
  end, { desc = "Send visual review comment to Herdr agent" })
  vim.api.nvim_create_user_command("HerdrPick", M.pick, { desc = "Choose Herdr agent for this repository" })
  vim.api.nvim_create_user_command("HerdrRefresh", M.refresh, { desc = "Refresh Herdr agents for this repository" })
  vim.api.nvim_create_user_command("HerdrStatus", M.status, { desc = "Show Herdr agent status for this repository" })
end

return M
