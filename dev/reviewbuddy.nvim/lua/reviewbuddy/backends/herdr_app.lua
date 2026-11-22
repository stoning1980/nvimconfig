local app = require("reviewbuddy.app")

local M = {
  id = "herdr_app",
  target_ids = { "herdr_app" },
  host_error = "Neovim is no longer running inside Herdr app",
}

function M.detect()
  return vim.env.HC_TERMINAL_ID ~= nil and vim.env.HC_TERMINAL_ID ~= ""
end

function M.discover(repo_root, callback)
  app.discover(repo_root, callback)
end

function M.revalidate(repo_root, target, callback)
  app.revalidate(repo_root, target, callback)
end

function M.send_queue(target, items, callback)
  app.send_queue(target, items, callback)
end

---@param target table
---@return string
function M.label(target)
  return string.format("[Herdr app] %s [%s] %s", target.agent, target.status, target.id)
end

return M
