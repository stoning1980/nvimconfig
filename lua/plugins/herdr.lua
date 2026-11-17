return {
  dir = vim.fn.stdpath("config") .. "/dev/herdr.nvim",
  name = "herdr.nvim",
  event = "VeryLazy",
  dependencies = { "folke/snacks.nvim" },
  cmd = {
    "HerdrComment",
    "HerdrCommentVisual",
    "HerdrPick",
    "HerdrRefresh",
    "HerdrStatus",
  },
  keys = {
    { "<F8>", "<cmd>HerdrComment<cr>", mode = "n", desc = "Comment current line to Herdr agent" },
    { "<F8>", ":<C-u>HerdrCommentVisual<cr>", mode = "v", desc = "Comment selection to Herdr agent" },
    { "<leader>h", nil, desc = "Herdr" },
    { "<leader>hc", "<cmd>HerdrComment<cr>", desc = "Comment to Herdr agent" },
    { "<leader>hc", ":<C-u>HerdrCommentVisual<cr>", mode = "v", desc = "Comment selection to Herdr agent" },
    { "<leader>hp", "<cmd>HerdrPick<cr>", desc = "Pick Herdr agent" },
    { "<leader>hr", "<cmd>HerdrRefresh<cr>", desc = "Refresh Herdr agents" },
    { "<leader>hs", "<cmd>HerdrStatus<cr>", desc = "Herdr status" },
  },
  opts = {},
  config = function(_, opts)
    require("herdr").setup(opts)
  end,
}
