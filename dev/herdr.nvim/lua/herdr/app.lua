local client = require("herdr.client")

local M = {}

local function json_value(value)
  return value ~= vim.NIL and value or nil
end

---@param command string[]
---@param callback fun(payload: table|nil, err: string|nil)
local function run_json(command, callback)
  vim.system(command, { text = true }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        local message = vim.trim(result.stderr ~= "" and result.stderr or result.stdout)
        callback(nil, message ~= "" and message or "herdr-core command failed")
        return
      end
      local ok, payload = pcall(vim.json.decode, result.stdout)
      if not ok then
        callback(nil, "herdr-core returned invalid JSON")
        return
      end
      callback(payload, nil)
    end)
  end)
end

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

---@param terminal table
---@return string|nil
local function foreground_agent(terminal)
  local foreground = terminal.foreground or {}
  local name = (json_value(foreground.name) or ""):lower()
  local argv = {}
  for _, value in ipairs(foreground.argv or {}) do
    argv[#argv + 1] = value:lower()
  end
  local command = table.concat(argv, "\n")
  if command:find("/cursor-agent/", 1, true) then
    return "Cursor Agent"
  end
  if name == "claude" or command:match("/claude\n") or command:match("/claude$") then
    return "Claude Code"
  end
  if name == "codex" or command:match("/codex\n") or command:match("/codex$") then
    return "Codex"
  end
  if name == "kiro-cli" or command:match("/kiro%-cli\n") or command:match("/kiro%-cli$") then
    return "Kiro"
  end
end

---@param terminals table[]
---@param current_address string
---@param space_id string
---@param repo_root string
---@return table[]
function M.targets(terminals, current_address, space_id, repo_root)
  local result = {}
  for _, terminal in ipairs(terminals) do
    local labels = terminal.labels or {}
    local foreground = terminal.foreground or {}
    local fallback_agent = foreground_agent(terminal)
    local status = json_value(terminal.status)
    if
      terminal.address ~= current_address
      and terminal.state == "live"
      and (status or fallback_agent)
      and labels["herdr.space"] == space_id
      and belongs_to_repo(foreground.cwd or terminal.cwd, repo_root)
    then
      local agent = json_value(terminal.agent)
      if not status or not agent or agent == "bash" then
        agent = fallback_agent or agent
      end
      result[#result + 1] = {
        backend = "herdr_app",
        id = terminal.address,
        agent = agent or foreground.name or terminal.name or "agent",
        status = status or "paste + submit",
        space_id = space_id,
        terminal_created_ms = terminal.created_ms,
        foreground_pid = foreground.pid,
        source = terminal,
      }
    end
  end
  return result
end

---@param repo_root string
---@param callback fun(targets: table[]|nil, err: string|nil)
function M.discover(repo_root, callback)
  local current_address = vim.env.HC_TERMINAL_ID
  if not current_address or current_address == "" then
    callback(nil, "Neovim is not running inside Herdr app")
    return
  end
  run_json({ "hc", "get", current_address, "--json" }, function(current, current_err)
    if not current then
      callback(nil, current_err)
      return
    end
    local space_id = current.labels and current.labels["herdr.space"]
    if not space_id or space_id == "" then
      callback(nil, "Herdr app space identity is unavailable")
      return
    end
    run_json({ "hc", "ls", "--json", "--label", "herdr.space=" .. space_id }, function(list, list_err)
      if not list then
        callback(nil, list_err)
        return
      end
      local candidates = {}
      for _, summary in ipairs(list.terminals or {}) do
        if summary.address ~= current_address then
          candidates[#candidates + 1] = summary
        end
      end
      if #candidates == 0 then
        callback({}, nil)
        return
      end
      local terminals = {}
      local remaining = #candidates
      local done = false
      for _, summary in ipairs(candidates) do
        run_json({ "hc", "get", summary.address, "--json" }, function(terminal, terminal_err)
          if done then
            return
          end
          if not terminal then
            done = true
            callback(nil, terminal_err)
            return
          end
          terminal.agent = summary.agent
          terminals[#terminals + 1] = terminal
          remaining = remaining - 1
          if remaining == 0 then
            local result = M.targets(terminals, current_address, space_id, repo_root)
            for _, target in ipairs(result) do
              target.caller_id = current_address
              target.caller_created_ms = current.created_ms
            end
            done = true
            callback(result, nil)
          end
        end)
      end
    end)
  end)
end

---@param repo_root string
---@param target table
---@param callback fun(target: table|nil, err: string|nil)
function M.revalidate(repo_root, target, callback)
  if not vim.env.HC_TERMINAL_ID or vim.env.HC_TERMINAL_ID == "" or vim.env.HC_TERMINAL_ID ~= target.caller_id then
    callback(nil, "Neovim is no longer running inside the same Herdr app terminal")
    return
  end
  M.discover(repo_root, function(current_targets, err)
    if not current_targets then
      callback(nil, err)
      return
    end
    for _, current in ipairs(current_targets) do
      if current.id == target.id then
        if
          current.space_id ~= target.space_id
          or current.caller_created_ms ~= target.caller_created_ms
          or current.terminal_created_ms ~= target.terminal_created_ms
          or current.foreground_pid ~= target.foreground_pid
          or current.agent ~= target.agent
        then
          callback(nil, "Herdr app target agent changed before delivery")
          return
        end
        callback(current, nil)
        return
      end
    end
    callback(nil, "Herdr app target is no longer in this repository and space")
  end)
end

---@param target table
---@param items table[]
---@param callback fun(ok: boolean, err: string|nil)
function M.send_queue(target, items, callback)
  local prompt = client.queue_prompt(items)
  vim.system({ "hc", "send", "--json", target.id, prompt }, { text = true }, function(result)
    vim.schedule(function()
      if result.code == 0 then
        callback(true, nil)
        return
      end
      local message = vim.trim(result.stderr ~= "" and result.stderr or result.stdout)
      callback(false, message ~= "" and message or "Herdr app rejected the review comments")
    end)
  end)
end

return M
