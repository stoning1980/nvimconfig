local app = require("herdr.app")

local M = {
  id = "herdr_app",
  target_ids = { "herdr_app" },
  host_error = "Neovim is no longer running inside Herdr app",
}

function M.detect()
  return vim.env.HC_TERMINAL_ID ~= nil and vim.env.HC_TERMINAL_ID ~= ""
end

M.discover = app.discover
M.revalidate = app.revalidate
M.send_queue = app.send_queue

---@param target table
---@return string
function M.label(target)
  return string.format("[Herdr app] %s [%s] %s", target.agent, target.status, target.id)
end

return M
