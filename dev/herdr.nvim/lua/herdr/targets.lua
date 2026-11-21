local backends = require("herdr.backends")
local herdr = require("herdr.backends.herdr")

local M = {}

---@param agents table[]
---@return table[]
function M.herdr(agents)
  return herdr.targets(agents)
end

---@param target table
---@return string
function M.label(target)
  return backends.label(target)
end

---@param repo_root string
---@param callback fun(targets: table[]|nil, err: string|nil)
function M.discover(repo_root, callback)
  backends.discover(repo_root, callback)
end

---@param repo_root string
---@param target table
---@param callback fun(target: table|nil, err: string|nil)
function M.revalidate(repo_root, target, callback)
  backends.revalidate(repo_root, target, callback)
end

return M
