local M = {}
local queues = {}

---@param repo_root string
---@return table[]
function M.items(repo_root)
  return vim.deepcopy(queues[repo_root] or {})
end

---@param repo_root string
---@return integer
function M.count(repo_root)
  return #(queues[repo_root] or {})
end

---@param selection table
---@param comment string
function M.add(selection, comment)
  local repo_root = selection.repo_root
  queues[repo_root] = queues[repo_root] or {}
  queues[repo_root][#queues[repo_root] + 1] = {
    selection = vim.deepcopy(selection),
    comment = comment,
  }
end

---@param repo_root string
function M.clear(repo_root)
  queues[repo_root] = nil
end

return M
