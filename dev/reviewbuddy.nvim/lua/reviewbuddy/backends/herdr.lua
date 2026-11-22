local client = require("reviewbuddy.client")
local discovery = require("reviewbuddy.discovery")

local M = {
  id = "herdr",
  target_ids = { "herdr" },
  host_error = "Neovim is no longer running inside Herdr",
}

function M.detect()
  return vim.env.HERDR_ENV == "1"
end

---@param pane_id string
---@return string[]
function M.process_command(pane_id)
  return { "herdr", "pane", "process-info", "--pane", pane_id }
end

---@param payload table
---@param pane_id string
---@return string|nil
local function process_identity(payload, pane_id)
  local result = payload.result or payload
  local info = result.process_info or result
  if info.pane_id ~= pane_id or not info.foreground_process_group_id then
    return nil
  end
  local processes = {}
  for _, process in ipairs(info.foreground_processes or {}) do
    if process.pid then
      processes[#processes + 1] = vim.json.encode({
        tostring(process.pid),
        process.name or "",
        process.argv0 or "",
        process.cwd or "",
        process.cmdline or table.concat(process.argv or {}, " "),
      })
    end
  end
  if #processes == 0 then
    return nil
  end
  table.sort(processes)
  local canonical = vim.json.encode({
    tostring(info.foreground_process_group_id),
    processes,
  })
  return "process:" .. vim.fn.sha256(canonical)
end

---@param pane_id string
---@param callback fun(identity: string|nil)
local function query_process_identity(pane_id, callback)
  vim.system(M.process_command(pane_id), { text = true }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        callback(nil)
        return
      end
      local ok, payload = pcall(vim.json.decode, result.stdout)
      callback(ok and process_identity(payload, pane_id) or nil)
    end)
  end)
end

---@param agents table[]
---@param process_identities table<string, string>|nil
---@return table[]
function M.targets(agents, process_identities)
  local result = {}
  for _, agent in ipairs(agents) do
    local session_id = agent.agent_session and agent.agent_session.value
    local identity = session_id or agent.agent_id or (process_identities and process_identities[agent.pane_id])
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

---@param agents table[]
---@param callback fun(targets: table[])
local function targets_with_process_identities(agents, callback)
  local results = {}
  local pending = 0
  local function finish()
    if pending ~= 0 then
      return
    end
    local compact = {}
    for index = 1, #agents do
      if results[index] then
        compact[#compact + 1] = results[index]
      end
    end
    callback(compact)
  end
  for index, agent in ipairs(agents) do
    local result_index = index
    local current_agent = agent
    local target = M.targets({ current_agent })[1]
    if target then
      results[result_index] = target
    elseif current_agent.pane_id then
      pending = pending + 1
      query_process_identity(current_agent.pane_id, function(identity)
        if identity then
          results[result_index] = M.targets({ current_agent }, { [current_agent.pane_id] = identity })[1]
        end
        pending = pending - 1
        finish()
      end)
    end
  end
  finish()
end

---@param repo_root string
---@param callback fun(targets: table[]|nil, err: string|nil)
function M.discover(repo_root, callback)
  if not vim.env.HERDR_WORKSPACE_ID or vim.env.HERDR_WORKSPACE_ID == "" then
    callback(nil, "Herdr workspace identity is unavailable")
    return
  end
  discovery.for_repo(repo_root, function(agents, err)
    if not agents then
      callback(nil, err)
      return
    end
    targets_with_process_identities(agents, function(found)
      callback(found, nil)
    end)
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
  M.discover(repo_root, function(current_targets, err)
    if not current_targets then
      callback(nil, err)
      return
    end
    for _, current in ipairs(current_targets) do
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
