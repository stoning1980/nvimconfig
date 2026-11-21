local adapters = {
  require("herdr.backends.herdr"),
  require("herdr.backends.herdr_app"),
  require("herdr.backends.cmux"),
}

local required_fields = {
  "id",
  "target_ids",
  "detect",
  "discover",
  "revalidate",
  "send_queue",
  "label",
  "host_error",
}

local by_target = {}
for _, adapter in ipairs(adapters) do
  for _, field in ipairs(required_fields) do
    assert(adapter[field] ~= nil, adapter.id .. " backend is missing " .. field)
  end
  for _, target_id in ipairs(adapter.target_ids) do
    assert(not by_target[target_id], "duplicate review target backend: " .. target_id)
    by_target[target_id] = adapter
  end
end

local M = {}

---@return table[]
function M.list()
  return adapters
end

---@return table|nil
function M.active()
  for _, adapter in ipairs(adapters) do
    if adapter.detect() then
      return adapter
    end
  end
end

---@param target table
---@return table|nil
function M.owner(target)
  return target and by_target[target.backend] or nil
end

---@param repo_root string
---@param callback fun(targets: table[]|nil, err: string|nil)
function M.discover(repo_root, callback)
  local adapter = M.active()
  if not adapter then
    callback(nil, "Neovim is not running inside Herdr, Herdr app, or cmux")
    return
  end
  adapter.discover(repo_root, callback)
end

---@param repo_root string
---@param target table
---@param callback fun(target: table|nil, err: string|nil)
function M.revalidate(repo_root, target, callback)
  local owner = M.owner(target)
  if not owner then
    callback(nil, "unknown review target backend: " .. tostring(target and target.backend))
    return
  end
  if M.active() ~= owner then
    callback(nil, owner.host_error)
    return
  end
  owner.revalidate(repo_root, target, callback)
end

---@param target table
---@param items table[]
---@param callback fun(ok: boolean, err: string|nil)
function M.send_queue(target, items, callback)
  local owner = M.owner(target)
  if not owner then
    callback(false, "unknown review target backend: " .. tostring(target and target.backend))
    return
  end
  owner.send_queue(target, items, callback)
end

---@param target table
---@return string
function M.label(target)
  local owner = M.owner(target)
  if not owner then
    return "[unknown] " .. tostring(target and target.backend)
  end
  return owner.label(target)
end

return M
