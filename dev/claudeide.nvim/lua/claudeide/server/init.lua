-- WebSocket server lifecycle and per-client message handling.

local tcp = require("claudeide.server.tcp")
local handshake = require("claudeide.server.handshake")
local frame = require("claudeide.server.frame")
local util = require("claudeide.util")

local M = {}

M.state = {
  server = nil, ---@type userdata|nil
  port = nil, ---@type integer|nil
  auth_token = nil, ---@type string|nil
  clients = {}, ---@type table<userdata, table>
  on_message = nil, ---@type fun(msg: table, client: table)|nil
}

-- Write raw bytes to a client, swallowing errors from a dead socket.
local function safe_write(client, data)
  if client.closed or not client.sock then
    return false
  end
  local ok = pcall(function()
    client.sock:write(data)
  end)
  return ok
end

local function client_send(client, tbl)
  if client.closed then
    return
  end
  local ok, json = pcall(util.json_encode, tbl)
  if not ok then
    util.error("failed to encode message: " .. tostring(json))
    return
  end
  safe_write(client, frame.text(json))
end

local function close_client(client)
  if client.closed then
    return
  end
  client.closed = true
  M.state.clients[client.sock] = nil
  pcall(function()
    client.sock:read_stop()
  end)
  pcall(function()
    client.sock:close()
  end)
end

-- Cap on a single accumulated message (50 MB) to avoid unbounded memory use
-- from a misbehaving or malicious client.
local MAX_MESSAGE_BYTES = 50 * 1024 * 1024

local function handle_frame(client, fr)
  if fr.opcode == frame.OPCODE.CLOSE then
    safe_write(client, frame.close())
    close_client(client)
    return
  elseif fr.opcode == frame.OPCODE.PING then
    safe_write(client, frame.pong(fr.payload))
    return
  elseif fr.opcode == frame.OPCODE.PONG then
    return
  end

  -- Text/continuation: accumulate until FIN.
  client.msg_buf = (client.msg_buf or "") .. fr.payload
  if #client.msg_buf > MAX_MESSAGE_BYTES then
    util.warn("incoming message exceeded size limit, dropping connection")
    close_client(client)
    return
  end
  if not fr.fin then
    return
  end
  local payload = client.msg_buf
  client.msg_buf = ""

  local ok, msg = util.json_decode(payload)
  if not ok then
    util.debug("received non-JSON payload, ignoring")
    return
  end
  if M.state.on_message then
    vim.schedule(function()
      if client.closed then
        return
      end
      local handler_ok, err = pcall(M.state.on_message, msg, client)
      if not handler_ok then
        util.error("message handler error: " .. tostring(err))
      end
    end)
  end
end

-- Cap on the HTTP upgrade header size before we give up on the handshake.
local MAX_HEADER_BYTES = 64 * 1024

local function on_data(client, chunk)
  client.buf = (client.buf or "") .. chunk

  if not client.handshaked then
    local req = handshake.parse_request(client.buf)
    if not req then
      if #client.buf > MAX_HEADER_BYTES then
        util.warn("oversized HTTP request, dropping connection")
        close_client(client)
      end
      return -- wait for the rest of the headers
    end
    local response, ok = handshake.response(req, M.state.auth_token)
    safe_write(client, response)
    if not ok then
      util.warn("rejected WebSocket connection (auth/upgrade failed)")
      close_client(client)
      return
    end
    client.handshaked = true
    -- Strip the consumed HTTP request from the buffer.
    local header_end = client.buf:find("\r\n\r\n", 1, true)
    client.buf = client.buf:sub(header_end + 4)
    util.info("Claude connected")
  end

  -- Parse as many complete frames as available.
  while true do
    local fr, rest = frame.decode(client.buf)
    if not fr then
      break
    end
    client.buf = rest
    handle_frame(client, fr)
  end
end

local function on_connection(sock)
  local client = { sock = sock, buf = "", handshaked = false, closed = false }
  client.send = function(tbl)
    client_send(client, tbl)
  end
  M.state.clients[sock] = client

  sock:read_start(function(err, chunk)
    if err then
      close_client(client)
      return
    end
    if not chunk then
      close_client(client)
      return
    end
    local ok, e = pcall(on_data, client, chunk)
    if not ok then
      util.error("error handling data: " .. tostring(e))
    end
  end)
end

--- Start the server.
---@param opts { auth_token: string, on_message: fun(msg: table, client: table), port_range?: integer[] }
---@return integer|nil port
---@return string|nil err
function M.start(opts)
  if M.state.server then
    return M.state.port
  end
  local range = opts.port_range or { 10000, 65535 }
  M.state.auth_token = opts.auth_token
  M.state.on_message = opts.on_message

  -- find_free_port + listen has an inherent TOCTOU race, so retry a few times.
  local last_err
  for _ = 1, 10 do
    local port = tcp.find_free_port(range[1], range[2])
    if not port then
      last_err = "no free port available"
      break
    end
    local server, err = tcp.listen("127.0.0.1", port, on_connection)
    if server then
      M.state.server = server
      M.state.port = port
      return port
    end
    last_err = err
  end

  M.state.auth_token = nil
  M.state.on_message = nil
  return nil, last_err or "failed to start server"
end

--- Send a notification/message to all connected clients.
---@param tbl table
function M.broadcast(tbl)
  for _, client in pairs(M.state.clients) do
    client_send(client, tbl)
  end
end

function M.is_running()
  return M.state.server ~= nil
end

function M.client_count()
  return vim.tbl_count(M.state.clients)
end

function M.stop()
  for _, client in pairs(M.state.clients) do
    safe_write(client, frame.close())
    close_client(client)
  end
  M.state.clients = {}
  if M.state.server then
    pcall(function()
      M.state.server:close()
    end)
  end
  M.state.server = nil
  M.state.port = nil
  M.state.auth_token = nil
  M.state.on_message = nil
end

return M
