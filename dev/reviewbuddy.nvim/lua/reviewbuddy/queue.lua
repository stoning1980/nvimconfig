local M = {}
local queues = {}
local next_id = 0

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
  next_id = next_id + 1
  queues[repo_root] = queues[repo_root] or {}
  queues[repo_root][#queues[repo_root] + 1] = {
    id = next_id,
    selection = vim.deepcopy(selection),
    comment = comment,
  }
end

---@param repo_root string
---@param items table[]
function M.remove(repo_root, items)
  local removed = {}
  for _, item in ipairs(items) do
    removed[item.id] = true
  end
  local remaining = {}
  for _, item in ipairs(queues[repo_root] or {}) do
    if not removed[item.id] then
      remaining[#remaining + 1] = item
    end
  end
  queues[repo_root] = #remaining > 0 and remaining or nil
end

---@param repo_root string
function M.clear(repo_root)
  queues[repo_root] = nil
end

return M
