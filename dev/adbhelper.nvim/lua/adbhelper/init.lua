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
