local client = require("herdr.client")
local discovery = require("herdr.discovery")

local M = {
  id = "herdr",
  target_ids = { "herdr" },
  host_error = "Neovim is no longer running inside Herdr",
}

function M.detect()
  return vim.env.HERDR_ENV == "1"
end

---@param agents table[]
---@return table[]
function M.targets(agents)
  local result = {}
  for _, agent in ipairs(agents) do
    local session_id = agent.agent_session and agent.agent_session.value
    local identity = session_id or agent.agent_id
    if identity then
      result[#result + 1] = {
        backend = "herdr",
        id = agent.agent_id or agent.pane_id or agent.name,
        agent = agent.agent or "agent",
        status = agent.agent_status or agent.status or "unknown",
        workspace_id = agent.workspace_id,
        session_id = session_id,
        identity = identity,
        source = agent,
      }
    end
  end
  return result
end

---@param repo_root string
---@param callback fun(targets: table[]|nil, err: string|nil)
function M.discover(repo_root, callback)
  if not vim.env.HERDR_WORKSPACE_ID or vim.env.HERDR_WORKSPACE_ID == "" then
    callback(nil, "Herdr workspace identity is unavailable")
    return
  end
  discovery.for_repo(repo_root, function(agents, err)
    callback(agents and M.targets(agents) or nil, err)
  end)
end

---@param repo_root string
---@param target table
---@param callback fun(target: table|nil, err: string|nil)
function M.revalidate(repo_root, target, callback)
  if
    not vim.env.HERDR_WORKSPACE_ID
    or vim.env.HERDR_WORKSPACE_ID == ""
    or target.workspace_id ~= vim.env.HERDR_WORKSPACE_ID
  then
    callback(nil, "Herdr target is no longer in Neovim's workspace")
    return
  end
  discovery.for_repo(repo_root, function(agents, err)
    if not agents then
      callback(nil, err)
      return
    end
    for _, current in ipairs(M.targets(agents)) do
      if current.id == target.id then
        if current.identity ~= target.identity then
          callback(nil, "Herdr target agent changed before delivery")
          return
        end
        callback(current, nil)
        return
      end
    end
    callback(nil, "Herdr target is no longer in this repository and workspace")
  end)
end

---@param target table
---@return string
function M.label(target)
  return string.format("[Herdr] %s [%s] %s", target.agent, target.status, target.id)
end

---@param target table
---@param items table[]
---@param callback fun(ok: boolean, err: string|nil)
function M.send_queue(target, items, callback)
  client.send_queue(target.source, items, callback)
end

return M
