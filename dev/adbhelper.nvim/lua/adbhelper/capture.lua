local M = {}

local device = require("adbhelper.device")

local REMOTE_SCREENSHOT = "/sdcard/screencap.png"
local active_recording

local function notify(message, level)
  vim.notify(message, level or vim.log.levels.INFO, { title = "AdbHelper" })
end

local function output_dir()
  local dir = vim.fn.expand("~/Desktop/screen-shot")
  vim.fn.mkdir(dir, "p")
  return dir
end

local function output_path(prefix, extension)
  return ("%s/%s_%s.%s"):format(output_dir(), prefix, os.date("%m%d-%Hh%Mm%Ss"), extension)
end

---@param command string[]
---@param callback fun(result: vim.SystemCompleted)
local function run(command, callback)
  vim.system(command, { text = true }, function(result)
    vim.schedule(function()
      callback(result)
    end)
  end)
end

local function result_error(result)
  local message = vim.trim((result.stderr or "") .. (result.stdout or ""))
  return message ~= "" and message or "command failed"
end

local function copy_png(path)
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
  end)
end

--- Capture a screenshot, pull it to the baseline macOS directory, remove the
--- temporary device file, and copy the local PNG to the clipboard.
function M.screenshot()
  device.pick_device(function(serial)
    local path = output_path("Screen", "png")
    run({ "adb", "-s", serial, "shell", "screencap", "-p", REMOTE_SCREENSHOT }, function(captured)
      if captured.code ~= 0 then
        notify("Screenshot failed: " .. result_error(captured), vim.log.levels.WARN)
        return
      end
      run({ "adb", "-s", serial, "pull", REMOTE_SCREENSHOT, path }, function(pulled)
        run({ "adb", "-s", serial, "shell", "rm", REMOTE_SCREENSHOT }, function()
          if pulled.code == 0 then
            copy_png(path)
          else
            notify("Screenshot pull failed: " .. result_error(pulled), vim.log.levels.WARN)
          end
        end)
      end)
    end)
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
