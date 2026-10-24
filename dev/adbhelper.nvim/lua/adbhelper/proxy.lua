-- Turn the device HTTP proxy on or off, matching bash `proxy` / `proxyoff`.
-- On: reverse host port 9900, then point the device proxy at 127.0.0.1:9900.
-- Off: clear the proxy (`:0`), then remove the reverse. Every connected device
-- is updated; there is no device picker.
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
---@param callback fun(ok: boolean, err: string)
local function run(cmd, callback)
  vim.system(cmd, { text = true }, function(result)
    vim.schedule(function()
      callback(outcome(result))
    end)
  end)
end

--- `adb -s SERIAL reverse tcp:9900 tcp:9900 && settings put global http_proxy 127.0.0.1:9900`
function M.on()
  each_device(function(serial, done)
    run({ "adb", "-s", serial, "reverse", PORT, PORT }, function(ok, err)
      if not ok then
        notify(serial .. ": reverse failed: " .. err, vim.log.levels.WARN)
        done()
        return
      end
      run({ "adb", "-s", serial, "shell", "settings", "put", "global", "http_proxy", PROXY }, function(ok2, err2)
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
    run({ "adb", "-s", serial, "shell", "settings", "put", "global", "http_proxy", ":0" }, function(ok, err)
      if not ok then
        notify(serial .. ": proxy off failed: " .. err, vim.log.levels.WARN)
        done()
        return
      end
      run({ "adb", "-s", serial, "reverse", "--remove", PORT }, function(ok2, err2)
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

return M
