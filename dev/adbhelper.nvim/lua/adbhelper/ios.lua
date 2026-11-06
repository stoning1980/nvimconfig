local M = {}

local ui = require("adbhelper.ui")

local function notify(message, level)
  vim.notify(message, level or vim.log.levels.INFO, { title = "iOS Device Hub" })
end

local function decode_result(json)
  local ok, decoded = pcall(vim.json.decode, json or "")
  if not ok or type(decoded) ~= "table" or type(decoded.result) ~= "table" then
    return nil, "Invalid JSON from Device Hub"
  end
  return decoded.result
end

---@param result { stderr?: string, stdout?: string }
---@return string
function M.command_error(result)
  local stderr = vim.trim(result.stderr or "")
  if stderr ~= "" then
    return stderr
  end
  local stdout = vim.trim(result.stdout or "")
  return stdout ~= "" and stdout or "Device Hub command failed"
end

---@param json string
---@return { text: string, value: string }[]?, string?
function M.parse_devices(json)
  local result, err = decode_result(json)
  if not result then
    return nil, err
  end
  if type(result.devices) ~= "table" then
    return nil, "Device Hub response did not contain a device list"
  end
  local items = {}
  for _, entry in ipairs(result.devices) do
    local properties = entry.properties or {}
    local hardware = properties.hardware or {}
    local connection = properties.connection or {}
    local state = properties.state or {}
    local identifier = hardware.udid or entry.identifier
    if hardware.reality == "simulated" and connection.state == "connected" and identifier then
      local name = state.name or identifier
      items[#items + 1] = { text = name .. "  ·  " .. identifier, value = identifier }
    end
  end
  return items
end

---@param json string
---@return { text: string, value: string }[]?, string?
function M.parse_apps(json)
  local result, err = decode_result(json)
  if not result then
    return nil, err
  end
  if type(result.apps) ~= "table" then
    return nil, "Device Hub response did not contain an app list"
  end
  local items = {}
  for _, app in ipairs(result.apps) do
    local bundle = app.bundleIdentifier
    if bundle then
      local name = app.name or bundle
      local version = app.version or "unknown"
      local build = app.bundleVersion and (" (" .. app.bundleVersion .. ")") or ""
      items[#items + 1] = {
        text = ("%s  ·  %s  ·  %s%s"):format(name, bundle, version, build),
        value = bundle,
      }
    end
  end
  return items
end

---@param action "launch"|"relaunch"|"uninstall"|"clear"
---@param device string
---@param bundle string
---@return string[]?
function M.build_command(action, device, bundle)
  if action == "launch" then
    return { "xcrun", "devicectl", "device", "process", "launch", "--device", device, bundle }
  elseif action == "relaunch" then
    return {
      "xcrun",
      "devicectl",
      "device",
      "process",
      "launch",
      "--device",
      device,
      "--terminate-existing",
      bundle,
    }
  elseif action == "uninstall" or action == "clear" then
    return { "xcrun", "devicectl", "device", "uninstall", "app", "--device", device, bundle }
  end
end

local function run_json(command, callback)
  vim.system(command, { text = true }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        notify(M.command_error(result), vim.log.levels.ERROR)
        return
      end
      callback(result.stdout or "")
    end)
  end)
end

local function choose(items, title, empty_message, callback)
  if #items == 0 then
    notify(empty_message, vim.log.levels.ERROR)
  elseif #items == 1 then
    callback(items[1].value)
  else
    ui.select(items, { title = title }, function(item)
      if item then
        callback(item.value)
      end
    end)
  end
end

local function pick_device(callback)
  if vim.fn.executable("xcrun") ~= 1 then
    notify("'xcrun' command not found. Install Xcode to use Device Hub.", vim.log.levels.ERROR)
    return
  end
  run_json({
    "xcrun",
    "devicectl",
    "--quiet",
    "list",
    "devices",
    "--json-output",
    "-",
    "--omit-deprecated-fields-in-json",
  }, function(json)
    local items, err = M.parse_devices(json)
    if not items then
      notify(err, vim.log.levels.ERROR)
      return
    end
    choose(items, "Pick iOS Simulator", "No connected Simulator in Device Hub.", callback)
  end)
end

local function pick_app(device, callback)
  run_json({
    "xcrun",
    "devicectl",
    "--quiet",
    "device",
    "info",
    "apps",
    "--device",
    device,
    "--json-output",
    "-",
    "--omit-deprecated-fields-in-json",
  }, function(json)
    local items, err = M.parse_apps(json)
    if not items then
      notify(err, vim.log.levels.ERROR)
      return
    end
    choose(items, "Pick iOS app", "No developer apps found on this Simulator.", callback)
  end)
end

---@param action "launch"|"relaunch"|"uninstall"|"clear"
function M.run(action)
  pick_device(function(device)
    pick_app(device, function(bundle)
      local command = M.build_command(action, device, bundle)
      if not command then
        notify("Unknown action: " .. tostring(action), vim.log.levels.ERROR)
        return
      end
      local verb = action == "clear" and "clearing (uninstalling)" or action
      notify(("%s %s ..."):format(verb:gsub("^%l", string.upper), bundle))
      vim.system(command, { text = true }, function(result)
        vim.schedule(function()
          if result.code ~= 0 then
            notify(M.command_error(result), vim.log.levels.ERROR)
          else
            notify(("%s complete for %s"):format(verb:gsub("^%l", string.upper), bundle))
          end
        end)
      end)
    end)
  end)
end

return M
