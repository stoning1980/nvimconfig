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

  -- Clamp the end column to the end row's length. The '> mark is inclusive, so
  -- normally we add 1 to include the character under it. But for linewise (V)
  -- selections '> column is v:maxcol (a huge sentinel), which would otherwise
  -- run past the buffer and error. Multi-line selections come back as multiple
  -- lines and are joined with "\n" (sent as Enter keyevents by input.lua).
  local end_line = vim.api.nvim_buf_get_lines(0, end_row - 1, end_row, false)[1] or ""
  end_col = math.min(end_col + 1, #end_line)

  local lines = vim.api.nvim_buf_get_text(0, start_row - 1, start_col, end_row - 1, end_col, {})
  return table.concat(lines, "\n")
end

--- Pick a device and send the given text to it.
---@param text string
local function send(text)
  local device = require("adbhelper.device")
  local input = require("adbhelper.input")
  device.pick_device(function(serial)
    input.send_text(serial, text, function()
      vim.notify("Text sent to " .. serial, vim.log.levels.INFO, { title = "AdbHelper" })
    end)
  end)
end

--- Send the current visual selection to an Android device. The selection is
--- also copied to the system clipboard so a subsequent normal-mode send resends
--- the same text.
function M.send_selection()
  local text = get_visual_selection()
  if text == "" then
    vim.notify("No text selected", vim.log.levels.WARN, { title = "AdbHelper" })
    return
  end
  vim.fn.setreg("+", text)
  send(text)
end

--- Send text to an Android device from normal mode. Prefers the word under the
--- cursor; when there is no word under the cursor, falls back to the system
--- clipboard contents.
function M.send_clipboard()
  local text = vim.fn.expand("<cword>")
  if text == nil or text == "" then
    text = vim.fn.getreg("+")
  end
  if text == nil or text == "" then
    vim.notify("No text to send", vim.log.levels.WARN, { title = "AdbHelper" })
    return
  end
  send(text)
end

--- Show the adb action menu (device/app pickers follow the chosen action).
function M.action_menu()
  local ui = require("adbhelper.ui")
  local actions = require("adbhelper.actions")
  local items = {
    { text = "A/B debug menu", action = "ab" },
    { text = "Relaunch app", action = "relaunch" },
    { text = "Kill TikTok family app", action = "kill" },
    { text = "Clear TikTok family app", action = "clear" },
  }
  ui.select(items, { title = "AdbHelper" }, function(item)
    if item then
      actions.run(item.action)
    end
  end)
end

return M
