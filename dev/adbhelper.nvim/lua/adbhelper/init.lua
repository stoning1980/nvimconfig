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

--- Find the token under the cursor, using the same grouping as the `w` motion: a
--- run of keyword characters or a run of punctuation, with blanks skipped
--- forward. `expand("<cword>")` cannot be used here because it refuses to return
--- punctuation and silently jumps ahead to the next keyword instead, which makes
--- separators unsendable and repeats the following word.
---@return string? text, integer? end_col byte column (0-indexed) of the last character
local function token_under_cursor()
  local col = vim.api.nvim_win_get_cursor(0)[2]
  local chars = vim.fn.split(vim.api.nvim_get_current_line(), "\\zs")
  local offsets, byte = {}, 0
  for i, ch in ipairs(chars) do
    offsets[i] = byte
    byte = byte + #ch
  end

  local idx
  for i = 1, #chars do
    if col < offsets[i] + #chars[i] then
      idx = i
      break
    end
  end
  -- Cursor on a blank: the token is the next one on the line, matching where a
  -- `w` motion would land.
  while idx and vim.fn.charclass(chars[idx]) == 0 do
    idx = idx < #chars and idx + 1 or nil
  end
  if not idx then
    return nil, nil
  end

  local class = vim.fn.charclass(chars[idx])
  local first, last = idx, idx
  while first > 1 and vim.fn.charclass(chars[first - 1]) == class do
    first = first - 1
  end
  while last < #chars and vim.fn.charclass(chars[last + 1]) == class do
    last = last + 1
  end
  return table.concat(chars, "", first, last), offsets[last]
end

--- Move the cursor to the start of the token following `from` ({row, col} with a
--- 1-indexed row and 0-indexed col), so repeated sends walk through the buffer
--- token by token. `from` must be the last character of the token just sent, or
--- the walk sends that token again. This runs once the send has finished, so it
--- bails out when the user has moved on to another buffer or is no longer in
--- normal mode.
---@param buf integer buffer the text was sent from
---@param from integer[]
local function advance_to_next_word(buf, from)
  if vim.api.nvim_get_current_buf() ~= buf or vim.fn.mode() ~= "n" then
    return
  end
  local row = from[1]
  if row < 1 or row > vim.api.nvim_buf_line_count(buf) then
    return
  end
  local line = vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1] or ""
  -- The '> mark uses v:maxcol for linewise selections, so clamp it.
  local col = math.max(math.min(from[2], #line - 1), 0)
  vim.api.nvim_win_set_cursor(0, { row, col })
  vim.cmd("normal! w")
end

--- Pick a device and send the given text to it.
---@param text string
---@param on_sent? fun() called only when every adb command succeeded
local function send(text, on_sent)
  local device = require("adbhelper.device")
  local input = require("adbhelper.input")
  device.pick_device(function(serial)
    input.send_text(serial, text, function(ok)
      if not ok then
        return
      end
      vim.notify("Text sent to " .. serial, vim.log.levels.INFO, { title = "AdbHelper" })
      if on_sent then
        on_sent()
      end
    end)
  end)
end

--- Send the current visual selection to an Android device. The selection is
--- also copied to the system clipboard so a subsequent normal-mode send resends
--- the same text. Once the send succeeds the cursor moves to the word following
--- the selection.
function M.send_selection()
  local text = get_visual_selection()
  if text == "" then
    vim.notify("No text selected", vim.log.levels.WARN, { title = "AdbHelper" })
    return
  end
  vim.fn.setreg("+", text)
  local buf = vim.api.nvim_get_current_buf()
  local selection_end = vim.api.nvim_buf_get_mark(0, ">")
  send(text, function()
    advance_to_next_word(buf, selection_end)
  end)
end

--- Send text to an Android device from normal mode. Prefers the token under the
--- cursor (a word or a run of punctuation such as `.` or `:`); when the rest of
--- the line is blank, falls back to the system clipboard contents. A successful
--- send advances the cursor to the next token, so repeated presses walk through
--- the buffer.
function M.send_clipboard()
  local text, end_col = token_under_cursor()
  if text == nil then
    local clipboard = vim.fn.getreg("+")
    if clipboard == nil or clipboard == "" then
      vim.notify("No text to send", vim.log.levels.WARN, { title = "AdbHelper" })
      return
    end
    send(clipboard)
    return
  end
  local buf = vim.api.nvim_get_current_buf()
  local row = vim.api.nvim_win_get_cursor(0)[1]
  send(text, function()
    advance_to_next_word(buf, { row, end_col })
  end)
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
