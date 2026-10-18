-- codechat.nvim: drive CLI coding agents (Claude, Cursor, Trae, Codex) in Neovim terminals.
-- Runs the agent's interactive TUI in a terminal and injects the current
-- file/selection + an optional typed comment into its input box.
--   <F9>   -> send to the active agent (normal: whole file, visual: selection).
--            On first use it pops a picker (ttadk Claude / ttadk Cursor /
--            Claude / Cursor / Relay / Trae / Codex) and remembers the choice across restarts. Change
--            it later with :CodeChatPick.
--   <S-F9> -> close the CodeChat window, terminal, and session (:CodeChatStop).
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
    "CodeChatStop",
  },
  keys = {
    -- The one shortcut: send to the remembered agent (picker on first use).
    { "<F9>", "<cmd>CodeChatSendFile<cr>", mode = "n", desc = "Send current file to AI agent" },
    { "<F9>", ":<C-u>CodeChatSend<cr>", mode = "v", desc = "Send selection to AI agent" },
    -- Shift+F9 closes the agent window and kills its terminal session.
    -- Terminals emit shifted F9 as <F21>, so map both spellings. Terminal mode
    -- is included so the key works while the agent window itself is focused.
    {
      "<S-F9>",
      "<cmd>CodeChatStop<cr>",
      mode = { "n", "v", "t" },
      desc = "Close CodeChat window, terminal, and session",
    },
    {
      "<F21>",
      "<cmd>CodeChatStop<cr>",
      mode = { "n", "v", "t" },
      desc = "Close CodeChat window, terminal, and session",
    },
    -- Helpers: focus the agent terminal (to answer prompts) / switch agent.
    { "<leader>ac", "<cmd>CodeChat<cr>", desc = "Focus/toggle AI agent terminal" },
    { "<leader>ap", "<cmd>CodeChatPick<cr>", desc = "Pick AI agent for <F9>" },
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
    -- All agents launch with full access and skip interactive permission checks.
    -- Claude and Cursor inherit their permission flags from config.lua defaults.
    -- Seven candidates are offered in the picker (in `order`):
    --   1. ttadk Claude  -- Claude via the `ttadk` wrapper
    --   2. ttadk Cursor  -- Cursor CLI via the `ttadk` wrapper
    --   3. Claude        -- the plain `claude` binary (from config.lua defaults)
    --   4. Cursor        -- the plain `cursor-agent` binary (from defaults)
    --   5. Relay         -- the plain `relay` binary (launched directly in bash)
    --   6. Trae          -- the plain `trae-cli` binary
    --   7. Codex         -- the plain `codex` binary
    -- ── Agent parameter reference ─────────────────────────────────────
    -- label          : display name shown in the :CodeChatPick picker.
    -- command        : how to launch the agent. Accepts three forms:
    --                  * "binary"              – plain executable (no spaces)
    --                  * "cmd --flag -x val"   – shell command line (has spaces)
    --                  * { "cmd", "--flag" }    – argv list (no shell involved)
    -- args           : extra arguments appended to `command` (list of strings).
    -- setup          : shell steps executed BEFORE `command`, joined with `&&`.
    --                  string or list, e.g. { "cd ~/repo", "nvm use 22" }.
    -- login          : if true, run via interactive login shell (`$SHELL -lic`)
    --                  so rc files are sourced. REQUIRED when `setup` calls a
    --                  shell function (nvm, conda, asdf, etc.).
    -- login_shell    : override the login shell (default: vim.o.shell / $SHELL).
    -- shell          : force shell execution even for a single-token command.
    -- env            : { VAR = "value" } pairs added to the agent's environment.
    -- fallbacks      : list of alternative binary names tried when the primary
    --                  `command` is not found on PATH (single-token only).
    -- order          : position in the picker (lower = higher). Agents without
    --                  `order` sort after numbered ones, alphabetically.
    -- ────────────────────────────────────────────────────────────────────
    agents = {
      ttadk_claude = {
        label = "ttadk Claude",
        order = 1,
        login = true,
        setup = { "nvm use 22" }, -- runs before `command`
        command = "ttadk code -t claude -a --dangerously-skip-permissions -m es1_orange_o46",
        -- env = { PATH = "/path/to/node22/bin:" .. vim.env.PATH },
      },
      ttadk_cursor = {
        label = "ttadk Cursor",
        order = 2,
        login = true,
        setup = { "nvm use 22" },
        command = { "ttadk", "code", "-t", "cursor-cli" },
        args = { "-a", "--force --sandbox disabled --approve-mcps --trust" },
      },
      claude = {
        label = "Claude",
        order = 3,
        login = true,
        setup = { "nvm use 22" },
        command = "cl",
        fallbacks = { "claude" },
      },
      cursor = {
        label = "Cursor",
        order = 4,
        command = vim.fn.expand("~/.local/bin/cursor-agent"),
        fallbacks = { "cursor-agent", "agent" },
      },
      relay = {
        label = "Relay",
        order = 5,
        command = "relay",
        args = { "--dangerously-skip-permissions" },
      },
      trae = {
        label = "Trae",
        order = 6,
        command = vim.fn.expand("~/.local/bin/trae-cli"),
        args = { "--dangerously-bypass-approvals-and-sandbox" },
        fallbacks = { "trae-cli", "traecli" },
      },
      codex = {
        label = "Codex",
        order = 7,
        command = vim.fn.expand("~/.local/bin/codex"),
        args = { "--dangerously-bypass-approvals-and-sandbox" },
        fallbacks = { "codex" },
      },
    },
  },
}
