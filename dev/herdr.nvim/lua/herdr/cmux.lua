local client = require("herdr.client")

local M = {}

local supported_agents = {
  claude = true,
  codex = true,
  kiro = true,
}

local CMUX_PASTE_CHUNK_BYTES = 1400

---@param text string
---@return string[]
local function paste_chunks(text)
  local chunks = {}
  local start = 1
  while start <= #text do
    local finish = math.min(start + CMUX_PASTE_CHUNK_BYTES - 1, #text)
    if finish < #text then
      local next_byte = text:byte(finish + 1)
      if next_byte and next_byte >= 0x80 and next_byte <= 0xBF then
        while finish >= start do
          local byte = text:byte(finish)
          if not (byte and byte >= 0x80 and byte <= 0xBF) then
            break
          end
          finish = finish - 1
        end
        finish = finish - 1
      end
    end
    chunks[#chunks + 1] = text:sub(start, finish)
    start = finish + 1
  end
  return chunks
end

---@param process table
---@param foreground table<integer, boolean>
---@param identities table[]
---@param seen table<integer, boolean>
local function collect_process_agents(process, foreground, identities, seen)
  local name = (process.name or ""):lower()
  local path = (process.path or ""):lower()
  local agent
  if path:find("/cursor-agent/", 1, true) then
    agent = "Cursor"
  elseif name == "claude" or path:match("/claude$") then
    agent = "Claude Code"
  elseif name == "codex" or path:match("/codex$") then
    agent = "Codex"
  elseif name == "kiro-cli" or path:match("/kiro%-cli$") then
    agent = "Kiro"
  end
  if agent and process.pid and process.pgid and foreground[process.pgid] and not seen[process.pid] then
    seen[process.pid] = true
    identities[#identities + 1] = {
      agent = agent,
      process_id = process.pid,
      process_pgid = process.pgid,
      process_path = process.path,
    }
  end
  for _, child in ipairs(process.children or {}) do
    collect_process_agents(child, foreground, identities, seen)
  end
end

---@param payload table
---@param workspace_id string
---@return table<string, table>
local function surface_agents(payload, workspace_id)
  local result = {}
  for _, window in ipairs(payload.windows or {}) do
    for _, workspace in ipairs(window.workspaces or {}) do
      if workspace.id == workspace_id then
        for _, pane in ipairs(workspace.panes or {}) do
          for _, surface in ipairs(pane.surfaces or {}) do
            local foreground = {}
            for _, pgid in ipairs(surface.foreground_pgids or {}) do
              foreground[pgid] = true
            end
            local identities = {}
            local seen = {}
            for _, process in ipairs(surface.processes or {}) do
              collect_process_agents(process, foreground, identities, seen)
            end
            if #identities == 1 then
              result[surface.ref] = identities[1]
            end
          end
        end
      end
    end
  end
  return result
end

---@param tree table
---@param workspace_id string
---@param surface_id string
---@return boolean
local function surface_in_workspace(tree, workspace_id, surface_id)
  for _, window in ipairs(tree.windows or {}) do
    for _, workspace in ipairs(window.workspaces or {}) do
      if workspace.id == workspace_id then
        for _, pane in ipairs(workspace.panes or {}) do
          for _, surface in ipairs(pane.surfaces or {}) do
            if surface.ref == surface_id then
              return true
            end
          end
        end
      end
    end
  end
  return false
end

---@param tree table
---@return table|nil
function M.workspace(tree)
  local caller = tree.caller
  if not (caller and caller.workspace_id) then
    return nil
  end
  local title
  for _, window in ipairs(tree.windows or {}) do
    for _, workspace in ipairs(window.workspaces or {}) do
      if workspace.id == caller.workspace_id then
        title = workspace.title
        break
      end
    end
  end
  return {
    id = caller.workspace_id,
    ref = caller.workspace_ref,
    title = title or caller.workspace_ref or caller.workspace_id,
  }
end

---@param tree table
---@param workspace table
---@param processes table
---@return table[]
function M.terminal_targets(tree, workspace, processes)
  local targets = {}
  local caller_surface = tree.caller and tree.caller.surface_ref
  local agents = surface_agents(processes, workspace.id)
  for _, window in ipairs(tree.windows or {}) do
    for _, candidate in ipairs(window.workspaces or {}) do
      if candidate.id == workspace.id then
        for _, pane in ipairs(candidate.panes or {}) do
          for _, surface in ipairs(pane.surfaces or {}) do
            if surface.type == "terminal" and surface.ref ~= caller_surface and agents[surface.ref] then
              local identity = agents[surface.ref]
              targets[#targets + 1] = {
                backend = "cmux_terminal",
                id = surface.ref,
                agent = identity.agent,
                status = "paste + submit",
                workspace = workspace.title,
                workspace_id = workspace.id,
                process_id = identity.process_id,
                process_pgid = identity.process_pgid,
                process_path = identity.process_path,
              }
            end
          end
        end
      end
    end
  end
  return targets
end

---@param workspace_id string
---@return string[]
function M.sessions_command(workspace_id)
  return { "cmux", "sessions", "list", "--workspace", workspace_id, "--json" }
end

---@param workspace_id string
---@return string[]
function M.top_command(workspace_id)
  return { "cmux", "top", "--workspace", workspace_id, "--processes", "--json" }
end

---@param command string[]
---@param callback fun(payload: table|nil, err: string|nil)
local function run_json(command, callback)
  vim.system(command, { text = true }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        local message = vim.trim(result.stderr ~= "" and result.stderr or result.stdout)
        callback(nil, message ~= "" and message or "cmux command failed")
        return
      end
      local ok, payload = pcall(vim.json.decode, result.stdout)
      if not ok then
        callback(nil, "cmux returned invalid JSON")
        return
      end
      callback(payload, nil)
    end)
  end)
end

---@param payload table
---@param workspace string
---@param workspace_id string|nil
---@return table[]
function M.targets(payload, workspace, workspace_id)
  local targets = {}
  for _, session in ipairs(payload.sessions or {}) do
    if supported_agents[session.agent] and session.active_for_surface and session.surface_id and session.session_id then
      targets[#targets + 1] = {
        backend = "cmux",
        id = session.surface_id,
        agent = session.agent_display_name or session.agent,
        status = session.agent_lifecycle or "unknown",
        workspace = workspace,
        workspace_id = session.workspace_id or workspace_id,
        session_id = session.session_id,
      }
    end
  end
  return targets
end

---@param tree table
---@param workspace table
---@param callback fun(targets: table[]|nil, err: string|nil)
local function discover_terminal_targets(tree, workspace, callback)
  run_json(M.top_command(workspace.id), function(processes, err)
    if not processes then
      callback(nil, err)
      return
    end
    callback(M.terminal_targets(tree, workspace, processes), nil)
  end)
end

---@param callback fun(targets: table[]|nil, err: string|nil)
function M.discover(callback)
  if not vim.env.CMUX_SURFACE_ID or vim.env.CMUX_SURFACE_ID == "" then
    callback({}, nil)
    return
  end
  run_json({ "cmux", "tree", "--all", "--json" }, function(tree, tree_err)
    if not tree then
      callback(nil, tree_err)
      return
    end
    local workspace = M.workspace(tree)
    if not workspace then
      callback(nil, "cmux could not identify Neovim's workspace")
      return
    end
    run_json(M.sessions_command(workspace.id), function(payload, sessions_err)
      if not payload then
        callback(nil, sessions_err)
        return
      end
      local targets = M.targets(payload, workspace.title, workspace.id)
      if #targets == 0 then
        discover_terminal_targets(tree, workspace, callback)
        return
      end
      callback(targets, nil)
    end)
  end)
end

---@param target table
---@param callback fun(target: table|nil, err: string|nil)
function M.revalidate(target, callback)
  if vim.env.HERDR_ENV == "1" or not vim.env.CMUX_SURFACE_ID or vim.env.CMUX_SURFACE_ID == "" then
    callback(nil, "Neovim is no longer running exclusively inside cmux")
    return
  end
  run_json({ "cmux", "tree", "--all", "--json" }, function(tree, tree_err)
    if not tree then
      callback(nil, tree_err)
      return
    end
    local workspace = M.workspace(tree)
    if not workspace or not target.workspace_id or workspace.id ~= target.workspace_id then
      callback(nil, "cmux target is no longer in Neovim's workspace")
      return
    end

    if target.backend == "cmux_terminal" then
      if not surface_in_workspace(tree, workspace.id, target.id) then
        callback(nil, "cmux target is no longer in Neovim's workspace")
        return
      end
      discover_terminal_targets(tree, workspace, function(current_targets, err)
        if not current_targets then
          callback(nil, err)
          return
        end
        for _, current in ipairs(current_targets) do
          if current.id == target.id then
            if
              current.agent ~= target.agent
              or current.process_id ~= target.process_id
              or current.process_pgid ~= target.process_pgid
              or current.process_path ~= target.process_path
            then
              callback(nil, "cmux target agent changed before delivery")
              return
            end
            callback(current, nil)
            return
          end
        end
        callback(nil, "cmux target is no longer a recognized agent in Neovim's workspace")
      end)
      return
    end

    run_json(M.sessions_command(workspace.id), function(payload, sessions_err)
      if not payload then
        callback(nil, sessions_err)
        return
      end
      for _, current in ipairs(M.targets(payload, workspace.title, workspace.id)) do
        if current.id == target.id then
          if current.session_id ~= target.session_id then
            callback(nil, "cmux target agent changed before delivery")
            return
          end
          callback(current, nil)
          return
        end
      end
      callback(nil, "cmux target is no longer an active agent in Neovim's workspace")
    end)
  end)
end

---@param target table
---@param prompt string
---@param callback fun(ok: boolean, err: string|nil)
local function send_pasted_prompt(target, prompt, callback)
  if not target.workspace_id then
    callback(false, "cmux target has no workspace identity")
    return
  end
  local chunks = paste_chunks(prompt)
  local function paste(index, current_target)
    local command = { "cmux", "paste", "--workspace", current_target.workspace_id, "--surface", current_target.id }
    if index > 1 then
      command[#command + 1] = "--force"
    end
    if index == #chunks then
      command[#command + 1] = "--submit"
    end
    command[#command + 1] = "-"
    vim.system(command, { text = true, stdin = chunks[index] }, function(result)
      vim.schedule(function()
        if result.code ~= 0 then
          local message = vim.trim(result.stderr ~= "" and result.stderr or result.stdout)
          callback(false, message ~= "" and message or "cmux could not send the review comments")
          return
        end
        if index < #chunks then
          M.revalidate(target, function(validated, err)
            if not validated then
              callback(false, err)
              return
            end
            paste(index + 1, validated)
          end)
          return
        end
        callback(true, nil)
      end)
    end)
  end
  paste(1, target)
end

---@param target table
---@param items table[]
---@param callback fun(ok: boolean, err: string|nil)
function M.send_queue(target, items, callback)
  local prompt = client.queue_prompt(items)
  if target.backend == "cmux_terminal" or #prompt > CMUX_PASTE_CHUNK_BYTES then
    send_pasted_prompt(target, prompt, callback)
    return
  end
  vim.system(
    { "cmux", "agent", "message", target.id, "--from", "Neovim", "--json", "-" },
    { text = true, stdin = prompt },
    function(result)
      vim.schedule(function()
        if result.code ~= 0 then
          local message = vim.trim(result.stderr ~= "" and result.stderr or result.stdout)
          callback(false, message ~= "" and message or "cmux rejected the review comments")
          return
        end
        local decoded, response = pcall(vim.json.decode, result.stdout)
        if not decoded then
          callback(false, "cmux returned invalid JSON after sending the review comments")
          return
        end
        if response.recipient_has_agent ~= true then
          callback(false, "cmux target no longer has a live agent; queued comments were kept")
          return
        end
        callback(true, nil)
      end)
    end
  )
end

return M
