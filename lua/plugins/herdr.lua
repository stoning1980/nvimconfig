return {
  dir = vim.fn.stdpath("config") .. "/dev/herdr.nvim",
  name = "herdr.nvim",
  event = "VeryLazy",
  dependencies = { "folke/snacks.nvim" },
  cmd = {
    "HerdrComment",
    "HerdrCommentVisual",
    "HerdrSubmitQueue",
    "HerdrPick",
    "HerdrRefresh",
    "HerdrStatus",
  },
  keys = {
    { "<F8>", "<cmd>HerdrComment<cr>", mode = "n", desc = "Queue current line review comment" },
    { "<F8>", ":<C-u>HerdrCommentVisual<cr>", mode = "v", desc = "Queue selected review comment" },
    { "<leader>h", nil, desc = "Herdr" },
    { "<leader>hc", "<cmd>HerdrComment<cr>", desc = "Queue review comment" },
    { "<leader>hc", ":<C-u>HerdrCommentVisual<cr>", mode = "v", desc = "Queue selected review comment" },
    { "<leader>hS", "<cmd>HerdrSubmitQueue<cr>", desc = "Submit queued Herdr comments" },
    { "<leader>hp", "<cmd>HerdrPick<cr>", desc = "Pick Herdr agent" },
    { "<leader>hr", "<cmd>HerdrRefresh<cr>", desc = "Refresh Herdr agents" },
    { "<leader>hs", "<cmd>HerdrStatus<cr>", desc = "Herdr status" },
  },
  opts = {},
  config = function(_, opts)
    require("herdr").setup(opts)
  end,
}
