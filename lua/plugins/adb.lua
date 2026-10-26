-- adbhelper.nvim: send selected text to an Android device via adb.
-- Supports device picker (vim.ui.select) when multiple devices are connected,
-- and handles special characters via keyevent fallback.
return {
  dir = vim.fn.stdpath("config") .. "/dev/adbhelper.nvim",
  name = "adbhelper.nvim",
  event = "VeryLazy",
  cmd = { "AdbSendText", "AdbSendWord", "AdbMenu" },
  -- F12: visual → send the selection. Normal → send the WORD under the cursor.
  -- Either way, a successful send jumps to the next WORD (whitespace, not
  -- punctuation). A cursor on whitespace uses the next WORD.
  -- Shift+F12 opens the action menu. Proxy on and proxy off follow the app
  -- actions, and the menu marks which one is current. Terminals emit shifted
  -- F12 as <F24>, so both spellings are mapped.
  keys = {
    { "<F12>", ":<C-u>AdbSendText<cr>", mode = "v", desc = "Send selection to Android device, then next WORD" },
    { "<F12>", "<cmd>AdbSendWord<cr>", mode = "n", desc = "Send WORD under cursor to Android device" },
    { "<S-F12>", "<cmd>AdbMenu<cr>", mode = "n", desc = "AdbHelper action menu" },
    { "<F24>", "<cmd>AdbMenu<cr>", mode = "n", desc = "AdbHelper action menu" },
  },
  config = function(_, opts)
    local adb = require("adbhelper")
    adb.setup(opts)
    vim.api.nvim_create_user_command("AdbSendText", function()
      adb.send_selection()
    end, { range = true, desc = "Send visual selection to Android device via adb" })
    vim.api.nvim_create_user_command("AdbSendWord", function()
      adb.send_word()
    end, { desc = "Send WORD under cursor to Android device via adb" })
    vim.api.nvim_create_user_command("AdbMenu", function()
      adb.action_menu()
    end, { desc = "AdbHelper: A/B debug, relaunch, kill, clear, then proxy on/off" })
  end,
}
