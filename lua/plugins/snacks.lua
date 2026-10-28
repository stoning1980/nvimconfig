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
    {
      "<leader><space>",
      function()
        local exact = require("config.exact_filename")
        Snacks.picker.files({ cwd = exact.search_cwd(vim.uv.cwd(), LazyVim.root()) })
      end,
      desc = "Find files by exact filename",
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
        -- `<leader><space>` / `<leader>ff`: the query must equal the filename.
        -- Fuzzy matching and directory names are not compared.
        files = {
          matcher = {
            fuzzy = false,
            -- Always ignore case. A capital letter in the query still matches.
            smartcase = false,
            ignorecase = true,
          },
          -- An empty query does not walk the tree. `fd` runs only after the
          -- typed filename has stayed still for a moment.
          finder = function(opts, ctx)
            local exact = require("config.exact_filename")
            if exact.fd_available() and (ctx.filter.search or "") == "" then
              return {}
            end
            return require("snacks.picker.source.files").files(opts, ctx)
          end,
          transform = function(item)
            local exact = require("config.exact_filename")
            local file = item.file or item.text or ""
            item.file = item.file or file
            item.text = exact.item_text(file)
          end,
          filter = {
            transform = function(picker, filter)
              require("config.exact_filename").hold_fd(picker, filter)
            end,
          },
        },
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
