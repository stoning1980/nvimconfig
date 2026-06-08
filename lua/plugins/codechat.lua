-- codechat.nvim: drive CLI coding agents (Claude, Cursor) in Neovim terminals.
-- Runs the agent's interactive TUI in a terminal and injects the current
-- file/selection + an optional typed comment into its input box.
--   <F7>  -> send to the active agent (normal: whole file, visual: selection).
--           On first use it pops a picker (ttadk Claude / ttadk Cursor /
--           Claude / Cursor) and remembers the choice across restarts. Change
--           it later with :CodeChatPick.
-- Requires the respective CLI installed (and logged in once).
return {
  dir = vim.fn.stdpath("config") .. "/dev/codechat.nvim",
  name = "codechat.nvim",
  event = "VeryLazy",
  dependencies = { "folke/snacks.nvim" },
  cmd = {
    "CodeChat",
    "CodeChatSend",
    "CodeChatSendFile",
    "CodeChatPick",
    "TtadkClaudeChat",
    "TtadkClaudeChatSend",
    "TtadkClaudeChatSendFile",
    "TtadkClaudeChatStop",
    "TtadkCursorChat",
    "TtadkCursorChatSend",
    "TtadkCursorChatSendFile",
    "TtadkCursorChatStop",
    "ClaudeChat",
    "ClaudeChatSend",
    "ClaudeChatSendFile",
    "ClaudeChatStop",
    "CursorChat",
    "CursorChatSend",
    "CursorChatSendFile",
    "CursorChatStop",
  },
  keys = {
    -- The one shortcut: send to the remembered agent (picker on first use).
    { "<F7>", "<cmd>CodeChatSendFile<cr>", mode = "n", desc = "Send current file to AI agent" },
    { "<F7>", ":<C-u>CodeChatSend<cr>", mode = "v", desc = "Send selection to AI agent" },
    -- Helpers: focus the agent terminal (to answer prompts) / switch agent.
    { "<leader>ac", "<cmd>CodeChat<cr>", desc = "Focus/toggle AI agent terminal" },
    { "<leader>ap", "<cmd>CodeChatPick<cr>", desc = "Pick AI agent for <F7>" },
  },
  opts = {
    -- Customize how each agent is launched. `command` can be a plain binary, a
    -- full shell command line (run via your $SHELL), or an argv list. Use
    -- `setup` to run prep steps first (chained with `&&` in your shell), e.g.
    -- switching node versions before a `ttadk` wrapper.
    -- `nvm` is a shell function from ~/.bashrc / ~/.zshrc, not an executable, so
    -- `login = true` runs the pipeline via an interactive login shell that
    -- sources your rc files. Set `login_shell` if your shell isn't vim.o.shell.
    --
    -- Four candidates are offered in the picker (in `order`):
    --   1. ttadk Claude  -- Claude via the `ttadk` wrapper
    --   2. ttadk Cursor  -- Cursor CLI via the `ttadk` wrapper
    --   3. Claude        -- the plain `claude` binary (from config.lua defaults)
    --   4. Cursor        -- the plain `cursor-agent` binary (from defaults)
    agents = {
      ttadk_claude = {
        label = "ttadk Claude",
        command_prefix = "TtadkClaudeChat",
        order = 1,
        login = true,
        setup = { "nvm use 22" }, -- runs before `command`
        command = "ttadk code -t claude -a --dangerously-skip-permissions -m es1_orange_o46",
        -- env = { PATH = "/path/to/node22/bin:" .. vim.env.PATH },
      },
      ttadk_cursor = {
        label = "ttadk Cursor",
        command_prefix = "TtadkCursorChat",
        order = 2,
        login = true,
        setup = { "nvm use 22" },
        command = { "ttadk", "code", "-t", "cursor-cli" },
      },
      -- Pure `claude` / `cursor-agent` binaries (launched directly). Command,
      -- labels and fallbacks come from codechat's defaults in config.lua; we
      -- only set the picker order here.
      claude = { order = 3 },
      cursor = { order = 4 },
    },
  },
}
