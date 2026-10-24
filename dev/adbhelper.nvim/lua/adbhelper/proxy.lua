-- Turn the device HTTP proxy on or off, and report its current state.
-- Matches bash `proxy` / `proxyoff`: on reverses tcp:9900 and sets
-- 127.0.0.1:9900; off writes `:0` and removes the reverse. Every connected
-- device is updated. Status only reads `http_proxy` and `adb reverse --list`.
local M = {}

local device = require("adbhelper.device")

local PROXY = "127.0.0.1:9900"
local PORT = "tcp:9900"

---@param msg string
---@param level integer|nil
local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = "AdbHelper" })
end

---@param result vim.SystemCompleted
---@return boolean ok, string err
local function outcome(result)
  local err = vim.trim((result.stderr or "") .. (result.stdout or ""))
  return result.code == 0, err
end

--- A proxy value of `:0`, `null`, or empty means the helper's proxy is off.
---@param raw string|nil
---@return string|nil
local function proxy_value(raw)
  local value = vim.trim(raw or "")
  if value == "" or value == "null" or value == ":0" then
    return nil
  end
  return value
end

---@param proxy string|nil
---@param reversed boolean
---@return string
local function describe(proxy, reversed)
  if proxy and reversed then
    return "proxy on (" .. proxy .. ")"
  end
  if proxy then
    return "proxy " .. proxy .. ", reverse " .. PORT .. " missing"
  end
  if reversed then
    return "proxy off, reverse " .. PORT .. " still set"
  end
  return "proxy off"
end

--- Run `fn` on each connected device, one at a time.
---@param fn fun(serial: string, done: fun())
local function each_device(fn)
  device.get_devices(function(devices)
    if #devices == 0 then
      notify("No adb device connected. Run 'adb devices' to check.", vim.log.levels.ERROR)
      return
    end
    local index = 1
    local function next_device()
      local serial = devices[index]
      if not serial then
        return
      end
      index = index + 1
      fn(serial, next_device)
    end
    next_device()
  end)
end

---@param cmd string[]
---@param callback fun(result: vim.SystemCompleted)
local function run(cmd, callback)
  vim.system(cmd, { text = true }, function(result)
    vim.schedule(function()
      callback(result)
    end)
  end)
end

--- `adb -s SERIAL reverse tcp:9900 tcp:9900 && settings put global http_proxy 127.0.0.1:9900`
function M.on()
  each_device(function(serial, done)
    run({ "adb", "-s", serial, "reverse", PORT, PORT }, function(result)
      local ok, err = outcome(result)
      if not ok then
        notify(serial .. ": reverse failed: " .. err, vim.log.levels.WARN)
        done()
        return
      end
      run({ "adb", "-s", serial, "shell", "settings", "put", "global", "http_proxy", PROXY }, function(put)
        local ok2, err2 = outcome(put)
        if ok2 then
          notify(serial .. ": proxy on")
        else
          notify(serial .. ": proxy failed: " .. err2, vim.log.levels.WARN)
        end
        done()
      end)
    end)
  end)
end

--- `settings put global http_proxy :0`, then `adb reverse --remove tcp:9900`.
function M.off()
  each_device(function(serial, done)
    run({ "adb", "-s", serial, "shell", "settings", "put", "global", "http_proxy", ":0" }, function(result)
      local ok, err = outcome(result)
      if not ok then
        notify(serial .. ": proxy off failed: " .. err, vim.log.levels.WARN)
        done()
        return
      end
      run({ "adb", "-s", serial, "reverse", "--remove", PORT }, function(removed)
        local ok2, err2 = outcome(removed)
        if ok2 then
          notify(serial .. ": proxy off")
        else
          -- The proxy is already cleared. A missing reverse is not a failure.
          notify(serial .. ": proxy off (" .. err2 .. ")", vim.log.levels.WARN)
        end
        done()
      end)
    end)
  end)
end

--- Read `http_proxy` and `adb reverse --list` for one device, then call `done`.
---@param serial string
---@param done fun()
local function report(serial, done)
  local pending = 2
  local proxy_raw, reverse_raw, failed
  local function finish(kind, result)
    if result.code ~= 0 then
      failed = vim.trim((result.stderr or "") .. (result.stdout or ""))
    elseif kind == "proxy" then
      proxy_raw = result.stdout
    else
      reverse_raw = result.stdout
    end
    pending = pending - 1
    if pending > 0 then
      return
    end
    if failed and proxy_raw == nil then
      notify(serial .. ": " .. (failed ~= "" and failed or "adb command failed"), vim.log.levels.WARN)
    else
      local reversed = (reverse_raw or ""):find(PORT, 1, true) ~= nil
      notify(serial .. ": " .. describe(proxy_value(proxy_raw), reversed))
    end
    done()
  end
  run({ "adb", "-s", serial, "shell", "settings", "get", "global", "http_proxy" }, function(result)
    finish("proxy", result)
  end)
  run({ "adb", "-s", serial, "reverse", "--list" }, function(result)
    finish("reverse", result)
  end)
end

--- Notify the proxy status of every connected device.
function M.status()
  each_device(report)
end

return M
