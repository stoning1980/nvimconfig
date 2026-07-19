-- adbhelper.nvim: send selected text to an Android device via adb.
-- Supports device picker (vim.ui.select) when multiple devices are connected,
-- and handles special characters via keyevent fallback.
return {
  dir = vim.fn.stdpath("config") .. "/dev/adbhelper.nvim",
  name = "adbhelper.nvim",
  event = "VeryLazy",
  cmd = { "AdbSendText", "AdbMenu" },
  keys = {
    { "<F13>", ":<C-u>AdbSendText<cr>", mode = "v", desc = "Send selection to Android device" },
    { "<S-F13>", "<cmd>AdbMenu<cr>", mode = "n", desc = "AdbHelper action menu" },
  },
  config = function(_, opts)
    local adb = require("adbhelper")
    adb.setup(opts)
    vim.api.nvim_create_user_command("AdbSendText", function()
      adb.send_selection()
    end, { range = true, desc = "Send visual selection to Android device via adb" })
    vim.api.nvim_create_user_command("AdbMenu", function()
      adb.action_menu()
    end, { desc = "AdbHelper: pick an adb action (A/B debug, kill, clear, relaunch)" })
  end,
}
