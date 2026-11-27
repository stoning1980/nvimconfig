local root = vim.fn.getcwd()
package.path = root .. "/dev/adbhelper.nvim/lua/?.lua;" .. root .. "/dev/adbhelper.nvim/lua/?/init.lua;" .. package.path

local actions = require("adbhelper.actions")
local apps = require("adbhelper.apps")
local device = require("adbhelper.device")
local ui = require("adbhelper.ui")

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

test("screenshot review discovers Android and USB iOS devices", function()
  eq(
    capture.screenshot_devices(
      "List of devices attached\nandroid-123\tdevice\nandroid-offline\toffline\n",
      "ios-456\nios-789\n"
    ),
    {
      { text = "Android  ·  android-123", platform = "Android", device = "android-123" },
      { text = "iOS  ·  ios-456", platform = "iOS", device = "ios-456" },
      { text = "iOS  ·  ios-789", platform = "iOS", device = "ios-789" },
    },
    "only connected Android and USB iOS devices should be selectable"
  )
  eq(capture.ios_screenshot_command("/ios/python", "/tmp/IOSScreen.png"), {
    "/ios/python",
    "-m",
    "pymobiledevice3",
    "developer",
    "core-device",
    "screen-capture",
    "screenshot",
    "/tmp/IOSScreen.png",
  }, "iOS screenshots should mirror iosshot")
end)

test("screenshot review captures the picked Android device and returns its PNG", function()
  local original_system = vim.system
  local original_select = ui.select
  local original_notify = vim.notify
  local original_home = vim.env.HOME
  local original_date = os.date
  local temp_home = vim.fn.tempname()
  local commands = {}
  local captured
  vim.fn.mkdir(temp_home, "p")
  temp_home = assert(vim.uv.fs_realpath(temp_home))
  vim.env.HOME = temp_home
  os.date = function()
    return "1126-13h40m00s"
  end
  vim.notify = function() end
  ui.select = function(items, _, callback)
    eq(#items, 2, "combined picker should include Android and iOS")
    callback(items[1])
  end
  vim.system = function(argv, _, callback)
    commands[#commands + 1] = argv
    local result = { code = 0, stdout = "", stderr = "" }
    if argv[1] == "adb" and argv[2] == "devices" then
      result.stdout = "List of devices attached\nandroid-123\tdevice\n"
    elseif argv[1] == "idevice_id" then
      result.stdout = "ios-456\n"
    elseif argv[1] == "adb" and argv[4] == "pull" then
      vim.fn.writefile({ "fake PNG" }, argv[6])
    end
    if callback then
      callback(result)
    end
    return {}
  end

  local ok, err = xpcall(function()
    capture.screenshot_for_review(function(image)
      captured = image
    end)
    assert(
      vim.wait(500, function()
        return captured ~= nil
      end),
      "screenshot review workflow did not finish"
    )
    local output = temp_home .. "/Desktop/screen-shot/Screen_1126-13h40m00s.png"
    eq(captured, {
      platform = "Android",
      device = "android-123",
      path = output,
    }, "capture callback should expose the saved Android screenshot")
    eq(commands[3], {
      "adb",
      "-s",
      "android-123",
      "shell",
      "screencap",
      "-p",
      "/sdcard/screencap.png",
    }, "picked Android device should be captured")
  end, debug.traceback)

  vim.system = original_system
  ui.select = original_select
  vim.notify = original_notify
  vim.env.HOME = original_home
  os.date = original_date
  vim.fn.delete(temp_home, "rf")
  if not ok then
    error(err)
  end
end)

test("screenshot review keeps Android available when idevice_id is missing", function()
  local original_system = vim.system
  local original_notify = vim.notify
  local original_home = vim.env.HOME
  local original_date = os.date
  local temp_home = vim.fn.tempname()
  local captured
  vim.fn.mkdir(temp_home, "p")
  temp_home = assert(vim.uv.fs_realpath(temp_home))
  vim.env.HOME = temp_home
  os.date = function()
    return "1126-13h41m00s"
  end
  vim.notify = function() end
  vim.system = function(argv, _, callback)
    if argv[1] == "idevice_id" then
      error("ENOENT: idevice_id")
    end
    local result = { code = 0, stdout = "", stderr = "" }
    if argv[1] == "adb" and argv[2] == "devices" then
      result.stdout = "List of devices attached\nandroid-123\tdevice\n"
    elseif argv[1] == "adb" and argv[4] == "pull" then
      vim.fn.writefile({ "fake PNG" }, argv[6])
    end
    if callback then
      callback(result)
    end
    return {}
  end

  local ok, err = xpcall(function()
    capture.screenshot_for_review(function(image)
      captured = image
    end)
    assert(
      vim.wait(500, function()
        return captured ~= nil
      end),
      "Android capture should survive a missing iOS tool"
    )
    eq(captured.platform, "Android", "Android device should still be captured")
  end, debug.traceback)

  vim.system = original_system
  vim.notify = original_notify
  vim.env.HOME = original_home
  os.date = original_date
  vim.fn.delete(temp_home, "rf")
  if not ok then
    error(err)
  end
end)

test("screenshot review permits only one capture workflow at a time", function()
  local original_system = vim.system
  local original_notify = vim.notify
  local callbacks = {}
  local command_count = 0
  local no_device_count = 0
  vim.notify = function(message)
    if message:find("No connected", 1, true) then
      no_device_count = no_device_count + 1
    end
  end
  vim.system = function(_, _, callback)
    command_count = command_count + 1
    callbacks[#callbacks + 1] = callback
    return {}
  end

  local ok, err = xpcall(function()
    capture.screenshot_for_review(function() end)
    capture.screenshot_for_review(function() end)
    eq(command_count, 2, "second invocation must not start another device discovery")
    callbacks[1]({ code = 1, stdout = "", stderr = "no adb" })
    callbacks[2]({ code = 1, stdout = "", stderr = "no idevice_id" })
    assert(
      vim.wait(500, function()
        return no_device_count == 1
      end),
      "failed discovery did not finish"
    )
    capture.screenshot_for_review(function() end)
    eq(command_count, 4, "capture guard should clear after discovery failure")
    callbacks[3]({ code = 1, stdout = "", stderr = "no adb" })
    callbacks[4]({ code = 1, stdout = "", stderr = "no idevice_id" })
    vim.wait(50)
  end, debug.traceback)

  vim.system = original_system
  vim.notify = original_notify
  if not ok then
    error(err)
  end
end)

test("plugin maps F9, F18 and F19 while Herdr separates shifted keys", function()
  local spec = dofile(root .. "/lua/plugins/adb.lua")
  local commands = {
    "AdbScreenshotReview",
    "AdbDebugMenu",
    "AdbRelaunchApp",
    "AdbScreenshot",
    "AdbRecordScreen",
    "AdbLogcat",
    "AdbAppSettings",
    "AdbForceStop",
  }
  local reserved = {
    ["<F13>"] = true,
    ["<F14>"] = true,
    ["<F15>"] = true,
    ["<F16>"] = true,
    ["<F17>"] = true,
  }
  local expected_keys = {
    ["<F9>"] = "<cmd>AdbScreenshotReview<cr>",
    ["<F18>"] = "<cmd>AdbDebugMenu<cr>",
    ["<F19>"] = "<cmd>AdbScreenshot<cr>",
  }
  for key = 1, 7 do
    reserved["<S-F" .. key .. ">"] = true
  end
  local actual_keys = {}
  for _, key in ipairs(spec.keys) do
    assert(not reserved[key[1]], key[1] .. " must remain available for the original Shift behavior")
    if expected_keys[key[1]] then
      actual_keys[key[1]] = key[2]
    end
  end
  eq(actual_keys, expected_keys, "F9, F18 and F19 should expose the selected device actions")
  for _, name in ipairs(commands) do
    assert(vim.tbl_contains(spec.cmd, name), name .. " should lazy-load AdbHelper")
  end

  spec.config({}, {})
  for _, name in ipairs(commands) do
    assert(vim.fn.exists(":" .. name) == 2, name .. " should be registered when AdbHelper loads")
  end
end)

print("android_spec: ok")
