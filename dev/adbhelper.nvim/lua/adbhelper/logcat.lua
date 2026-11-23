local M = {}

local apps = require("adbhelper.apps")
local device = require("adbhelper.device")

local active_terminal
local starting = false

local function notify(message, level)
  vim.notify(message, level or vim.log.levels.INFO, { title = "AdbHelper" })
end

local function stop_active()
  if not active_terminal then
    return false
  end
  if active_terminal:buf_valid() then
    active_terminal:close()
    active_terminal = nil
    notify("Focused-app logcat stopped")
    return true
  end
  active_terminal = nil
  return false
end

--- Toggle a terminal running logcat for the selected foreground app process.
function M.toggle()
  if stop_active() then
    return
  end
  if starting then
    notify("Focused-app logcat is already starting")
    return
  end

  starting = true
  device.pick_device(function(serial)
    apps.pick_app(serial, { prefer_foreground = true }, function(pkg)
      vim.system({ "adb", "-s", serial, "shell", "pidof", "-s", pkg }, { text = true }, function(result)
        vim.schedule(function()
          starting = false
          local pid = vim.trim(result.stdout or "")
          if result.code ~= 0 or pid == "" then
            notify("App is not running: " .. pkg, vim.log.levels.WARN)
            return
          end
          local snacks = _G.Snacks
          if not (snacks and snacks.terminal) then
            local ok, loaded = pcall(require, "snacks")
            snacks = ok and loaded or nil
          end
          if not (snacks and snacks.terminal) then
            notify("Snacks terminal is unavailable", vim.log.levels.ERROR)
            return
          end
          active_terminal = snacks.terminal.open({
            "adb",
            "-s",
            serial,
            "logcat",
            "--pid=" .. pid,
            "-v",
            "threadtime",
          }, {
            interactive = false,
            win = { position = "bottom", title = " Logcat: " .. pkg .. " " },
          })
          notify("Focused-app logcat started: " .. pkg)
        end)
      end)
    end, function()
      starting = false
    end)
  end, function()
    starting = false
  end)
end

return M
