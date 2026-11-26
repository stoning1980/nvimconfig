local launch_dir = vim.uv.cwd() or vim.fn.getcwd()
local project_root = vim.uv.fs_realpath(launch_dir) or launch_dir

return {
  dir = vim.fn.stdpath("config") .. "/dev/reviewbuddy.nvim",
  name = "reviewbuddy.nvim",
  event = "VeryLazy",
  dependencies = { "folke/snacks.nvim" },
  cmd = {
    "ReviewComment",
    "ReviewCommentVisual",
    "ReviewSubmitQueue",
    "ReviewPick",
    "ReviewRefresh",
    "ReviewStatus",
    "HerdrComment",
    "HerdrCommentVisual",
    "HerdrSubmitQueue",
    "HerdrPick",
    "HerdrRefresh",
    "HerdrStatus",
  },
  keys = {
    { "<F8>", "<cmd>ReviewComment<cr>", mode = "n", desc = "Queue current file review context" },
    { "<F8>", "<cmd>ReviewCommentVisual<cr>", mode = "v", desc = "Queue selected review comment" },
    { "<leader>h", nil, desc = "Review comments" },
    { "<leader>hc", "<cmd>ReviewComment<cr>", desc = "Queue current file review context" },
    { "<leader>hc", "<cmd>ReviewCommentVisual<cr>", mode = "v", desc = "Queue selected review comment" },
    { "<leader>hS", "<cmd>ReviewSubmitQueue<cr>", desc = "Choose session and submit review comments" },
    { "<leader>hp", "<cmd>ReviewPick<cr>", desc = "Explain review session selection" },
    { "<leader>hr", "<cmd>ReviewRefresh<cr>", desc = "Refresh review sessions" },
    { "<leader>hs", "<cmd>ReviewStatus<cr>", desc = "Review queue and session status" },
  },
  opts = { project_root = project_root },
  config = function(_, opts)
    require("reviewbuddy").setup(opts)
  end,
}
