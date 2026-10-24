local M = {}

local device = require("adbhelper.device")
local apps = require("adbhelper.apps")

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = "AdbHelper" })
end

--- Run a single adb argv, reporting failures.
---@param cmd string[] argv
---@param on_done? fun()
local function run(cmd, on_done)
  vim.system(cmd, { text = true }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        notify("adb command failed: " .. (result.stderr or "unknown"), vim.log.levels.WARN)
      end
      if on_done then
        on_done()
      end
    end)
  end)
end

local handlers = {}

--- Launch the A/B (assistant) debug screen for the app. Mirrors `droidab`.
function handlers.ab(serial, pkg)
  local activity = apps.is_go(pkg) and "com.ss.android.ugc.aweme.local.test.impl.page.AssistantActivity"
    or "com.bytedance.ies.assistant.AssistantActivity"
  notify("Opening A/B debug menu for " .. pkg .. " ...")
  run({ "adb", "-s", serial, "shell", "am", "start", "-n", pkg .. "/" .. activity })
end

--- Force-stop the app. Mirrors `droidkill`.
function handlers.kill(serial, pkg)
  notify("Killing " .. pkg .. " ...")
  run({ "adb", "-s", serial, "shell", "am", "force-stop", pkg }, function()
    notify(pkg .. " stopped")
  end)
end

--- Clear the app's data. Mirrors `droidclear`.
function handlers.clear(serial, pkg)
  notify("Clearing data for " .. pkg .. " ...")
  run({ "adb", "-s", serial, "shell", "pm", "clear", pkg }, function()
    notify(pkg .. " cleared")
  end)
end

--- Force-stop, then relaunch the app's launcher activity. Mirrors `droidre`.
function handlers.relaunch(serial, pkg)
  local activity = apps.is_go(pkg) and "com.ss.android.ugc.aweme.main.homepage.MainActivity"
    or "com.ss.android.ugc.aweme.splash.SplashActivity"
  notify("Relaunching " .. pkg .. " ...")
  run({ "adb", "-s", serial, "shell", "am", "force-stop", pkg }, function()
    -- Give the process time to fully die before starting again (shell used `sleep 2`).
    vim.defer_fn(function()
      run({
        "adb",
        "-s",
        serial,
        "shell",
        "am",
        "start",
        "-n",
        pkg .. "/" .. activity,
        "-a",
        "android.intent.action.MAIN",
        "-c",
        "android.intent.category.LAUNCHER",
        "--splashscreen-show-icon",
      }, function()
        notify(pkg .. " relaunched")
      end)
    end, 2000)
  end)
end

-- A/B debug and relaunch target whatever is on screen when possible, so they
-- skip the app picker if the foreground app is a TikTok-family app.
local PREFER_FOREGROUND = { ab = true, relaunch = true }

--- Run a named action: pick device -> resolve TikTok-family app -> execute.
---@param action "ab"|"kill"|"clear"|"relaunch"
function M.run(action)
  local handler = handlers[action]
  if not handler then
    notify("Unknown action: " .. tostring(action), vim.log.levels.ERROR)
    return
  end
  device.pick_device(function(serial)
    apps.pick_app(serial, { prefer_foreground = PREFER_FOREGROUND[action] }, function(pkg)
      handler(serial, pkg)
    end)
  end)
end

return M
