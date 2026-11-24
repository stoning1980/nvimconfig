-- adbhelper.nvim: send selected text to an Android device via adb.
-- Supports device picker (vim.ui.select) when multiple devices are connected,
-- and handles special characters via keyevent fallback.
return {
  dir = vim.fn.stdpath("config") .. "/dev/adbhelper.nvim",
  name = "adbhelper.nvim",
  event = "VeryLazy",
  cmd = {
    "AdbSendText",
    "AdbSendWord",
    "AdbMenu",
    "AdbDebugMenu",
    "AdbRelaunchApp",
    "AdbScreenshot",
    "AdbRecordScreen",
    "AdbLogcat",
    "AdbAppSettings",
    "AdbForceStop",
  },
  -- F12: visual → send the selection and leave the cursor where it is.
  -- Normal → send the WORD under the cursor (whitespace, not punctuation).
  -- A cursor on whitespace uses the next WORD on the line. After that send,
  -- the cursor stays on the same line and moves to the next WORD, or to the
  -- first WORD when nothing follows. The text is not copied to the clipboard.
  -- Shift+F12 opens the Android + iOS Simulator action menu. Android proxy on
  -- and proxy off follow its app actions, and the menu marks which one is
  -- current. Terminals emit shifted F12 as <F24>, so both spellings are mapped.
  --
  -- F18 opens the focused TikTok-family A/B debug menu; F19 saves/copies a
  -- screenshot. The other Android actions stay available as commands. Many
  -- terminals encode Shift+F6 and Shift+F7 as F18 and F19, so those shifted
  -- combinations may invoke the same actions.
  keys = {
    { "<F12>", ":<C-u>AdbSendText<cr>", mode = "v", desc = "Send selection to Android device" },
    { "<F12>", "<cmd>AdbSendWord<cr>", mode = "n", desc = "Send WORD, then next WORD or first WORD of the line" },
    { "<S-F12>", "<cmd>AdbMenu<cr>", mode = "n", desc = "Android and iOS Simulator action menu" },
    { "<F24>", "<cmd>AdbMenu<cr>", mode = "n", desc = "Android and iOS Simulator action menu" },
    { "<F18>", "<cmd>AdbDebugMenu<cr>", mode = "n", desc = "Open focused Android app A/B debug menu" },
    { "<F19>", "<cmd>AdbScreenshot<cr>", mode = "n", desc = "Save Android screenshot and copy it" },
  },
  config = function(_, opts)
    local adb = require("adbhelper")
    local actions = require("adbhelper.actions")
    local capture = require("adbhelper.capture")
    local logcat = require("adbhelper.logcat")
    adb.setup(opts)
    vim.api.nvim_create_user_command("AdbSendText", function()
      adb.send_selection()
    end, { range = true, desc = "Send visual selection to Android device via adb" })
    vim.api.nvim_create_user_command("AdbSendWord", function()
      adb.send_word()
    end, { desc = "Send WORD via adb, then next WORD or first WORD of the line" })
    vim.api.nvim_create_user_command("AdbMenu", function()
      adb.action_menu()
    end, { desc = "Android and iOS Simulator app actions" })
    vim.api.nvim_create_user_command("AdbDebugMenu", function()
      actions.run("ab")
    end, { desc = "Open focused TikTok-family app A/B debug menu" })
    vim.api.nvim_create_user_command("AdbRelaunchApp", function()
      actions.run("relaunch")
    end, { desc = "Relaunch focused TikTok-family app" })
    vim.api.nvim_create_user_command("AdbScreenshot", function()
      capture.screenshot()
    end, { desc = "Save an Android screenshot and copy the PNG" })
    vim.api.nvim_create_user_command("AdbRecordScreen", function()
      capture.toggle_recording()
    end, { desc = "Toggle Android screen recording" })
    vim.api.nvim_create_user_command("AdbLogcat", function()
      logcat.toggle()
    end, { desc = "Toggle focused Android app logcat" })
    vim.api.nvim_create_user_command("AdbAppSettings", function()
      actions.run("settings")
    end, { desc = "Open focused TikTok-family app settings" })
    vim.api.nvim_create_user_command("AdbForceStop", function()
      actions.run("kill")
    end, { desc = "Force-stop focused TikTok-family app" })
  end,
}
