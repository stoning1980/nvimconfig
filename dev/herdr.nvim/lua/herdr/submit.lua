local backends = require("herdr.backends")
local queue = require("herdr.queue")
local targets = require("herdr.targets")

local M = {}
local active = {}

---@param repo_root string
---@param target table
---@param callback fun(ok: boolean, err: string|nil)
---@param transport table|nil
function M.send(repo_root, target, callback, transport)
  if active[repo_root] then
    callback(false, "review comments are already being submitted for this repository")
    return
  end
  local items = queue.items(repo_root)
  if #items == 0 then
    callback(false, "no queued review comments for this repository")
    return
  end
  active[repo_root] = true

  local function finish(ok, err)
    active[repo_root] = nil
    if ok then
      queue.remove(repo_root, items)
    end
    callback(ok, err)
  end

  local function dispatch(current_target, selected_transport)
    selected_transport = selected_transport or backends
    selected_transport.send_queue(current_target, items, function(ok, err)
      finish(ok, err)
    end)
  end

  if transport then
    dispatch(target, transport)
    return
  end

  targets.revalidate(repo_root, target, function(current_target, err)
    if not current_target then
      finish(false, err)
      return
    end
    dispatch(current_target)
  end)
end

return M
