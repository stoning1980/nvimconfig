local M = {}

---@param path string|nil
---@param root string
---@return boolean
local function belongs_to_repo(path, root)
  if type(path) ~= "string" then
    return false
  end
  root = root:gsub("/+$", "")
  return path == root or vim.startswith(path, root .. "/")
end

---@param snapshot table
---@param repo_root string
---@param workspace_id string|nil
---@return table[]
function M.match_agents(snapshot, repo_root, workspace_id)
  local result = snapshot.result or snapshot
  result = result.snapshot or result
  local matches = {}
  for _, agent in ipairs(result.agents or {}) do
    local same_workspace = not workspace_id or agent.workspace_id == workspace_id
    if
      same_workspace and (belongs_to_repo(agent.foreground_cwd, repo_root) or belongs_to_repo(agent.cwd, repo_root))
    then
      matches[#matches + 1] = agent
    end
  end
  return matches
end

---@return string[]
function M.snapshot_command()
  return { "herdr", "api", "snapshot" }
end

---@param callback fun(agents: table[]|nil, err: string|nil)
---@param repo_root string
function M.for_repo(repo_root, callback)
  local workspace_id = vim.env.HERDR_WORKSPACE_ID
  if not workspace_id or workspace_id == "" then
    callback(nil, "Herdr workspace identity is unavailable")
    return
  end
  vim.system(M.snapshot_command(), { text = true }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        local message = vim.trim(result.stderr ~= "" and result.stderr or result.stdout)
        callback(nil, message ~= "" and message or "unable to query Herdr")
        return
      end
      local ok, snapshot = pcall(vim.json.decode, result.stdout)
      if not ok then
        callback(nil, "Herdr returned invalid JSON")
        return
      end
      callback(M.match_agents(snapshot, repo_root, workspace_id), nil)
    end)
  end)
end

return M
