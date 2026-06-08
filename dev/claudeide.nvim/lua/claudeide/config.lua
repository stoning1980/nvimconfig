local M = {}

M.defaults = {
  -- Start the IDE server automatically when the plugin loads so a running
  -- `claude` CLI session can connect to it with /ide.
  auto_start = true,
  -- Log verbosity: "error" | "warn" | "info" | "debug".
  log_level = "info",
  -- Port range for the WebSocket server.
  port_range = { 10000, 65535 },
  -- Track and broadcast cursor/selection changes to Claude.
  track_selection = true,
}

M.options = vim.deepcopy(M.defaults)

---@param opts table|nil
function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
  return M.options
end

return M
