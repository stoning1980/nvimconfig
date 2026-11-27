local M = {}

local device = require("adbhelper.device")
local ui = require("adbhelper.ui")

local REMOTE_SCREENSHOT = "/sdcard/screencap.png"
local active_recording
local screenshot_active = false

---@param android_stdout string
---@param ios_stdout string
---@return table[]
function M.screenshot_devices(android_stdout, ios_stdout)
  local items = {}
  for line in (android_stdout or ""):gmatch("[^\r\n]+") do
    local serial = line:match("^(%S+)%s+device$")
    if serial and serial ~= "List" then
      items[#items + 1] = { text = "Android  ·  " .. serial, platform = "Android", device = serial }
    end
  end
  for device_id in (ios_stdout or ""):gmatch("[^\r\n]+") do
    device_id = vim.trim(device_id)
    if device_id ~= "" then
      items[#items + 1] = { text = "iOS  ·  " .. device_id, platform = "iOS", device = device_id }
    end
  end
  return items
end

---@param python string
---@param path string
---@return string[]
function M.ios_screenshot_command(python, path)
  return {
    python,
    "-m",
    "pymobiledevice3",
    "developer",
    "core-device",
    "screen-capture",
    "screenshot",
    path,
  }
end

local function notify(message, level)
  vim.notify(message, level or vim.log.levels.INFO, { title = "AdbHelper" })
end

local function output_dir()
  local dir = vim.fn.expand("~/Desktop/screen-shot")
  vim.fn.mkdir(dir, "p")
  return dir
end

local function output_path(prefix, extension)
  local dir = output_dir()
  local stem = ("%s_%s"):format(prefix, os.date("%m%d-%Hh%Mm%Ss"))
  local path = ("%s/%s.%s"):format(dir, stem, extension)
  local index = 2
  while vim.uv.fs_stat(path) do
    path = ("%s/%s_%d.%s"):format(dir, stem, index, extension)
    index = index + 1
  end
  return path
end

---@param command string[]
---@param callback fun(result: vim.SystemCompleted)
---@param options? table
local function run(command, callback, options)
  options = vim.tbl_extend("force", { text = true }, options or {})
  local ok, process = pcall(vim.system, command, options, function(result)
    vim.schedule(function()
      callback(result)
    end)
  end)
  if not ok then
    vim.schedule(function()
      callback({ code = 127, stdout = "", stderr = tostring(process) })
    end)
    return nil
  end
  return process
end

local function result_error(result)
  local message = vim.trim((result.stderr or "") .. (result.stdout or ""))
  return message ~= "" and message or "command failed"
end

local function copy_png(path, callback)
  local script = table.concat({
    "on run argv",
    "set the clipboard to (read (POSIX file (item 1 of argv)) as «class PNGf»)",
    "end run",
  }, "\n")
  run({ "osascript", "-e", script, path }, function(result)
    if result.code == 0 then
      notify("Screenshot saved and copied: " .. path)
    else
      notify("Screenshot saved, but clipboard copy failed: " .. result_error(result), vim.log.levels.WARN)
    end
    if callback then
      callback()
    end
  end)
end

local function screenshot_python()
  if vim.env.IOS_RECORD_PYTHON and vim.env.IOS_RECORD_PYTHON ~= "" then
    return vim.env.IOS_RECORD_PYTHON
  end
  local venv_python = vim.fn.expand("~/work/tools/iosrecord-venv/bin/python")
  if vim.fn.executable(venv_python) == 1 then
    return venv_python
  end
  return "python3"
end

local function prepare_review_png(image, callback)
  local function copy()
    if vim.fn.executable("osascript") == 1 then
      copy_png(image.path, function()
        callback(image)
      end)
    else
      notify("Screenshot saved, but osascript is unavailable", vim.log.levels.WARN)
      callback(image)
    end
  end
  if vim.fn.executable("sips") ~= 1 then
    copy()
    return
  end
  run({ "sips", "-Z", "600", image.path }, function(result)
    if result.code ~= 0 then
      notify("Screenshot resize failed: " .. result_error(result), vim.log.levels.WARN)
      callback(nil)
      return
    end
    copy()
  end)
end

local function capture_android_screenshot(item, path, callback)
  run({ "adb", "-s", item.device, "shell", "screencap", "-p", REMOTE_SCREENSHOT }, function(captured)
    if captured.code ~= 0 then
      notify("Screenshot failed: " .. result_error(captured), vim.log.levels.WARN)
      callback(nil)
      return
    end
    run({ "adb", "-s", item.device, "pull", REMOTE_SCREENSHOT, path }, function(pulled)
      run({ "adb", "-s", item.device, "shell", "rm", REMOTE_SCREENSHOT }, function(removed)
        if pulled.code ~= 0 then
          notify("Screenshot pull failed: " .. result_error(pulled), vim.log.levels.WARN)
          callback(nil)
          return
        end
        if removed.code ~= 0 then
          notify("Screenshot cleanup failed: " .. result_error(removed), vim.log.levels.WARN)
          callback(nil)
          return
        end
        prepare_review_png({ platform = item.platform, device = item.device, path = path }, callback)
      end)
    end)
  end)
end

local function capture_ios_screenshot(item, path, callback)
  local python = screenshot_python()
  run(M.ios_screenshot_command(python, path), function(result)
    if result.code ~= 0 then
      notify("iOS screenshot failed: " .. result_error(result), vim.log.levels.WARN)
      callback(nil)
      return
    end
    local stat = vim.uv.fs_stat(path)
    if not stat or stat.size == 0 then
      notify("iOS screenshot did not create an image", vim.log.levels.WARN)
      callback(nil)
      return
    end
    prepare_review_png({ platform = item.platform, device = item.device, path = path }, callback)
  end, {
    env = { PYMOBILEDEVICE3_UDID = item.device },
  })
end

local function discover_screenshot_devices(callback)
  local pending = 2
  local android_stdout, ios_stdout = "", ""
  local function finish()
    pending = pending - 1
    if pending > 0 then
      return
    end
    callback(M.screenshot_devices(android_stdout, ios_stdout))
  end
  run({ "adb", "devices" }, function(result)
    android_stdout = result.code == 0 and (result.stdout or "") or ""
    finish()
  end)
  run({ "idevice_id", "-l" }, function(result)
    ios_stdout = result.code == 0 and (result.stdout or "") or ""
    finish()
  end)
end

--- Capture a selected Android or physical iOS device for ReviewBuddy.
---@param callback fun(image: { platform: string, device: string, path: string })
function M.screenshot_for_review(callback)
  if screenshot_active then
    notify("A device screenshot is already in progress")
    return
  end
  screenshot_active = true
  local function finish(image)
    screenshot_active = false
    if image then
      callback(image)
    end
  end
  discover_screenshot_devices(function(items)
    if #items == 0 then
      notify("No connected Android or USB iOS device", vim.log.levels.ERROR)
      finish(nil)
      return
    end
    local function capture(item)
      local prefix = item.platform == "iOS" and "IOSScreen" or "Screen"
      local path = output_path(prefix, "png")
      if item.platform == "iOS" then
        capture_ios_screenshot(item, path, finish)
      else
        capture_android_screenshot(item, path, finish)
      end
    end
    if #items == 1 then
      capture(items[1])
      return
    end
    ui.select(items, { title = "Pick screenshot device" }, function(item)
      if item then
        capture(item)
      else
        finish(nil)
      end
    end)
  end)
end

--- Capture a screenshot, pull it to the baseline macOS directory, remove the
--- temporary device file, and copy the local PNG to the clipboard.
function M.screenshot()
  if screenshot_active then
    notify("A device screenshot is already in progress")
    return
  end
  screenshot_active = true
  local function finish()
    screenshot_active = false
  end
  device.pick_device(function(serial)
    local path = output_path("Screen", "png")
    run({ "adb", "-s", serial, "shell", "screencap", "-p", REMOTE_SCREENSHOT }, function(captured)
      if captured.code ~= 0 then
        notify("Screenshot failed: " .. result_error(captured), vim.log.levels.WARN)
        finish()
        return
      end
      run({ "adb", "-s", serial, "pull", REMOTE_SCREENSHOT, path }, function(pulled)
        run({ "adb", "-s", serial, "shell", "rm", REMOTE_SCREENSHOT }, function()
          if pulled.code == 0 then
            copy_png(path, finish)
          else
            notify("Screenshot pull failed: " .. result_error(pulled), vim.log.levels.WARN)
            finish()
          end
        end)
      end)
    end)
  end, function()
    finish()
  end)
end

local function recording_pending_message(status)
  return status == "stopping" and "Screen recording is still stopping" or "Screen recording is already starting"
end

--- Start a direct-to-Mac scrcpy recording, or gracefully stop the active one.
function M.toggle_recording()
  if active_recording then
    if active_recording.status == "running" then
      active_recording.status = "stopping"
      active_recording.process:kill(2)
      notify("Stopping screen recording: " .. active_recording.path)
    else
      notify(recording_pending_message(active_recording.status))
    end
    return
  end

  local recording = { status = "selecting" }
  active_recording = recording
  device.pick_device(function(serial)
    if active_recording ~= recording then
      return
    end
    recording.status = "starting"
    local path = output_path("Record", "mp4")
    local process
    process = vim.system({ "scrcpy", "-s", serial, "--no-playback", "-r", path }, { text = true }, function(result)
      vim.schedule(function()
        if active_recording == recording then
          active_recording = nil
        end
        if result.code == 0 or result.signal == 2 then
          notify("Screen recording saved: " .. path)
        else
          notify("Screen recording failed: " .. result_error(result), vim.log.levels.WARN)
        end
      end)
    end)
    recording.status = "running"
    recording.process = process
    recording.path = path
    recording.serial = serial
    notify("Screen recording started: " .. path)
  end, function()
    if active_recording == recording then
      active_recording = nil
    end
  end)
end

return M
