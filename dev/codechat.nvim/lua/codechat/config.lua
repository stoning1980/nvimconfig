local M = {}

-- Shared options apply to every agent; each agent in `agents` may override any
-- of them, and additionally defines its `command`/`args`/labels.
M.defaults = {
  -- Snacks terminal window options.
  win = {
    position = "right",
    width = 0.4,
    height = 0.5,
  },
  -- Wrap injected text in bracketed-paste markers so multi-line content lands
  -- in the input box as a single paste instead of executing line-by-line.
  bracketed_paste = true,
  -- Append a carriage return so the agent submits the message immediately.
  auto_submit = true,
  -- Delay (ms) before sending the submit Enter as a separate keystroke. TUIs
  -- debounce paste input, so the Enter must arrive after the paste is processed
  -- or it gets swallowed (message stays in the box, unsubmitted).
  submit_delay = 150,
  -- Pop up an input window to type a comment before sending.
  prompt_for_comment = true,
  -- Include the selected code as a fenced block. Off by default: the file
  -- reference + line range is enough for the agent to read the code itself.
  include_code = false,
  -- Milliseconds to wait after first launching the TUI before injecting text
  -- (a cold start loads the binary, checks auth, and renders before the input
  -- box accepts input).
  startup_delay = 1500,
  -- Terminal scrollback lines kept per agent buffer (Neovim default is 10000,
  -- max 100000). Higher keeps more of the transcript scrollable.
  scrollback = 100000,
  -- Comment input window (Snacks float). `history_height` sizes the read-only
  -- panel shown beneath it listing recently sent messages.
  input = {
    width = 0.6,
    height = 0.3,
    history_height = 0.25,
  },
  -- How a message is rendered before being sent. Receives a table:
  --   { relpath, start_line, end_line, ext, code, comment, include_code }
  -- and must return the string to inject.
  format = nil,
  log_level = "info",

  -- Per-agent definitions. Each runs in its own terminal and gets its own set
  -- of `<prefix>` / `<prefix>Send` / `<prefix>SendFile` / `<prefix>Stop` commands.
  --
  -- `command` may be:
  --   * a simple binary name/path (string, no spaces) -> run directly as argv,
  --   * a full shell command line (string with spaces) -> run via your $SHELL,
  --     e.g. "ttadk code -t claude -a --dangerously-skip-permissions -m foo",
  --   * an argv list, e.g. { "ttadk", "code", "-t", "cursor-cli" }.
  -- `setup`    : one or more shell steps to run BEFORE `command`, chained with
  --              `&&` in your $SHELL. Accepts a string or a list of strings, e.g.
  --                setup = { "cd ~/work/repo", "nvm use 22" }
  --              Use this when launching needs prep (cd, env managers, etc.).
  --              When set, the whole agent is launched as one shell pipeline.
  -- `args`     : extra arguments appended to `command`.
  -- `login`    : run the pipeline through an interactive login shell
  --              (`$SHELL -lic '...'`) so your rc files (~/.bashrc, ~/.zshrc)
  --              are sourced. REQUIRED when `setup` calls a shell *function*
  --              such as `nvm`, `conda`, or `asdf` (these are not executables).
  -- `login_shell`: shell program to use for `login` (default: your `vim.o.shell`
  --              or $SHELL), e.g. "/bin/zsh".
  -- `shell`    : force running through the shell even for a single-token command
  --              (useful when the wrapper needs your shell env, e.g. node/nvm).
  -- `env`      : table of VAR=value pairs added to the agent's environment, e.g.
  --              { PATH = "/path/to/node22/bin:" .. vim.env.PATH }.
  -- `fallbacks`: only used to resolve a missing single-token binary; ignored for
  --              shell lines / argv lists / setup pipelines / custom wrappers.
  -- `order`    : optional number controlling position in the agent picker (lower
  --              comes first). Agents without it sort after, alphabetically by label.
  agents = {
    claude = {
      label = "Claude",
      command = vim.fn.expand("~/.local/bin/claude"),
      setup = nil,
      login = false,
      login_shell = nil,
      args = {},
      shell = false,
      env = nil,
      command_prefix = "ClaudeChat",
      fallbacks = { "claude" },
      order = 3,
    },
    cursor = {
      label = "Cursor",
      command = vim.fn.expand("~/.local/bin/cursor-agent"),
      setup = nil,
      login = false,
      login_shell = nil,
      args = {},
      shell = false,
      env = nil,
      command_prefix = "CursorChat",
      fallbacks = { "cursor-agent", "agent" },
      order = 4,
    },
  },
}

M.options = vim.deepcopy(M.defaults)

-- Resolve an agent's command to an executable, trying configured fallbacks.
-- Only applies to a simple single-token binary; custom wrappers (shell command
-- lines, argv lists, or anything with spaces) are left exactly as configured.
local function resolve_command(agent)
  -- A setup pipeline runs in the shell (often after env managers like nvm), so
  -- the binary may not be on Nvim's PATH yet -- never second-guess it.
  if agent.setup ~= nil and agent.setup ~= "" then
    return
  end
  local command = agent.command
  if type(command) ~= "string" or command:find("%s") then
    return
  end
  if vim.fn.executable(command) == 1 then
    return
  end
  for _, fb in ipairs(agent.fallbacks or {}) do
    if vim.fn.executable(fb) == 1 then
      agent.command = fb
      return
    end
  end
end

---@param opts table|nil
function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
  for _, agent in pairs(M.options.agents) do
    resolve_command(agent)
  end
  return M.options
end

return M
