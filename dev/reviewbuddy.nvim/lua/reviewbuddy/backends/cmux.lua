local cmux = require("reviewbuddy.cmux")

local M = {
  id = "cmux",
  target_ids = { "cmux", "cmux_terminal" },
  host_error = "Neovim is no longer running exclusively inside cmux",
}

function M.detect()
  return vim.env.CMUX_SURFACE_ID ~= nil and vim.env.CMUX_SURFACE_ID ~= ""
end

function M.discover(repo_root, callback)
  cmux.discover(repo_root, callback)
end

function M.revalidate(repo_root, target, callback)
  cmux.revalidate(repo_root, target, callback)
end

function M.send_queue(target, items, callback)
  cmux.send_queue(target, items, callback, function(current, done)
    require("reviewbuddy.backends").revalidate(current.repo_root, current, done)
  end)
end

---@param target table
---@return string
function M.label(target)
  if target.backend == "cmux_terminal" then
    return string.format("[cmux terminal] %s [paste + submit] %s", target.agent, target.workspace)
  end
  return string.format("[cmux] %s [%s] %s", target.agent, target.status, target.workspace)
end

return M
