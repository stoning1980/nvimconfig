local M = {}

local ui = require("adbhelper.ui")

-- TikTok-family packages, mirroring `_apk_black_list` in 50-adb.sh.
M.TIKTOK_PACKAGES = {
  "com.ss.android.ugc.tiktok.pro",
  "com.ss.android.ugc.trill",
  "com.zhiliaoapp.musically",
  "com.tiktok.lite.go",
  "com.zhiliaoapp.musically.go",
}

local TIKTOK_SET = {}
for _, pkg in ipairs(M.TIKTOK_PACKAGES) do
  TIKTOK_SET[pkg] = true
end

--- Fetch installed TikTok-family packages on a device (async).
---@param serial string device serial
---@param callback fun(apps: string[])
function M.get_apps(serial, callback)
  vim.system({ "adb", "-s", serial, "shell", "pm", "list", "packages", "-3" }, { text = true }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        vim.notify("adb failed: " .. (result.stderr or "unknown error"), vim.log.levels.ERROR, { title = "AdbHelper" })
        callback({})
        return
      end
      local apps = {}
      for line in (result.stdout or ""):gmatch("[^\r\n]+") do
        local pkg = line:match("^package:(%S+)")
        if pkg and TIKTOK_SET[pkg] then
          apps[#apps + 1] = pkg
        end
      end
      callback(apps)
    end)
  end)
end

--- Detect the current foreground (on-screen) package (async, best-effort).
--- Returns nil if it can't be determined.
---@param serial string device serial
---@param callback fun(pkg: string|nil)
function M.get_foreground_app(serial, callback)
  vim.system({ "adb", "-s", serial, "shell", "dumpsys", "activity", "activities" }, { text = true }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        callback(nil)
        return
      end
      local out = result.stdout or ""
      -- Prefer the resumed/focused activity keys, which name the app on screen
      -- as `<package>/<activity>`. Keys vary across Android versions.
      for _, key in ipairs({ "topResumedActivity", "mResumedActivity", "mCurrentFocus", "mFocusedApp" }) do
        for line in out:gmatch("[^\r\n]+") do
          if line:find(key, 1, true) then
            local pkg = line:match("([%w_%.]+)/[%w_%.%$]+")
            if pkg then
              callback(pkg)
              return
            end
          end
        end
      end
      callback(nil)
    end)
  end)
end

--- Prompt to pick from installed TikTok-family apps: auto-select if one, show a
--- selection screen if multiple, error if none installed.
---@param serial string device serial
---@param callback fun(pkg: string)
local function pick_installed(serial, callback)
  M.get_apps(serial, function(apps)
    if #apps == 0 then
      vim.notify("No TikTok-family app installed on device.", vim.log.levels.ERROR, { title = "AdbHelper" })
      return
    end
    if #apps == 1 then
      callback(apps[1])
      return
    end
    local items = {}
    for _, pkg in ipairs(apps) do
      items[#items + 1] = { text = pkg, value = pkg }
    end
    ui.select(items, { title = "Pick TikTok-family app" }, function(item)
      if item then
        callback(item.value)
      end
    end)
  end)
end

--- Resolve the target TikTok-family app.
--- When `opts.prefer_foreground` is set, use the on-screen app directly (no
--- picker) if it is a TikTok-family app; otherwise fall back to the picker.
---@param serial string device serial
---@param opts? { prefer_foreground?: boolean }
---@param callback fun(pkg: string)
function M.pick_app(serial, opts, callback)
  opts = opts or {}
  if not opts.prefer_foreground then
    pick_installed(serial, callback)
    return
  end
  M.get_foreground_app(serial, function(fg)
    if fg and TIKTOK_SET[fg] then
      vim.notify("Using foreground app: " .. fg, vim.log.levels.INFO, { title = "AdbHelper" })
      callback(fg)
      return
    end
    pick_installed(serial, callback)
  end)
end

--- Whether a package is a "go" (lite) variant, which uses different launch
--- activities than the full app.
---@param pkg string
---@return boolean
function M.is_go(pkg)
  return pkg:match("%.go$") ~= nil
end

return M
