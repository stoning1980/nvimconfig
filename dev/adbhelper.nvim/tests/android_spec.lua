local root = vim.fn.getcwd()
package.path = root .. "/dev/adbhelper.nvim/lua/?.lua;" .. root .. "/dev/adbhelper.nvim/lua/?/init.lua;" .. package.path

local actions = require("adbhelper.actions")
local apps = require("adbhelper.apps")
local device = require("adbhelper.device")

local function eq(actual, expected, message)
  assert(
    vim.deep_equal(actual, expected),
    ("%s\nexpected: %s\nactual:   %s"):format(message, vim.inspect(expected), vim.inspect(actual))
  )
end

local function test(name, fn)
  local ok, err = xpcall(fn, debug.traceback)
  if not ok then
    error(name .. "\n" .. err)
  end
end

local function action_command(action)
  local original_pick_device = device.pick_device
  local original_pick_app = apps.pick_app
  local original_system = vim.system
  local original_notify = vim.notify
  local picked
  local command
  device.pick_device = function(callback)
    callback("SERIAL-1")
  end
  apps.pick_app = function(serial, options, callback)
    picked = { serial = serial, options = options }
    callback("com.zhiliaoapp.musically")
  end
  vim.system = function(argv)
    command = argv
    return {}
  end
  vim.notify = function() end

  local ok, err = xpcall(function()
    actions.run(action)
  end, debug.traceback)

  device.pick_device = original_pick_device
  apps.pick_app = original_pick_app
  vim.system = original_system
  vim.notify = original_notify
  if not ok then
    error(err)
  end
  return picked, command
end

test("app settings prefers the focused TikTok-family app", function()
  local picked, command = action_command("settings")
  eq(picked, {
    serial = "SERIAL-1",
    options = { prefer_foreground = true },
  }, "app settings should use focused-app resolution")
  eq(command, {
    "adb",
    "-s",
    "SERIAL-1",
    "shell",
    "am",
    "start",
    "-a",
    "android.settings.APPLICATION_DETAILS_SETTINGS",
    "-d",
    "package:com.zhiliaoapp.musically",
  }, "app settings should open the selected package details")
end)

test("force-stop prefers the focused TikTok-family app", function()
  local picked, command = action_command("kill")
  eq(picked.options, { prefer_foreground = true }, "force-stop should use focused-app resolution")
  eq(command, {
    "adb",
    "-s",
    "SERIAL-1",
    "shell",
    "am",
    "force-stop",
    "com.zhiliaoapp.musically",
  }, "force-stop should target the selected package")
end)

local capture_ok, capture = pcall(require, "adbhelper.capture")
assert(capture_ok, "adbhelper.capture must provide screenshot and recording workflows")

test("screenshot saves locally, cleans up the device, and copies the PNG", function()
  local original_pick_device = device.pick_device
  local original_system = vim.system
  local original_notify = vim.notify
  local original_home = vim.env.HOME
  local original_date = os.date
  local temp_home = vim.fn.tempname()
  local commands = {}
  vim.fn.mkdir(temp_home, "p")
  temp_home = assert(vim.uv.fs_realpath(temp_home))
  vim.env.HOME = temp_home
  os.date = function()
    return "1122-21h13m14s"
  end
  device.pick_device = function(callback)
    callback("SERIAL-1")
  end
  vim.notify = function() end
  vim.system = function(argv, _, callback)
    commands[#commands + 1] = argv
    if callback then
      callback({ code = 0, stdout = "", stderr = "" })
    end
    return {}
  end

  local ok, err = xpcall(function()
    capture.screenshot()
    assert(
      vim.wait(500, function()
        return #commands == 4
      end),
      "screenshot workflow did not finish"
    )
    local output = temp_home .. "/Desktop/screen-shot/Screen_1122-21h13m14s.png"
    eq(commands[1], {
      "adb",
      "-s",
      "SERIAL-1",
      "shell",
      "screencap",
      "-p",
      "/sdcard/screencap.png",
    }, "screenshot should be captured on the selected device")
    eq(commands[2], {
      "adb",
      "-s",
      "SERIAL-1",
      "pull",
      "/sdcard/screencap.png",
      output,
    }, "screenshot should be pulled into the baseline directory")
    eq(commands[3], {
      "adb",
      "-s",
      "SERIAL-1",
      "shell",
      "rm",
      "/sdcard/screencap.png",
    }, "temporary device screenshot should be removed")
    eq(commands[4][1], "osascript", "screenshot should be copied with AppleScript")
    eq(commands[4][#commands[4]], output, "AppleScript should receive the saved PNG path as an argument")
  end, debug.traceback)

  device.pick_device = original_pick_device
  vim.system = original_system
  vim.notify = original_notify
  vim.env.HOME = original_home
  os.date = original_date
  vim.fn.delete(temp_home, "rf")
  if not ok then
    error(err)
  end
end)

test("screen recording starts once and stops on the second invocation", function()
  local original_pick_device = device.pick_device
  local original_system = vim.system
  local original_notify = vim.notify
  local original_home = vim.env.HOME
  local original_date = os.date
  local temp_home = vim.fn.tempname()
  local pick_count = 0
  local pending_pick
  local cancel_pick
  local command
  local killed
  local finish
  local finalized = false
  vim.fn.mkdir(temp_home, "p")
  temp_home = assert(vim.uv.fs_realpath(temp_home))
  vim.env.HOME = temp_home
  os.date = function()
    return "1122-21h14m15s"
  end
  device.pick_device = function(callback, on_cancel)
    pick_count = pick_count + 1
    pending_pick = callback
    cancel_pick = on_cancel
  end
  vim.notify = function(message)
    if message:find("saved", 1, true) then
      finalized = true
    end
  end
  vim.system = function(argv, _, callback)
    command = argv
    finish = callback
    return {
      kill = function(_, signal)
        killed = signal
      end,
    }
  end

  local ok, err = xpcall(function()
    capture.toggle_recording()
    capture.toggle_recording()
    eq(pick_count, 1, "a second press while choosing a device must not open another picker")
    pending_pick("SERIAL-1")
    capture.toggle_recording()
    capture.toggle_recording()
    eq(command, {
      "scrcpy",
      "-s",
      "SERIAL-1",
      "--no-playback",
      "-r",
      temp_home .. "/Desktop/screen-shot/Record_1122-21h14m15s.mp4",
    }, "recording should stream directly to the Mac")
    eq(pick_count, 1, "stopping should not ask for the device again")
    eq(killed, 2, "second invocation should gracefully interrupt scrcpy")
    finish({ code = 0, signal = 2, stdout = "", stderr = "" })
    assert(
      vim.wait(500, function()
        return finalized
      end),
      "recording process callback did not finalize"
    )
    capture.toggle_recording()
    eq(pick_count, 2, "a new recording may start only after scrcpy exits")
    cancel_pick()
  end, debug.traceback)

  device.pick_device = original_pick_device
  vim.system = original_system
  vim.notify = original_notify
  vim.env.HOME = original_home
  os.date = original_date
  vim.fn.delete(temp_home, "rf")
  if not ok then
    error(err)
  end
end)

local logcat_ok, logcat = pcall(require, "adbhelper.logcat")
assert(logcat_ok, "adbhelper.logcat must provide the focused-app log toggle")

test("logcat resolves the focused app once and closes on the second invocation", function()
  local original_pick_device = device.pick_device
  local original_pick_app = apps.pick_app
  local original_system = vim.system
  local original_snacks = _G.Snacks
  local original_notify = vim.notify
  local pick_count = 0
  local opened_command
  local closed = false
  device.pick_device = function(callback)
    pick_count = pick_count + 1
    callback("SERIAL-1")
  end
  apps.pick_app = function(_, options, callback)
    eq(options, { prefer_foreground = true }, "logcat should use focused-app resolution")
    callback("com.zhiliaoapp.musically")
  end
  vim.system = function(argv, _, callback)
    eq(argv, {
      "adb",
      "-s",
      "SERIAL-1",
      "shell",
      "pidof",
      "-s",
      "com.zhiliaoapp.musically",
    }, "logcat should resolve the selected app process")
    callback({ code = 0, stdout = "4242\n", stderr = "" })
    return {}
  end
  vim.notify = function() end
  _G.Snacks = {
    terminal = {
      open = function(command)
        opened_command = command
        return {
          buf_valid = function()
            return not closed
          end,
          close = function()
            closed = true
          end,
        }
      end,
    },
  }

  local ok, err = xpcall(function()
    logcat.toggle()
    assert(
      vim.wait(500, function()
        return opened_command ~= nil
      end),
      "logcat terminal did not open"
    )
    eq(opened_command, {
      "adb",
      "-s",
      "SERIAL-1",
      "logcat",
      "--pid=4242",
      "-v",
      "threadtime",
    }, "logcat should filter by the selected app process")
    logcat.toggle()
    eq(closed, true, "second invocation should close the active logcat terminal")
    eq(pick_count, 1, "stopping logcat should not ask for the device again")
  end, debug.traceback)

  device.pick_device = original_pick_device
  apps.pick_app = original_pick_app
  vim.system = original_system
  vim.notify = original_notify
  _G.Snacks = original_snacks
  if not ok then
    error(err)
  end
end)

test("logcat opens only one device picker while startup is pending", function()
  local original_pick_device = device.pick_device
  local original_notify = vim.notify
  local pick_count = 0
  local cancel_pick
  device.pick_device = function(_, on_cancel)
    pick_count = pick_count + 1
    cancel_pick = on_cancel
  end
  vim.notify = function() end

  local ok, err = xpcall(function()
    logcat.toggle()
    logcat.toggle()
    eq(pick_count, 1, "repeated logcat starts must share one pending picker")
    cancel_pick()
    logcat.toggle()
    eq(pick_count, 2, "canceling the picker should release the startup guard")
    cancel_pick()
  end, debug.traceback)

  device.pick_device = original_pick_device
  vim.notify = original_notify
  if not ok then
    error(err)
  end
end)

test("plugin exposes all Android commands through F13-F19", function()
  local spec = dofile(root .. "/lua/plugins/adb.lua")
  local expected = {
    ["<F13>"] = "<cmd>AdbDebugMenu<cr>",
    ["<F14>"] = "<cmd>AdbRelaunchApp<cr>",
    ["<F15>"] = "<cmd>AdbScreenshot<cr>",
    ["<F16>"] = "<cmd>AdbRecordScreen<cr>",
    ["<F17>"] = "<cmd>AdbLogcat<cr>",
    ["<F18>"] = "<cmd>AdbAppSettings<cr>",
    ["<F19>"] = "<cmd>AdbForceStop<cr>",
  }
  local shifted = {
    ["<S-F1>"] = true,
    ["<S-F2>"] = true,
    ["<S-F3>"] = true,
    ["<S-F4>"] = true,
    ["<S-F5>"] = true,
    ["<S-F6>"] = true,
    ["<S-F7>"] = true,
  }
  local actual = {}
  for _, key in ipairs(spec.keys) do
    assert(not shifted[key[1]], key[1] .. " must retain its non-Android behavior")
    if expected[key[1]] then
      actual[key[1]] = key[2]
      eq(key.mode, "n", key[1] .. " should be Normal-mode only")
    end
  end
  eq(actual, expected, "all seven physical function keys should invoke their Android commands")
  for _, command in pairs(expected) do
    local name = command:match("<cmd>(.-)<cr>")
    assert(vim.tbl_contains(spec.cmd, name), name .. " should lazy-load AdbHelper")
  end

  spec.config({}, {})
  for _, command in pairs(expected) do
    local name = command:match("<cmd>(.-)<cr>")
    assert(vim.fn.exists(":" .. name) == 2, name .. " should be registered when AdbHelper loads")
  end
end)

print("android_spec: ok")
