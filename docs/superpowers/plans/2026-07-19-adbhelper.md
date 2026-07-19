# AdbHelper.nvim Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Send visually selected text from Neovim to an Android device via adb, with device picker and symbol support.

**Architecture:** Three-module plugin under `dev/adbhelper.nvim/`: `device.lua` handles async device discovery and selection via `vim.ui.select`; `input.lua` handles text segmentation (safe chars batched into `input text`, symbols via `input keyevent`); `init.lua` wires them together as a visual-range command. Plugin spec in `lua/plugins/adb.lua` registers lazy loading, keymap, and command.

**Tech Stack:** Lua, Neovim ≥0.10 (`vim.system`), `adb` CLI

## Global Constraints

- Lua style: 2-space indent, 120 column width (stylua.toml)
- Plugin loading: `event = "VeryLazy"` + explicit `cmd`/`keys` tables
- No external Lua dependencies (only stdlib + Neovim API)
- Async I/O via `vim.system` (not `vim.fn.system`)
- Module pattern: `local M = {}` … `return M`

---

### Task 1: Device Discovery Module

**Files:**
- Create: `dev/adbhelper.nvim/lua/adbhelper/device.lua`

**Interfaces:**
- Consumes: nothing (leaf module)
- Produces:
  - `M.get_devices(callback)` — async; calls `callback(devices)` where `devices` is `string[]` of serials (empty table if none)
  - `M.pick_device(callback)` — async; auto-selects if 1 device, shows `vim.ui.select` if 2+, calls `callback(serial)` or notifies error if 0

- [ ] **Step 1: Create the device module**

Create `dev/adbhelper.nvim/lua/adbhelper/device.lua`:

```lua
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
```

- [ ] **Step 2: Verify module loads in Neovim**

Run in Neovim command line:
```vim
:lua print(vim.inspect(require("adbhelper.device")))
```
Expected: table with `get_devices` and `pick_device` functions (no errors).

- [ ] **Step 3: Verify device listing (requires adb on PATH)**

Run in Neovim:
```vim
:lua require("adbhelper.device").get_devices(function(d) print(vim.inspect(d)) end)
```
Expected: prints a table of device serials (or empty table `{}` if none connected).

- [ ] **Step 4: Commit**

```bash
git add dev/adbhelper.nvim/lua/adbhelper/device.lua
git commit -m "feat(adbhelper): add device discovery module"
```

---

### Task 2: Text Input Module

**Files:**
- Create: `dev/adbhelper.nvim/lua/adbhelper/input.lua`

**Interfaces:**
- Consumes: a device serial (string) from `device.pick_device`
- Produces:
  - `M.send_text(serial, text)` — async; segments text and dispatches adb commands sequentially

- [ ] **Step 1: Create the input module**

Create `dev/adbhelper.nvim/lua/adbhelper/input.lua`:

```lua
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
        vim.notify(
          "adb command failed: " .. (result.stderr or "unknown"),
          vim.log.levels.WARN,
          { title = "AdbHelper" }
        )
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
```

- [ ] **Step 2: Verify module loads**

```vim
:lua print(vim.inspect(require("adbhelper.input")))
```
Expected: table with `send_text` function.

- [ ] **Step 3: Verify text segmentation logic (manual spot check)**

```vim
:lua local i = require("adbhelper.input"); i.send_text("FAKE_SERIAL", "hello world!@#")
```
Expected: error notifications from adb (since FAKE_SERIAL doesn't exist) confirming the commands were attempted — this proves the segmentation and dispatch pipeline runs without Lua errors.

- [ ] **Step 4: Commit**

```bash
git add dev/adbhelper.nvim/lua/adbhelper/input.lua
git commit -m "feat(adbhelper): add text input module with keyevent fallback"
```

---

### Task 3: Plugin Init and Command Registration

**Files:**
- Create: `dev/adbhelper.nvim/lua/adbhelper/init.lua`

**Interfaces:**
- Consumes:
  - `device.pick_device(callback)` from Task 1
  - `input.send_text(serial, text, on_done)` from Task 2
- Produces:
  - `M.setup(opts)` — called by lazy.nvim `config`
  - `M.send_selection()` — extracts visual selection, picks device, sends text
  - User command `:AdbSendText` (visual-range)

- [ ] **Step 1: Create the init module**

Create `dev/adbhelper.nvim/lua/adbhelper/init.lua`:

```lua
local M = {}

---@param opts? table
function M.setup(opts)
  -- Reserved for future configuration (e.g., preferred device, custom keyevent overrides).
  _ = opts
end

--- Get the current visual selection as a string.
---@return string
local function get_visual_selection()
  -- Use the most recently set visual marks. When called from a visual-range
  -- command (:<C-u>AdbSendText<cr>), marks '< and '> are set before the
  -- command runs.
  local start_pos = vim.api.nvim_buf_get_mark(0, "<")
  local end_pos = vim.api.nvim_buf_get_mark(0, ">")
  local start_row, start_col = start_pos[1], start_pos[2]
  local end_row, end_col = end_pos[1], end_pos[2]

  if start_row == 0 and end_row == 0 then
    return ""
  end

  local lines = vim.api.nvim_buf_get_text(0, start_row - 1, start_col, end_row - 1, end_col + 1, {})
  return table.concat(lines, "\n")
end

--- Send the current visual selection to an Android device.
function M.send_selection()
  local text = get_visual_selection()
  if text == "" then
    vim.notify("No text selected", vim.log.levels.WARN, { title = "AdbHelper" })
    return
  end

  local device = require("adbhelper.device")
  local input = require("adbhelper.input")

  device.pick_device(function(serial)
    input.send_text(serial, text, function()
      vim.notify("Text sent to " .. serial, vim.log.levels.INFO, { title = "AdbHelper" })
    end)
  end)
end

return M
```

- [ ] **Step 2: Verify module loads**

```vim
:lua print(vim.inspect(require("adbhelper")))
```
Expected: table with `setup` and `send_selection` functions.

- [ ] **Step 3: Commit**

```bash
git add dev/adbhelper.nvim/lua/adbhelper/init.lua
git commit -m "feat(adbhelper): add init module with send_selection command"
```

---

### Task 4: Plugin Spec and Keymap

**Files:**
- Create: `lua/plugins/adb.lua`

**Interfaces:**
- Consumes: `M.setup(opts)` and `M.send_selection()` from Task 3
- Produces: lazy.nvim plugin registration, `:AdbSendText` command, `<F13>` keymap

- [ ] **Step 1: Create the lazy.nvim plugin spec**

Create `lua/plugins/adb.lua`:

```lua
-- adbhelper.nvim: send selected text to an Android device via adb.
-- Supports device picker (vim.ui.select) when multiple devices are connected,
-- and handles special characters via keyevent fallback.
return {
  dir = vim.fn.stdpath("config") .. "/dev/adbhelper.nvim",
  name = "adbhelper.nvim",
  event = "VeryLazy",
  cmd = { "AdbSendText" },
  keys = {
    { "<F13>", ":<C-u>AdbSendText<cr>", mode = "v", desc = "Send selection to Android device" },
  },
  config = function(_, opts)
    local adb = require("adbhelper")
    adb.setup(opts)
    vim.api.nvim_create_user_command("AdbSendText", function()
      adb.send_selection()
    end, { range = true, desc = "Send visual selection to Android device via adb" })
  end,
}
```

- [ ] **Step 2: Verify plugin loads with Lazy**

Restart Neovim (or run `:Lazy reload adbhelper.nvim`), then:
```vim
:AdbSendText
```
Expected: "No text selected" warning (since nothing is visually selected outside visual mode).

- [ ] **Step 3: End-to-end test (requires a connected device)**

1. Connect an Android device (or emulator).
2. Open any buffer, visually select some text (e.g., `hello world`).
3. Press `<F13>`.
4. If multiple devices: picker appears — choose one.
5. Expected: text appears in the focused input field on the Android device.
6. Verify with symbols: select `test@email.com` → should type correctly on device.

- [ ] **Step 4: Commit**

```bash
git add lua/plugins/adb.lua
git commit -m "feat(adbhelper): add plugin spec with F13 keymap and AdbSendText command"
```

---
