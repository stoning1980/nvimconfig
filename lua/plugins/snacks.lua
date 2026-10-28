return {
  "folke/snacks.nvim",
  -- Scope `<leader>fr` (Recent) to the current project's root (git repo dir,
  -- via LazyVim's root detection) instead of the whole oldfiles history.
  -- `<leader>fR` stays cwd-scoped; use `<leader>fL` for the full history.
  keys = {
    {
      "<leader>fr",
      function()
        Snacks.picker.recent({ filter = { cwd = LazyVim.root() } })
      end,
      desc = "Recent (project root)",
    },
    {
      "<leader>fL",
      function()
        Snacks.picker.recent()
      end,
      desc = "Recent (all history)",
    },
  },
  opts = {
    dashboard = {
      preset = {
        -- Mirror LazyVim's default dashboard menu, but make "Recent Files"
        -- project-scoped (git root) instead of the full oldfiles history.
        -- stylua: ignore
        keys = {
          { icon = " ", key = "f", desc = "Find File", action = ":lua Snacks.dashboard.pick('files')" },
          { icon = " ", key = "n", desc = "New File", action = ":ene | startinsert" },
          { icon = " ", key = "g", desc = "Find Text", action = ":lua Snacks.dashboard.pick('live_grep')" },
          { icon = " ", key = "r", desc = "Recent Files (project)", action = function() Snacks.picker.recent({ filter = { cwd = LazyVim.root() } }) end },
          { icon = " ", key = "R", desc = "Recent Files (all)", action = ":lua Snacks.dashboard.pick('oldfiles')" },
          { icon = " ", key = "c", desc = "Config", action = ":lua Snacks.dashboard.pick('files', {cwd = vim.fn.stdpath('config')})" },
          { icon = " ", key = "s", desc = "Restore Session", section = "session" },
          { icon = " ", key = "x", desc = "Lazy Extras", action = ":LazyExtras" },
          { icon = "󰒲 ", key = "l", desc = "Lazy", action = ":Lazy" },
          { icon = " ", key = "q", desc = "Quit", action = ":qa" },
        },
      },
    },
    picker = {
      layout = {
        -- input + list on top, preview on the bottom
        layout = {
          backdrop = false,
          width = 0.9,
          min_width = 80,
          height = 0.9,
          min_height = 30,
          box = "vertical",
          border = true,
          title = "{title} {live} {flags}",
          title_pos = "center",
          { win = "input", height = 1, border = "bottom" },
          { win = "list", border = "none" },
          { win = "preview", title = "{preview}", height = 0.7, border = "top" },
        },
      },
      sources = {
        explorer = {
          hidden = true,
          -- keep the explorer as a left sidebar (must be explicit, otherwise
          -- the global picker layout above merges in and overrides it)
          layout = {
            preset = "sidebar",
            preview = false,
            layout = {
              backdrop = false,
              width = 40,
              min_width = 40,
              height = 0,
              position = "left",
              border = "none",
              box = "vertical",
              {
                win = "input",
                height = 1,
                border = true,
                title = "{title} {live} {flags}",
                title_pos = "center",
              },
              { win = "list", border = "none" },
              { win = "preview", title = "{preview}", height = 0.4, border = "top" },
            },
          },
        },
      },
    },
  },
}
