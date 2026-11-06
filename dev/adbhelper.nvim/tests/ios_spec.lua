local root = vim.fn.getcwd()
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local ios = require("adbhelper.ios")
local adb = require("adbhelper")

local function eq(actual, expected, message)
  assert(vim.deep_equal(actual, expected), ("%s\nexpected: %s\nactual:   %s"):format(
    message,
    vim.inspect(expected),
    vim.inspect(actual)
  ))
end

local devices_json = vim.json.encode({
  result = {
    devices = {
      {
        identifier = "core-device-id",
        properties = {
          hardware = { reality = "simulated", udid = "SIM-UDID" },
          connection = { state = "connected" },
          state = { name = "iPhone 17 Pro" },
        },
      },
      {
        identifier = "physical-device-id",
        properties = {
          hardware = { reality = "physical", udid = "PHONE-UDID" },
          connection = { state = "connected" },
          state = { name = "Physical iPhone" },
        },
      },
      {
        identifier = "offline-simulator-id",
        properties = {
          hardware = { reality = "simulated", udid = "OFFLINE-UDID" },
          connection = { state = "disconnected" },
          state = { name = "Offline Simulator" },
        },
      },
    },
  },
})

eq(ios.parse_devices(devices_json), {
  { text = "iPhone 17 Pro  ·  SIM-UDID", value = "SIM-UDID" },
}, "only connected simulators should be selectable")

local invalid_devices, invalid_devices_error = ios.parse_devices("not json")
eq(invalid_devices, nil, "malformed device JSON should not look like an empty device list")
eq(invalid_devices_error, "Invalid JSON from Device Hub", "malformed device JSON should explain the failure")

local apps_json = vim.json.encode({
  result = {
    apps = {
      {
        name = "TikTok",
        bundleIdentifier = "com.zhiliaoapp.musically",
        version = "42.1.0",
        bundleVersion = "420100",
      },
      {
        name = "Missing bundle ID",
        version = "1.0",
      },
    },
  },
})

eq(ios.parse_apps(apps_json), {
  {
    text = "TikTok  ·  com.zhiliaoapp.musically  ·  42.1.0 (420100)",
    value = "com.zhiliaoapp.musically",
  },
}, "developer apps should expose their bundle IDs and versions")

eq(ios.build_command("launch", "SIM-UDID", "com.zhiliaoapp.musically"), {
  "xcrun",
  "devicectl",
  "device",
  "process",
  "launch",
  "--device",
  "SIM-UDID",
  "com.zhiliaoapp.musically",
}, "launch should use Device Hub's process launch operation")

eq(ios.build_command("relaunch", "SIM-UDID", "com.zhiliaoapp.musically"), {
  "xcrun",
  "devicectl",
  "device",
  "process",
  "launch",
  "--device",
  "SIM-UDID",
  "--terminate-existing",
  "com.zhiliaoapp.musically",
}, "relaunch should atomically terminate the existing process")

eq(ios.build_command("uninstall", "SIM-UDID", "com.zhiliaoapp.musically"), {
  "xcrun",
  "devicectl",
  "device",
  "uninstall",
  "app",
  "--device",
  "SIM-UDID",
  "com.zhiliaoapp.musically",
}, "uninstall should use Device Hub's app uninstall operation")

eq(
  ios.build_command("clear", "SIM-UDID", "com.zhiliaoapp.musically"),
  ios.build_command("uninstall", "SIM-UDID", "com.zhiliaoapp.musically"),
  "clear should remove the app container by uninstalling, matching the Bash helper"
)

eq(
  ios.command_error({ stderr = "", stdout = "Device Hub failed on stdout" }),
  "Device Hub failed on stdout",
  "command failures should use stdout when stderr is empty"
)
eq(ios.command_error({ stderr = "  ", stdout = "" }), "Device Hub command failed", "empty command output should fall back")

local menu_items = adb.menu_items("Proxy on · current", "Proxy off")
local menu_labels = vim.tbl_map(function(item)
  return item.text
end, menu_items)
eq(menu_labels, {
  "Android - A/B debug menu",
  "Android - Relaunch app",
  "Android - Kill TikTok family app",
  "Android - Clear TikTok family app",
  "Android - Proxy on · current",
  "Android - Proxy off",
  "iOS - Launch app",
  "iOS - Relaunch app",
  "iOS - Uninstall app",
  "iOS - Clear app data (uninstalls app)",
}, "the shared action menu should identify each platform")

print("ios_spec: ok")
