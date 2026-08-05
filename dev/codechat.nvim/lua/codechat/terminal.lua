-- Manage one CLI agent per name running inside a Snacks terminal, and inject
-- text into its input box via the terminal job channel.

local util = require("codechat.util")
local uv = vim.uv or vim.loop

local M = {}

-- Per-agent terminal state, keyed by agent name.
---@type table<string, { win: snacks.win|nil, launched_at: integer|nil }>
local states = {}

local function st(name)
  states[name] = states[name] or {}
  return states[name]
end

local function snacks()
  local ok, s = pcall(require, "snacks")
  if not ok then
    return nil
  end
  return s
end

local function job_of(buf)
  if buf and vim.api.nvim_buf_is_valid(buf) then
    return vim.b[buf].terminal_job_id
  end
  return nil
end

--- The agent's terminal buffer is alive (process running), regardless of visibility.
function M.is_alive(name)
  local s = st(name)
  return s.win ~= nil
    and s.win.buf ~= nil
    and vim.api.nvim_buf_is_valid(s.win.buf)
    and job_of(s.win.buf) ~= nil
end

--- The agent's terminal window is currently visible.
function M.is_open(name)
  local s = st(name)
  return s.win ~= nil and s.win.win ~= nil and vim.api.nvim_win_is_valid(s.win.win)
end

-- Collect `setup` into an ordered list of non-empty shell steps.
local function setup_steps(setup)
  local steps = {}
  if type(setup) == "table" then
    for _, s in ipairs(setup) do
      if type(s) == "string" and vim.trim(s) ~= "" then
        steps[#steps + 1] = s
      end
    end
  elseif type(setup) == "string" and vim.trim(setup) ~= "" then
    steps[#steps + 1] = setup
  end
  return steps
end

-- Turn `command` (+ args) into a single shell command-line string.
local function command_line(command, args)
  local line
  if type(command) == "table" then
    local parts = {}
    for _, c in ipairs(command) do
      parts[#parts + 1] = vim.fn.shellescape(c)
    end
    line = table.concat(parts, " ")
    for _, a in ipairs(args) do
      line = line .. " " .. vim.fn.shellescape(a)
    end
  else
    line = command
    if #args > 0 then
      line = line .. " " .. table.concat(args, " ")
    end
  end
  return line
end

--- Build the command passed to Snacks/jobstart from an agent config.
---   * `login = true` -> run the pipeline through an interactive login shell
---     (`$SHELL -lic '<pipeline>'`) so your rc files are sourced and shell
---     functions like `nvm` / `conda` / `asdf` are available.
---   * `setup` present, or string command with spaces, or `shell = true`
---     -> a single shell pipeline (setup steps `&&` command), run via $SHELL,
---        so prep (cd, nvm use, env managers) and wrappers like
---        `ttadk code -t claude` work with your shell environment.
---   * table command       -> argv list (+ args), run directly (no shell)
---   * single-token string -> argv list (+ args), run directly (no shell)
---@param cfg table
---@return string|string[]
function M.build_cmd(cfg)
  local command = cfg.command
  local args = cfg.args or {}
  local steps = setup_steps(cfg.setup)

  local needs_shell = #steps > 0
    or cfg.shell == true
    or cfg.login == true
    or (type(command) == "string" and command:find("%s") ~= nil)

  if needs_shell then
    steps[#steps + 1] = command_line(command, args)
    local pipeline = table.concat(steps, " && ")
    if cfg.login then
      -- An interactive (-i) login (-l) shell sources ~/.bash_profile + ~/.bashrc
      -- (or ~/.zprofile + ~/.zshrc), where managers like nvm define functions.
      local sh = cfg.login_shell or vim.o.shell or vim.env.SHELL or "bash"
      return { sh, "-lic", pipeline }
    end
    return pipeline
  end

  -- Direct argv, no shell.
  local cmd = type(command) == "table" and vim.deepcopy(command) or { command }
  for _, a in ipairs(args) do
    cmd[#cmd + 1] = a
  end
  return cmd
end

--- Open (or reveal) the agent terminal. Returns true if newly launched.
---@param name string
---@param cfg table
---@param focus boolean|nil whether to focus/enter the terminal (default true)
---@return boolean newly_launched
function M.open(name, cfg, focus)
  local s = snacks()
  if not s then
    util.error("snacks.nvim is required")
    return false
  end
  local want_focus = focus ~= false
  local state = st(name)
  if M.is_alive(name) then
    if not M.is_open(name) then
      state.win:show()
    end
    return false
  end

  state.win = s.terminal.open(M.build_cmd(cfg), {
    cwd = vim.fn.getcwd(),
    env = cfg.env,
    interactive = want_focus,
    start_insert = want_focus,
    auto_insert = want_focus,
    auto_close = false,
    win = vim.tbl_extend("force", { position = "right", enter = want_focus }, cfg.win or {}),
  })
  -- Keep the full agent transcript scrollable. Terminal buffers default to
  -- 10000 lines of scrollback and drop the oldest beyond that; raise it to the
  -- maximum (100000) so long sessions stay reviewable. Scoped to this buffer so
  -- other terminals are unaffected. (No effect while a TUI paints on the
  -- alternate screen, but harmless there.)
  if state.win and state.win.buf and vim.api.nvim_buf_is_valid(state.win.buf) then
    vim.bo[state.win.buf].scrollback = cfg.scrollback or 100000
  end
  state.launched_at = uv.now()
  return true
end

--- Launch the agent in the background if not running, so it can warm up while
--- the user does something else (e.g. typing a comment).
---@param name string
---@param cfg table
function M.prewarm(name, cfg)
  M.open(name, cfg, false)
end

--- Focus the agent's terminal window and enter Terminal-insert mode so the
--- user can answer CLI prompts (y/n, arrow-key menus, etc.).
---@param state table
---@return boolean focused
local function focus_win(state)
  if state.win and state.win.win and vim.api.nvim_win_is_valid(state.win.win) then
    pcall(vim.api.nvim_set_current_win, state.win.win)
    vim.cmd("startinsert")
    return true
  end
  return false
end

--- Reveal + focus the agent terminal in insert mode (launch if needed).
---@param name string
---@param cfg table
function M.focus(name, cfg)
  local state = st(name)
  if not M.is_alive(name) then
    M.open(name, cfg, true)
    return
  end
  if not M.is_open(name) then
    state.win:show()
  end
  focus_win(state)
end

--- Toggle terminal: open+focus when closed/hidden, focus+insert when visible
--- but unfocused, hide when already focused (launch if needed).
---@param name string
---@param cfg table
function M.toggle(name, cfg)
  local state = st(name)
  if M.is_open(name) then
    if state.win.win == vim.api.nvim_get_current_win() then
      state.win:hide()
    else
      focus_win(state)
    end
    return
  end
  M.focus(name, cfg)
end

local function inject(name, cfg, text)
  local state = st(name)
  local job = job_of(state.win and state.win.buf)
  if not job then
    util.error((cfg.label or name) .. " terminal is not ready")
    return false
  end
  local payload = text
  if cfg.bracketed_paste then
    payload = "\27[200~" .. text .. "\27[201~"
  end
  if cfg.newline_before then
    payload = "\n" .. payload
  end
  vim.fn.chansend(job, payload)

  -- Submit as a SEPARATE, slightly-delayed keystroke. TUIs debounce pasted
  -- input, so a carriage return sent in the same write (or right after the
  -- bracketed-paste end marker) gets absorbed instead of submitting.
  if cfg.auto_submit then
    vim.defer_fn(function()
      local j = job_of(state.win and state.win.buf)
      if j then
        vim.fn.chansend(j, "\r")
      end
    end, cfg.submit_delay or 150)
  end
  return true
end

--- Ensure the agent terminal is running, then inject text into its input box.
--- Waits only for whatever warm-up time remains since launch, so pre-warming
--- (e.g. while a comment box is open) removes the wait entirely.
---@param name string
---@param cfg table
---@param text string
---@param focus boolean|nil whether to focus the terminal (default false for sends)
function M.send(name, cfg, text, focus)
  M.open(name, cfg, focus == true)
  local state = st(name)
  local need = cfg.startup_delay or 1500
  local elapsed = state.launched_at and (uv.now() - state.launched_at) or need
  local wait = math.max(0, need - elapsed)
  if wait > 0 then
    vim.defer_fn(function()
      inject(name, cfg, text)
    end, wait)
  else
    inject(name, cfg, text)
  end
end

--- Stop one agent terminal: terminate the child job, then close the window.
--- Stopping the job first prevents the CLI's TUI from leaking terminal-control
--- escape sequences to the parent terminal as it dies.
---@param name string
function M.stop(name)
  local state = st(name)
  local buf = state.win and state.win.buf
  if buf and vim.api.nvim_buf_is_valid(buf) then
    local job = vim.b[buf].terminal_job_id
    if job then
      pcall(vim.fn.jobstop, job)
    end
  end
  if state.win then
    pcall(function()
      state.win:close()
    end)
  end
  state.win = nil
  state.launched_at = nil
end

--- Stop all agent terminals.
function M.stop_all()
  for name, _ in pairs(states) do
    M.stop(name)
  end
end

--- Cleanly shut down every agent on Neovim exit: stop all child jobs and wait
--- briefly for them to actually terminate, so a dying TUI cannot dump escape
--- sequences into the parent terminal after Nvim's UI is gone.
function M.shutdown()
  local jobs = {}
  for _, state in pairs(states) do
    local buf = state.win and state.win.buf
    if buf and vim.api.nvim_buf_is_valid(buf) then
      local job = vim.b[buf].terminal_job_id
      if job then
        jobs[#jobs + 1] = job
        pcall(vim.fn.jobstop, job)
      end
    end
  end
  if #jobs > 0 then
    -- Give the processes up to 300ms to exit before Nvim continues tearing down.
    pcall(vim.fn.jobwait, jobs, 300)
  end
  for name, state in pairs(states) do
    if state.win then
      pcall(function()
        state.win:close()
      end)
    end
    states[name] = nil
  end
end

return M
