return {
  {
    "sindrets/diffview.nvim",
    cmd = { "DiffviewOpen", "DiffviewClose", "DiffviewToggleFiles", "DiffviewFocusFiles" },
    keys = {
      { "<leader>gd", "<cmd>DiffviewOpen<cr>", desc = "Diffview Open" },
      { "<leader>gD", "<cmd>DiffviewClose<cr>", desc = "Diffview Close" },
    },
    config = function(_, opts)
      require("diffview").setup(opts)
      require("config.diffview_bootstrap").setup()
    end,
    opts = {
      -- Dim unchanged regions and emphasize the actual changed text/words.
      enhanced_diff_hl = true,
      -- Hide untracked/hidden files from the file panel by default (-uno).
      default_args = {
        DiffviewOpen = { "-uno" },
      },
      -- <F1> Git status arms this so tool directories are removed from the
      -- file list. Path args cannot do it: Diffview would show them as the
      -- diff scope and the real changes would disappear.
      hooks = {
        view_opened = function(view)
          require("config.git_diff").consume_ai_tool_filter(view)
        end,
      },
    },
  },
}
