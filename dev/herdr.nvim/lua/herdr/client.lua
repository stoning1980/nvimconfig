local M = {}

---@param selection table
---@param comment string
---@return string
function M.review_prompt(selection, comment)
  local location = selection.path .. ":" .. selection.start_line
  if selection.end_line and selection.end_line ~= selection.start_line then
    location = location .. "-" .. selection.end_line
  end
  return table.concat({
    "Review comment from Neovim",
    "Repository location: " .. location,
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

---@param agent table
---@param selection table
---@param comment string
---@param callback fun(ok: boolean, err: string|nil)
function M.send_review(agent, selection, comment, callback)
  local target = agent.agent_id or agent.pane_id or agent.name
  if not target then
    callback(false, "Herdr agent has no target ID")
    return
  end
  vim.system({ "herdr", "agent", "prompt", target, M.review_prompt(selection, comment) }, { text = true }, function(result)
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

return M
