-- codechat.nvim: drive CLI coding agents (Claude, Cursor, ...) from Neovim by
-- running each in its own terminal and injecting the current file/selection
-- (plus an optional typed comment) into its input box.

local config = require("codechat.config")
local util = require("codechat.util")
local terminal = require("codechat.terminal")
local ui = require("codechat.ui")
local history = require("codechat.history")

local M = {}

-- Options shared by all agents (overridable per-agent in config).
local SHARED_KEYS = {
  "win",
  "bracketed_paste",
  "auto_submit",
  "submit_delay",
  "prompt_for_comment",
  "include_code",
  "startup_delay",
  "scrollback",
  "input",
  "format",
  "log_level",
}

--- Build the effective config for an agent: shared options overlaid with the
--- agent's own definition (command, args, label, overrides).
---@param name string
---@return table|nil
local function agent_cfg(name)
  local o = config.options
  local agent = o.agents and o.agents[name]
  if not agent then
    util.error("unknown agent: " .. tostring(name))
    return nil
  end
  local base = {}
  for _, k in ipairs(SHARED_KEYS) do
    base[k] = o[k]
  end
  return vim.tbl_deep_extend("force", base, agent)
end

--- Capture the last visual selection from the '< '> marks.
--- Designed to be called from a `:<C-u>...` visual-mode command, where the
--- marks are set after leaving visual mode.
---@return table|nil { path, start_line, end_line, code }
local function captured_selection()
  local buf = vim.api.nvim_get_current_buf()
  if vim.bo[buf].buftype ~= "" then
    return nil
  end
  local path = vim.api.nvim_buf_get_name(buf)
  if path == "" then
    return nil
  end
  local s = vim.api.nvim_buf_get_mark(buf, "<")
  local e = vim.api.nvim_buf_get_mark(buf, ">")
  local sl, el = s[1], e[1]
  if sl == 0 or el == 0 then
    return nil
  end
  if sl > el then
    sl, el = el, sl
  end
  local lines = vim.api.nvim_buf_get_lines(buf, sl - 1, el, false)
  return { path = path, start_line = sl, end_line = el, code = table.concat(lines, "\n") }
end

--- The current file as a whole (no line range / no code).
---@return table|nil { path }
local function current_file()
  local buf = vim.api.nvim_get_current_buf()
  if vim.bo[buf].buftype ~= "" then
    return nil
  end
  local path = vim.api.nvim_buf_get_name(buf)
  if path == "" then
    return nil
  end
  return { path = path }
end

local function reference(sel)
  if not sel.start_line then
    return "@" .. sel.relpath
  end
  if sel.start_line == sel.end_line then
    return string.format("@%s (L%d)", sel.relpath, sel.start_line)
  end
  return string.format("@%s (L%d-%d)", sel.relpath, sel.start_line, sel.end_line)
end

local function default_format(sel)
  local parts = { reference(sel) }
  if sel.include_code and sel.code and sel.code ~= "" then
    parts[#parts + 1] = "```" .. (sel.ext or "")
    parts[#parts + 1] = sel.code
    parts[#parts + 1] = "```"
  end
  if sel.comment and sel.comment ~= "" then
    parts[#parts + 1] = sel.comment
  end
  return table.concat(parts, "\n")
end

---@param cfg table effective agent config
---@param selection table
---@param comment string
local function build_payload(cfg, selection, comment)
  local data = {
    relpath = util.relpath(selection.path),
    start_line = selection.start_line,
    end_line = selection.end_line,
    ext = vim.fn.fnamemodify(selection.path, ":e"),
    code = selection.code,
    comment = comment or "",
    include_code = cfg.include_code,
  }
  local fmt = cfg.format or default_format
  return fmt(data)
end

--- Shared send flow: build context from `selection`, optionally prompt for a
--- comment, send to the agent, then return to the code window in normal mode.
---@param name string
---@param selection table|nil
local function send_context(name, selection)
  local cfg = agent_cfg(name)
  if not cfg then
    return
  end
  if not selection then
    util.warn("no file/selection to send")
    return
  end
  local origin = vim.api.nvim_get_current_win()
  local function deliver(comment)
    local payload = build_payload(cfg, selection, comment)
    history.append(name, payload)
    terminal.send(name, cfg, payload, false)
    -- Return to the code window in normal mode; let the agent work on the side.
    vim.schedule(function()
      if vim.api.nvim_win_is_valid(origin) then
        pcall(vim.api.nvim_set_current_win, origin)
      end
      vim.cmd("stopinsert")
    end)
  end

  if cfg.prompt_for_comment then
    -- Launch the agent now so it warms up while the comment box is open; by the
    -- time the user submits, the input box is ready (no first-launch delay).
    terminal.prewarm(name, cfg)
    ui.input(cfg.input, {
      title = "Message to " .. (cfg.label or name) .. "  →  " .. reference({
        relpath = util.relpath(selection.path),
        start_line = selection.start_line,
        end_line = selection.end_line,
      }),
      history = history.recent(10),
      on_submit = deliver,
      on_send = function(comment)
        local send_cfg = vim.tbl_extend("force", cfg, { auto_submit = false, newline_before = true })
        local ref = reference({
          relpath = util.relpath(selection.path),
          start_line = selection.start_line,
          end_line = selection.end_line,
        })
        local text = (comment ~= "") and (ref .. "\n" .. comment) or ref
        history.append(name, text)
        terminal.send(name, send_cfg, text, false)
        vim.schedule(function()
          if vim.api.nvim_win_is_valid(origin) then
            pcall(vim.api.nvim_set_current_win, origin)
          end
          vim.cmd("stopinsert")
        end)
      end,
    })
  else
    deliver("")
  end
end

--- Send the current visual selection (file + line range) to an agent.
---@param name string
function M.send_selection(name)
  send_context(name, captured_selection())
end

--- Send the current file (whole-file context) to an agent.
---@param name string
function M.send_file(name)
  send_context(name, current_file())
end

--- Toggle an agent's terminal.
---@param name string
function M.toggle(name)
  local cfg = agent_cfg(name)
  if cfg then
    terminal.toggle(name, cfg)
  end
end

--- Stop an agent's terminal.
---@param name string
function M.stop(name)
  terminal.stop(name)
  util.info((agent_cfg(name) and agent_cfg(name).label or name) .. " stopped")
end

-- The agent <F9> last routed to (in-memory only). Used as a tie-breaker when
-- more than one chat terminal is alive; NOT persisted across restarts.
M.active = nil

--- Names of agents whose chat terminal is currently running.
---@return string[]
local function alive_agents()
  local alive = {}
  for name in pairs(config.options.agents) do
    if terminal.is_alive(name) then
      alive[#alive + 1] = name
    end
  end
  return alive
end

--- Ordered list of agent names for pickers. Sorted by an optional numeric
--- `order` field first (lower comes first), then alphabetically by label.
---@return string[] names, string[] labels
local function agent_list()
  local names = {}
  for name in pairs(config.options.agents) do
    names[#names + 1] = name
  end
  table.sort(names, function(a, b)
    local aa, ab = config.options.agents[a], config.options.agents[b]
    local oa = aa.order or math.huge
    local ob = ab.order or math.huge
    if oa ~= ob then
      return oa < ob
    end
    local la = aa.label or a
    local lb = ab.label or b
    return la < lb
  end)
  local labels = {}
  for i, name in ipairs(names) do
    labels[i] = config.options.agents[name].label or name
  end
  return names, labels
end

--- Record the active agent (in-memory).
---@param name string
function M.set_agent(name)
  if not config.options.agents[name] then
    util.error("unknown agent: " .. tostring(name))
    return
  end
  M.active = name
  util.info("active agent: " .. (config.options.agents[name].label or name))
end

--- Show a picker to choose the active agent, then call cb(name).
--- Prefers a Snacks popup; falls back to vim.ui.select (which may be a small
--- cmdline prompt depending on your config).
---@param cb fun(name: string)
function M.pick_agent(cb)
  local names, labels = agent_list()
  local select = vim.ui.select
  local opts = { prompt = "Send to which AI agent?" }
  local ok, snacks = pcall(require, "snacks")
  if ok and snacks.picker and type(snacks.picker.select) == "function" then
    select = snacks.picker.select
    -- Items are plain agent labels, not files. `layout.preview = false` makes
    -- Snacks hide the preview window entirely (it gets added to the layout's
    -- `hidden` list), so we get neither the "Item has no `file`" error nor a
    -- "no preview available" pane -- just a titled input + the agent list. This
    -- overrides any global picker layout the user has configured.
    opts.snacks = { preview = "none", layout = { preview = false } }
  end
  select(labels, opts, function(_, idx)
    if not idx then
      return
    end
    M.set_agent(names[idx])
    if cb then
      cb(names[idx])
    end
  end)
end

--- Resolve which agent to use, then call cb(name):
---   * no chat terminal running  -> always show the picker
---   * exactly one running        -> use it
---   * several running            -> use the last-used one if alive, else pick
---@param cb fun(name: string)
function M.ensure_agent(cb)
  local alive = alive_agents()
  if #alive == 0 then
    return M.pick_agent(cb)
  end
  if #alive == 1 then
    M.active = alive[1]
    return cb(alive[1])
  end
  if M.active and vim.tbl_contains(alive, M.active) then
    return cb(M.active)
  end
  M.pick_agent(cb)
end

--- Send the current visual selection to the active agent (picking on first use).
function M.send_active_selection()
  local sel = captured_selection()
  M.ensure_agent(function(name)
    send_context(name, sel)
  end)
end

--- Send the current file to the active agent (picking on first use).
function M.send_active_file()
  local sel = current_file()
  M.ensure_agent(function(name)
    send_context(name, sel)
  end)
end

--- Toggle/focus the active agent's terminal (picking on first use).
function M.toggle_active()
  M.ensure_agent(function(name)
    M.toggle(name)
  end)
end

local function create_commands()
  local cmd = vim.api.nvim_create_user_command

  -- Unified, agent-agnostic commands routed to the remembered agent.
  cmd("CodeChat", function()
    M.toggle_active()
  end, { desc = "Toggle the active AI agent terminal" })
  cmd("CodeChatSend", function()
    M.send_active_selection()
  end, { range = true, desc = "Send selection to the active AI agent" })
  cmd("CodeChatSendFile", function()
    M.send_active_file()
  end, { desc = "Send the current file to the active AI agent" })
  cmd("CodeChatPick", function()
    M.pick_agent(function() end)
  end, { desc = "Choose which AI agent <F9> sends to" })
  cmd("CodeChatStop", function()
    local alive = alive_agents()
    if #alive == 0 then
      util.info("no agent terminal running")
      return
    end
    for _, name in ipairs(alive) do
      M.stop(name)
    end
  end, { desc = "Stop any running AI agent terminals" })
end

---@param opts table|nil
function M.setup(opts)
  config.setup(opts)
  util.log_level = config.options.log_level
  create_commands()
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = vim.api.nvim_create_augroup("CodeChatCleanup", { clear = true }),
    callback = function()
      terminal.shutdown()
    end,
  })
end

return M
