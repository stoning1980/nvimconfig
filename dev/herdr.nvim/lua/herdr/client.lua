local M = {}

---@param selection table
---@return string
local function location(selection)
  local value = selection.path .. ":" .. selection.start_line
  if selection.end_line and selection.end_line ~= selection.start_line then
    value = value .. "-" .. selection.end_line
  end
  return value
end

---@param selection table
---@param comment string
---@return string
local function changed_review_prompt(selection, comment)
  local change = selection.change
  local parts = {
    "Review comment from Neovim",
    "Repository location: " .. location(selection),
    "Branch: " .. (selection.branch or "unknown"),
    "Revision: " .. (selection.revision or "unknown"),
    "",
    "Selected current code:",
    "```",
    selection.text or "",
    "```",
    "",
    "Relevant before/current change:",
  }
  if change.patch then
    vim.list_extend(parts, {
      "```diff",
      change.patch,
      "```",
    })
  else
    parts[#parts + 1] = change.note or "No changed hunk overlaps the selected current lines."
  end
  vim.list_extend(parts, {
    "",
    "Comment:",
    comment,
  })
  return table.concat(parts, "\n")
end

---@param selection table
---@param comment string
---@return string
function M.review_prompt(selection, comment)
  if selection.change then
    return changed_review_prompt(selection, comment)
  end
  return table.concat({
    "Review comment from Neovim",
    "Repository location: " .. location(selection),
    "Branch: " .. (selection.branch or "unknown"),
    "Revision: " .. (selection.revision or "unknown"),
    "",
    "Selected code:",
    "```",
    selection.text or "",
    "```",
    "",
    "Comment:",
    comment,
  }, "\n")
end

---@param items table[]
---@return string
function M.queue_prompt(items)
  local parts = { string.format("Queued review comments from Neovim (%d)", #items) }
  for index, item in ipairs(items) do
    parts[#parts + 1] = ""
    parts[#parts + 1] = "## Review " .. index
    parts[#parts + 1] = M.review_prompt(item.selection, item.comment)
  end
  return table.concat(parts, "\n")
end

---@param agent table
---@param prompt string
---@param callback fun(ok: boolean, err: string|nil)
local function send_prompt(agent, prompt, callback)
  local target = agent.agent_id or agent.pane_id or agent.name
  if not target then
    callback(false, "Herdr agent has no target ID")
    return
  end
  vim.system({ "herdr", "agent", "prompt", target, prompt }, { text = true }, function(result)
    vim.schedule(function()
      if result.code == 0 then
        callback(true, nil)
        return
      end
      local message = vim.trim(result.stderr ~= "" and result.stderr or result.stdout)
      callback(false, message ~= "" and message or "Herdr rejected the review comment")
    end)
  end)
end

---@param agent table
---@param selection table
---@param comment string
---@param callback fun(ok: boolean, err: string|nil)
function M.send_review(agent, selection, comment, callback)
  send_prompt(agent, M.review_prompt(selection, comment), callback)
end

---@param agent table
---@param items table[]
---@param callback fun(ok: boolean, err: string|nil)
function M.send_queue(agent, items, callback)
  send_prompt(agent, M.queue_prompt(items), callback)
end

return M
