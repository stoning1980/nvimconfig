-- Thin wrapper around vim.loop TCP for a localhost listening server.

local uv = vim.loop or vim.uv

local M = {}

--- Start listening on host:port. Calls on_connection(client) for each accepted
--- TCP client (a uv_tcp_t handle already accepted).
---@param host string
---@param port integer
---@param on_connection fun(client: userdata)
---@return userdata|nil server
---@return string|nil err
function M.listen(host, port, on_connection)
  local server = uv.new_tcp()
  local ok, err = pcall(function()
    assert(server:bind(host, port))
    assert(server:listen(128, function(listen_err)
      if listen_err then
        return
      end
      local accept_ok = pcall(function()
        local client = uv.new_tcp()
        server:accept(client)
        on_connection(client)
      end)
      if not accept_ok then
        -- Ignore a single failed accept; the server keeps listening.
        return
      end
    end))
  end)
  if not ok then
    pcall(function()
      server:close()
    end)
    return nil, tostring(err)
  end
  return server
end

--- Find a free TCP port in [min, max] by attempting binds on 127.0.0.1.
---@param min integer
---@param max integer
---@return integer|nil port
function M.find_free_port(min, max)
  for _ = 1, 50 do
    local port = math.random(min, max)
    local probe = uv.new_tcp()
    local ok = pcall(function()
      assert(probe:bind("127.0.0.1", port))
    end)
    pcall(function()
      probe:close()
    end)
    if ok then
      return port
    end
  end
  return nil
end

return M
