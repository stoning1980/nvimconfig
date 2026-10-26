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

--- Find the WORD under the cursor: a run of non-blank characters, the same
--- grouping as the `W` motion. Blanks are skipped forward, so a cursor sitting
--- on the gap between two addresses sends the next one. `<cword>` is not used
--- because it stops at punctuation and would split `a21740test0+133@gmail.com`.
---@return string? text, integer? end_col byte column (0-indexed) of the last character
local function word_under_cursor()
  local col = vim.api.nvim_win_get_cursor(0)[2]
  local chars = vim.fn.split(vim.api.nvim_get_current_line(), "\\zs")
  local offsets, byte = {}, 0
  for i, ch in ipairs(chars) do
    offsets[i] = byte
    byte = byte + #ch
  end

  local function is_blank(ch)
    return vim.fn.charclass(ch) == 0
  end

  local idx
  for i = 1, #chars do
    if col < offsets[i] + #chars[i] then
      idx = i
      break
    end
  end
  while idx and is_blank(chars[idx]) do
    idx = idx < #chars and idx + 1 or nil
  end
  if not idx then
    return nil, nil
  end

  local first, last = idx, idx
  while first > 1 and not is_blank(chars[first - 1]) do
    first = first - 1
  end
  while last < #chars and not is_blank(chars[last + 1]) do
    last = last + 1
  end
  return table.concat(chars, "", first, last), offsets[last]
end

local function is_blank_char(ch)
  return vim.fn.charclass(ch) == 0
end

local function line_chars(line)
  local chars = vim.fn.split(line, "\\zs")
  local offsets, byte = {}, 0
  for i, ch in ipairs(chars) do
    offsets[i] = byte
    byte = byte + #ch
  end
  return chars, offsets
end

--- Byte column of the first WORD on `row`, or nil when that line is blank.
--- A WORD starts at the first non-blank character, same grouping as `W`.
---@param buf integer
---@param row integer 1-indexed
---@return integer?
local function first_word_col(buf, row)
  if row < 1 or row > vim.api.nvim_buf_line_count(buf) then
    return nil
  end
  local line = vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1] or ""
  local chars, offsets = line_chars(line)
  for i = 1, #chars do
    if not is_blank_char(chars[i]) then
      return offsets[i]
    end
  end
  return nil
end

--- Byte column of the next WORD on `row` after `from_col`, or nil when the
--- rest of the line is blank. `from_col` is the 0-indexed byte of a character
--- inside the WORD just sent. Never looks at the following line.
---@param buf integer
---@param row integer
---@param from_col integer
---@return integer?
local function next_word_col_on_line(buf, row, from_col)
  if row < 1 or row > vim.api.nvim_buf_line_count(buf) then
    return nil
  end
  local line = vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1] or ""
  local chars, offsets = line_chars(line)
  local idx = #chars + 1
  for i = 1, #chars do
    if from_col < offsets[i] + #chars[i] then
      idx = i
      break
    end
  end
  while idx <= #chars and not is_blank_char(chars[idx]) do
    idx = idx + 1
  end
  for i = idx, #chars do
    if not is_blank_char(chars[i]) then
      return offsets[i]
    end
  end
  return nil
end

--- After a WORD send, stay on `row`. Move to the next WORD on that line, or
--- to its first WORD when nothing follows. Deferred one turn so a cursor
--- restore from the adb callback cannot undo it. Skipped when the user has
--- left this window's buffer.
---@param buf integer
---@param win integer
---@param row integer
---@param end_col integer
local function move_after_sent_word(buf, win, row, end_col)
  vim.schedule(function()
    if not vim.api.nvim_buf_is_valid(buf) or not vim.api.nvim_win_is_valid(win) then
      return
    end
    if vim.api.nvim_win_get_buf(win) ~= buf then
      return
    end
    local col = next_word_col_on_line(buf, row, end_col) or first_word_col(buf, row)
    if not col then
      return
    end
    vim.api.nvim_win_set_cursor(win, { row, col })
  end)
end

--- Pick a device and send the given text to it.
---@param text string
---@param on_sent? fun() called when at least one adb command succeeded
local function send(text, on_sent)
  local device = require("adbhelper.device")
  local input = require("adbhelper.input")
  device.pick_device(function(serial)
    input.send_text(serial, text, function(ok, any_ok)
      if ok then
        vim.notify("Text sent to " .. serial, vim.log.levels.INFO, { title = "AdbHelper" })
      end
      if (ok or any_ok) and on_sent then
        on_sent()
      end
    end)
  end)
end

--- Send the current visual selection to an Android device. The text is sent
--- with adb only; it is not copied to a register or the system clipboard.
--- The cursor is left where it is.
function M.send_selection()
  local text = get_visual_selection()
  if text == "" then
    vim.notify("No text selected", vim.log.levels.WARN, { title = "AdbHelper" })
    return
  end
  send(text)
end

--- Send the WORD under the cursor to an Android device. A WORD is a run of
--- non-blank characters, so an address is sent whole. A cursor on whitespace
--- uses the next WORD on the line. The text is sent with adb only; it is not
--- copied to a register or the system clipboard. Once any of the send has
--- landed, the cursor stays on this line and moves to the next WORD, or to
--- the first WORD when nothing follows on the line.
function M.send_word()
  local text, end_col = word_under_cursor()
  if text == nil or end_col == nil then
    vim.notify("No text to send", vim.log.levels.WARN, { title = "AdbHelper" })
    return
  end
  local buf = vim.api.nvim_get_current_buf()
  local win = vim.api.nvim_get_current_win()
  local row = vim.api.nvim_win_get_cursor(0)[1]
  send(text, function()
    move_after_sent_word(buf, win, row, end_col)
  end)
end

--- Mark whichever proxy row matches every connected device.
---@param lines { state: "on"|"off"|"other" }[]
---@return string on_label, string off_label
local function proxy_labels(lines)
  local on_label, off_label = "Proxy on", "Proxy off"
  local saw_on, saw_off, saw_other = false, false, false
  for _, line in ipairs(lines) do
    if line.state == "on" then
      saw_on = true
    elseif line.state == "off" then
      saw_off = true
    else
      saw_other = true
    end
  end
  if saw_on and not saw_off and not saw_other then
    on_label = "Proxy on · current"
  elseif saw_off and not saw_on and not saw_other then
    off_label = "Proxy off · current"
  end
  return on_label, off_label
end

--- Title carries the reading, including a mismatch between the setting and the reverse.
---@param lines { serial: string, text: string }[]
---@return string
local function menu_title(lines)
  if #lines == 0 then
    return "AdbHelper"
  end
  if #lines == 1 then
    return "AdbHelper · " .. lines[1].text
  end
  local parts = {}
  for _, line in ipairs(lines) do
    parts[#parts + 1] = line.serial .. " " .. line.text
  end
  return "AdbHelper · " .. table.concat(parts, ", ")
end

--- Show the adb action menu. Device and app pickers follow the app actions.
--- Proxy on and proxy off come after those, apply to every connected device,
--- and the current reading is shown on the menu itself.
function M.action_menu()
  local ui = require("adbhelper.ui")
  local actions = require("adbhelper.actions")
  local proxy = require("adbhelper.proxy")
  proxy.read(function(lines)
    local on_label, off_label = proxy_labels(lines)
    ui.select({
      { text = "A/B debug menu", action = "ab" },
      { text = "Relaunch app", action = "relaunch" },
      { text = "Kill TikTok family app", action = "kill" },
      { text = "Clear TikTok family app", action = "clear" },
      { text = on_label, action = "proxy_on" },
      { text = off_label, action = "proxy_off" },
    }, { title = menu_title(lines) }, function(item)
      if not item then
        return
      end
      if item.action == "proxy_on" then
        proxy.on()
      elseif item.action == "proxy_off" then
        proxy.off()
      else
        actions.run(item.action)
      end
    end)
  end)
end

return M
