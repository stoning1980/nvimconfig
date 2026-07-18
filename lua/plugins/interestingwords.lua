-- interestingwords.nvim: mark the word under the cursor (or a visual selection)
-- in a distinct color. Every occurrence of the same text shares that color,
-- across every open buffer and any file opened afterwards. Keys are wired
-- explicitly in lua/config/keymaps.lua (F10 / S-F10), so the plugin's own
-- <leader> mappings are disabled here by passing `false`.
return {
  "Mr-LLLLL/interestingwords.nvim",
  event = "VeryLazy",
  config = function()
    require("interestingwords").setup({
      search_key = false,
      cancel_search_key = false,
      color_key = false,
      cancel_color_key = false,
    })
  end,
}
