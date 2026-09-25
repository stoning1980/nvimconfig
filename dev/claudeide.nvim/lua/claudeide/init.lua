-- claudeide.nvim: a from-scratch Claude Code IDE integration for Neovim.
-- Implements the WebSocket MCP protocol so the Claude CLI connects to Neovim.

local config = require("claudeide.config")
local util = require("claudeide.util")
local server = require("claudeide.server")
local lockfile = require("claudeide.lockfile")
local mcp = require("claudeide.mcp")
local selection = require("claudeide.selection")
local diff = require("claudeide.diff")

local M = {}

M.started = false

--- Start the WebSocket server and write the discovery lock file.
---@return boolean ok
function M.start()
  if M.started then
    return true
  end
  lockfile.remove_stale()
  local auth_token = util.uuid()
  local port, err = server.start({
    auth_token = auth_token,
    on_message = mcp.handle,
    port_range = config.options.port_range,
  })
  if not port then
    util.error("failed to start server: " .. tostring(err))
    return false
  end

  local ok, lock_err = lockfile.write(port, auth_token)
  if not ok then
    util.error("failed to write lock file: " .. tostring(lock_err))
    server.stop()
    return false
  end

  if config.options.track_selection then
    selection.setup()
  end

  M.started = true
  M.port = port
  util.info("IDE server listening on 127.0.0.1:" .. port .. " - run /ide in your claude session to connect")
  return true
end

--- Stop the server, remove lock files, and tear down all plugin state.
---@param opts? { silent?: boolean }
function M.stop(opts)
  opts = opts or {}
  if not M.started and not server.is_running() then
    return
  end

  -- Reject pending diffs before closing sockets so the CLI does not hang.
  diff.teardown()
  selection.teardown()
  lockfile.remove()
  server.stop()

  M.started = false
  M.port = nil

  if not opts.silent then
    util.info("stopped")
  end
end

--- Ensure the server is running and tell the user how to connect.
function M.connect_hint()
  local already_running = M.started
  if not M.start() then
    return
  end
  -- A fresh start() already announced the port, so only speak up when the
  -- server was up beforehand and the keypress would otherwise look inert.
  if already_running then
    util.info("IDE server already listening on 127.0.0.1:" .. tostring(M.port) .. " - run /ide to connect")
  end
end

function M.status()
  local lines = {
    "claudeide.nvim status:",
    "  running: " .. tostring(server.is_running()),
    "  port: " .. tostring(M.port),
    "  clients connected: " .. tostring(server.client_count()),
    "  lock file: " .. tostring(lockfile.current),
    "  pending diff: " .. tostring(diff.has_pending()),
    "",
    "To connect: run `claude` in a terminal, then `/ide` and choose Neovim.",
  }
  vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
end

local function create_commands()
  local cmd = vim.api.nvim_create_user_command
  cmd("ClaudeIde", function()
    M.connect_hint()
  end, { desc = "Start the Claude IDE server and show connection instructions" })
  cmd("ClaudeIdeStart", function()
    M.start()
  end, { desc = "Start the Claude IDE server" })
  cmd("ClaudeIdeStop", function()
    M.stop()
  end, { desc = "Stop the Claude IDE server" })
  cmd("ClaudeIdeStatus", function()
    M.status()
  end, { desc = "Show Claude IDE status" })
  cmd("ClaudeIdeSend", function()
    selection.send_current_selection()
  end, { range = true, desc = "Send selection to Claude" })
  cmd("ClaudeIdeAdd", function(opts)
    selection.add_file(opts.args)
  end, { nargs = "?", complete = "file", desc = "Add a file to Claude context" })
  cmd("ClaudeIdeDiffAccept", function()
    diff.accept()
  end, { desc = "Accept the pending Claude diff" })
  cmd("ClaudeIdeDiffDeny", function()
    diff.deny()
  end, { desc = "Reject the pending Claude diff" })
end

--- Plugin entry point.
---@param opts table|nil
function M.setup(opts)
  config.setup(opts)
  util.log_level = config.options.log_level

  create_commands()

  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = vim.api.nvim_create_augroup("ClaudeIdeCleanup", { clear = true }),
    callback = function()
      pcall(M.stop, { silent = true })
    end,
  })

  if config.options.auto_start then
    vim.schedule(function()
      M.start()
    end)
  end
end

return M
