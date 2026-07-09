return {
  {
    "sindrets/diffview.nvim",
    cmd = { "DiffviewOpen", "DiffviewClose", "DiffviewToggleFiles", "DiffviewFocusFiles" },
    keys = {
      { "<leader>gd", "<cmd>DiffviewOpen<cr>", desc = "Diffview Open" },
      { "<leader>gD", "<cmd>DiffviewClose<cr>", desc = "Diffview Close" },
    },
    opts = {
      -- Hide untracked/hidden files from the file panel by default (-uno).
      default_args = {
        DiffviewOpen = { "-uno" },
      },
    },
  },
}
