-- adbhelper.nvim: send selected text to an Android device via adb.
-- Supports device picker (vim.ui.select) when multiple devices are connected,
-- and handles special characters via keyevent fallback.
return {
  dir = vim.fn.stdpath("config") .. "/dev/adbhelper.nvim",
  name = "adbhelper.nvim",
  event = "VeryLazy",
  cmd = { "AdbSendText", "AdbSendClipboard", "AdbMenu" },
  -- F12: send to Android device (visual → selection, normal → the WORD under
  -- the cursor, also copied to the system clipboard). A WORD runs until
  -- whitespace, so each address on a line is sent on its own. Repeated presses
  -- walk WORD by WORD.
  -- Shift+F12 opens the action menu; terminals emit shifted F12 as <F24>, so
  -- map both spellings.
  keys = {
    { "<F12>", ":<C-u>AdbSendText<cr>", mode = "v", desc = "Send selection to Android device" },
    { "<F12>", "<cmd>AdbSendClipboard<cr>", mode = "n", desc = "Send WORD under cursor and copy it" },
    { "<S-F12>", "<cmd>AdbMenu<cr>", mode = "n", desc = "AdbHelper action menu" },
    { "<F24>", "<cmd>AdbMenu<cr>", mode = "n", desc = "AdbHelper action menu" },
  },
  config = function(_, opts)
    local adb = require("adbhelper")
    adb.setup(opts)
    vim.api.nvim_create_user_command("AdbSendText", function()
      adb.send_selection()
    end, { range = true, desc = "Send visual selection to Android device via adb" })
    vim.api.nvim_create_user_command("AdbSendClipboard", function()
      adb.send_clipboard()
    end, { desc = "Send WORD under cursor to Android device and copy it" })
    vim.api.nvim_create_user_command("AdbMenu", function()
      adb.action_menu()
    end, { desc = "AdbHelper: pick an adb action (A/B debug, kill, clear, relaunch)" })
  end,
}
