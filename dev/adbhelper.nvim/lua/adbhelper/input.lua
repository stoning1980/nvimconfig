local M = {}

-- Android keyevent codes for characters that can't be safely passed through
-- `adb shell input text`.
local KEYEVENT_MAP = {
  [" "] = "62",
  ["@"] = "77",
  ["#"] = "18",
  ["*"] = "17",
  ["+"] = "81",
  ["="] = "70",
  ["("] = "162",
  [")"] = "163",
  ["'"] = "75",
  [";"] = "74",
  ["\\"] = "73",
  ["\t"] = "61",
  ["\n"] = "66",
}

-- Characters safe to pass directly to `adb shell input text` without escaping.
-- Alphanumerics plus a small set of punctuation that adb handles unquoted.
local SAFE_PATTERN = "^[%w%-_.,/]$"

--- Classify a character as "safe" (input text), "keyevent", or "escaped".
---@param ch string single character
---@return "safe"|"keyevent"|"escaped"
local function classify(ch)
  if KEYEVENT_MAP[ch] then
    return "keyevent"
  end
  if ch:match(SAFE_PATTERN) then
    return "safe"
  end
  return "escaped"
end

--- Build a list of adb commands from the input text.
--- Consecutive safe characters are batched into one `input text` call.
---@param serial string
---@param text string
---@return string[][] list of argv tables
local function build_commands(serial, text)
  local cmds = {}
  local safe_buf = {}

  local function flush_safe()
    if #safe_buf > 0 then
      local chunk = table.concat(safe_buf)
      cmds[#cmds + 1] = { "adb", "-s", serial, "shell", "input", "text", chunk }
      safe_buf = {}
    end
  end

  for i = 1, #text do
    local ch = text:sub(i, i)
    local kind = classify(ch)

    if kind == "safe" then
      safe_buf[#safe_buf + 1] = ch
    elseif kind == "keyevent" then
      flush_safe()
      cmds[#cmds + 1] = { "adb", "-s", serial, "shell", "input", "keyevent", KEYEVENT_MAP[ch] }
    else -- escaped: wrap in single quotes for the remote shell
      flush_safe()
      -- Escape single quotes within the character for the shell:
      -- replace ' with '\'' (end quote, escaped quote, start quote)
      local escaped = ch:gsub("'", "'\\''")
      cmds[#cmds + 1] = { "adb", "-s", serial, "shell", "input", "text", "'" .. escaped .. "'" }
    end
  end
  flush_safe()
  return cmds
end

--- Run a list of commands sequentially (each waits for the prior).
---@param cmds string[][] list of argv tables
---@param idx number current index
---@param on_done fun()
local function run_sequential(cmds, idx, on_done)
  if idx > #cmds then
    if on_done then
      on_done()
    end
    return
  end
  vim.system(cmds[idx], { text = true }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        vim.notify("adb command failed: " .. (result.stderr or "unknown"), vim.log.levels.WARN, { title = "AdbHelper" })
      end
      run_sequential(cmds, idx + 1, on_done)
    end)
  end)
end

--- Send text to a device, handling special characters.
---@param serial string device serial
---@param text string text to send
---@param on_done? fun() called when all commands finish
function M.send_text(serial, text, on_done)
  if text == "" then
    vim.notify("No text to send", vim.log.levels.WARN, { title = "AdbHelper" })
    return
  end
  local cmds = build_commands(serial, text)
  if #cmds == 0 then
    vim.notify("No sendable characters in selection", vim.log.levels.WARN, { title = "AdbHelper" })
    return
  end
  run_sequential(cmds, 1, on_done)
end

return M
