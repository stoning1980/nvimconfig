local cmux = require("herdr.cmux")
local discovery = require("herdr.discovery")

local M = {}

---@param agents table[]
---@return table[]
function M.herdr(agents)
  local result = {}
  for _, agent in ipairs(agents) do
    result[#result + 1] = {
      backend = "herdr",
      id = agent.agent_id or agent.pane_id or agent.name,
      agent = agent.agent or "agent",
      status = agent.agent_status or agent.status or "unknown",
      workspace_id = agent.workspace_id,
      session_id = agent.agent_session and agent.agent_session.value,
      source = agent,
    }
  end
  return result
end

---@param target table
---@return string
function M.label(target)
  if target.backend == "cmux" then
    return string.format("[cmux] %s [%s] %s", target.agent, target.status, target.workspace)
  end
  if target.backend == "cmux_terminal" then
    return string.format("[cmux terminal] %s [paste + submit] %s", target.agent, target.workspace)
  end
  return string.format("[Herdr] %s [%s] %s", target.agent, target.status, target.id)
end

---@param repo_root string
---@param callback fun(targets: table[]|nil, err: string|nil)
function M.discover(repo_root, callback)
  if vim.env.HERDR_ENV == "1" then
    if not vim.env.HERDR_WORKSPACE_ID or vim.env.HERDR_WORKSPACE_ID == "" then
      callback(nil, "Herdr workspace identity is unavailable")
      return
    end
    discovery.for_repo(repo_root, function(agents, err)
      callback(agents and M.herdr(agents) or nil, err)
    end)
    return
  end

  if vim.env.CMUX_SURFACE_ID and vim.env.CMUX_SURFACE_ID ~= "" then
    cmux.discover(callback)
    return
  end

  callback(nil, "Neovim is not running inside Herdr or cmux")
end

---@param repo_root string
---@param target table
---@param callback fun(target: table|nil, err: string|nil)
function M.revalidate(repo_root, target, callback)
  if target.backend == "herdr" then
    if vim.env.HERDR_ENV ~= "1" then
      callback(nil, "Neovim is no longer running inside Herdr")
      return
    end
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
      for _, current in ipairs(M.herdr(agents)) do
        if current.id == target.id then
          if target.session_id and current.session_id ~= target.session_id then
            callback(nil, "Herdr target agent changed before delivery")
            return
          end
          callback(current, nil)
          return
        end
      end
      callback(nil, "Herdr target is no longer in this repository and workspace")
    end)
    return
  end

  if vim.env.HERDR_ENV == "1" or not vim.env.CMUX_SURFACE_ID or vim.env.CMUX_SURFACE_ID == "" then
    callback(nil, "Neovim is no longer running exclusively inside cmux")
    return
  end
  cmux.revalidate(target, callback)
end

return M
