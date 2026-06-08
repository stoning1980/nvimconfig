-- HTTP -> WebSocket upgrade handshake handling.

local crypto = require("claudeide.crypto")

local M = {}

--- Parse an HTTP request head into method, path and lowercased headers.
---@param data string
---@return table|nil { method, path, headers } ; nil if headers not complete yet
function M.parse_request(data)
  local header_end = data:find("\r\n\r\n", 1, true)
  if not header_end then
    return nil
  end
  local head = data:sub(1, header_end - 1)
  local lines = vim.split(head, "\r\n", { plain = true })
  local request_line = table.remove(lines, 1) or ""
  local method, path = request_line:match("^(%S+)%s+(%S+)")
  local headers = {}
  for _, line in ipairs(lines) do
    local name, value = line:match("^([^:]+):%s*(.*)$")
    if name then
      headers[name:lower()] = value
    end
  end
  return { method = method, path = path, headers = headers }
end

--- Build the 101 Switching Protocols response, or an error response.
---@param request table parsed request
---@param auth_token string expected auth token
---@return string response
---@return boolean ok true if this is a valid upgrade to accept
function M.response(request, auth_token)
  local headers = request.headers or {}
  local key = headers["sec-websocket-key"]
  local upgrade = (headers["upgrade"] or ""):lower()

  if upgrade ~= "websocket" or not key then
    return "HTTP/1.1 400 Bad Request\r\n\r\nExpected WebSocket upgrade", false
  end

  local provided = headers["x-claude-code-ide-authorization"]
  if not provided or provided ~= auth_token then
    return "HTTP/1.1 401 Unauthorized\r\n\r\nInvalid auth token", false
  end

  local accept = crypto.websocket_accept(key)
  local response = table.concat({
    "HTTP/1.1 101 Switching Protocols",
    "Upgrade: websocket",
    "Connection: Upgrade",
    "Sec-WebSocket-Accept: " .. accept,
    "",
    "",
  }, "\r\n")
  return response, true
end

return M
