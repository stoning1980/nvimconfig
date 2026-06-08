-- JSON-RPC 2.0 / MCP message dispatch.

local tools = require("claudeide.tools")
local util = require("claudeide.util")

local M = {}

M.protocol_version = "2025-03-26"
M.server_info = { name = "claudeide.nvim", version = "0.1.0" }

local function send_result(client, id, result)
  client.send({ jsonrpc = "2.0", id = id, result = result })
end

local function send_error(client, id, code, message)
  client.send({ jsonrpc = "2.0", id = id, error = { code = code, message = message } })
end

--- Handle one incoming decoded message. Runs in a scheduled (main-loop) context.
---@param msg table
---@param client table
function M.handle(msg, client)
  local method = msg.method
  local id = msg.id

  -- Responses from the client to our notifications: nothing to do.
  if method == nil then
    return
  end

  if method == "initialize" then
    send_result(client, id, {
      protocolVersion = M.protocol_version,
      capabilities = { tools = vim.empty_dict() },
      serverInfo = M.server_info,
    })
    return
  end

  if method == "notifications/initialized" or method:match("^notifications/") then
    return
  end

  if method == "tools/list" then
    send_result(client, id, { tools = tools.list() })
    return
  end

  if method == "tools/call" then
    local params = msg.params or {}
    local name = params.name
    local args = params.arguments or {}
    if not name or not tools.exists(name) then
      send_error(client, id, -32601, "Unknown tool: " .. tostring(name))
      return
    end
    local answered = false
    local respond = function(result)
      if answered then
        return
      end
      answered = true
      send_result(client, id, result)
    end
    local ok, result = pcall(tools.call, name, args, respond)
    if not ok then
      util.error("tool '" .. name .. "' error: " .. tostring(result))
      respond({
        content = { { type = "text", text = "Error: " .. tostring(result) } },
        isError = true,
      })
      return
    end
    -- A non-nil return means the tool answered synchronously; otherwise the
    -- tool is responsible for calling respond() later (blocking tools).
    if result ~= nil then
      respond(result)
    end
    return
  end

  -- Unknown method: only error if a response was expected.
  if id ~= nil then
    send_error(client, id, -32601, "Method not found: " .. method)
  end
end

return M
