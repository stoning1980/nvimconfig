local M = {}

--- Parse `adb devices` output into a list of device serials.
---@param stdout string
---@return string[]
local function parse_devices(stdout)
  local devices = {}
  for line in stdout:gmatch("[^\r\n]+") do
    local serial = line:match("^(%S+)%s+device$")
    if serial and serial ~= "List" then
      devices[#devices + 1] = serial
    end
  end
  return devices
end

--- Asynchronously fetch connected device serials.
---@param callback fun(devices: string[])
function M.get_devices(callback)
  vim.system({ "adb", "devices" }, { text = true }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        vim.notify("adb failed: " .. (result.stderr or "unknown error"), vim.log.levels.ERROR, { title = "AdbHelper" })
        callback({})
        return
      end
      callback(parse_devices(result.stdout or ""))
    end)
  end)
end

--- Pick a device: auto-select if one, prompt if multiple, error if none.
---@param callback fun(serial: string)
function M.pick_device(callback)
  M.get_devices(function(devices)
    if #devices == 0 then
      vim.notify("No adb device connected. Run 'adb devices' to check.", vim.log.levels.ERROR, { title = "AdbHelper" })
      return
    end
    if #devices == 1 then
      callback(devices[1])
      return
    end
    vim.ui.select(devices, { prompt = "Pick Android device:" }, function(choice)
      if choice then
        callback(choice)
      end
    end)
  end)
end

return M
