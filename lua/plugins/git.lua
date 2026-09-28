return {
  {
    "sindrets/diffview.nvim",
    cmd = { "DiffviewOpen", "DiffviewClose", "DiffviewToggleFiles", "DiffviewFocusFiles" },
    keys = {
      { "<leader>gd", "<cmd>DiffviewOpen<cr>", desc = "Diffview Open" },
      { "<leader>gD", "<cmd>DiffviewClose<cr>", desc = "Diffview Close" },
    },
    opts = {
      -- Dim unchanged regions and emphasize the actual changed text/words.
      enhanced_diff_hl = true,
      -- Hide untracked/hidden files from the file panel by default (-uno).
      default_args = {
        DiffviewOpen = { "-uno" },
      },
      -- Put the file list on the right, beside HEAD's copy of the file, which
      -- is the side <F3> lands on and the one worth reading. Only `position` is
      -- set: diffview deep-merges this over its defaults, so width stays 35.
      file_panel = {
        win_config = { position = "right" },
      },
    },
  },
}
