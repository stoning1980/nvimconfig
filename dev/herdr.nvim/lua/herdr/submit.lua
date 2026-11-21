local app = require("herdr.app")
local client = require("herdr.client")
local cmux = require("herdr.cmux")
local queue = require("herdr.queue")
local targets = require("herdr.targets")

local M = {}
local active = {}

---@param target table
---@return table|nil
local function transport_for(target)
  if target.backend == "cmux" or target.backend == "cmux_terminal" then
    return cmux
  end
  if target.backend == "herdr" then
    return {
      send_queue = function(_, items, callback)
        client.send_queue(target.source, items, callback)
      end,
    }
  end
  if target.backend == "herdr_app" then
    return app
  end
end

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
    selected_transport = selected_transport or transport_for(current_target)
    if not selected_transport then
      finish(false, "unknown review target backend: " .. tostring(current_target.backend))
      return
    end
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
