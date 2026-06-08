local M = {}

local LEVELS = { error = 1, warn = 2, info = 3, debug = 4 }
M.log_level = "info"

---@param level "error"|"warn"|"info"|"debug"
---@param msg string
function M.log(level, msg)
  if (LEVELS[level] or 99) > (LEVELS[M.log_level] or 3) then
    return
  end
  local vl = ({
    error = vim.log.levels.ERROR,
    warn = vim.log.levels.WARN,
    info = vim.log.levels.INFO,
    debug = vim.log.levels.DEBUG,
  })[level] or vim.log.levels.INFO
  vim.schedule(function()
    vim.notify("[codechat] " .. msg, vl)
  end)
end

function M.error(m)
  M.log("error", m)
end
function M.warn(m)
  M.log("warn", m)
end
function M.info(m)
  M.log("info", m)
end
function M.debug(m)
  M.log("debug", m)
end

--- Format an absolute path relative to cwd when inside the workspace.
---@param path string
---@return string
function M.relpath(path)
  if path == nil or path == "" then
    return path
  end
  local cwd = vim.fn.getcwd()
  if path:sub(1, #cwd) == cwd then
    local rel = path:sub(#cwd + 2)
    if rel ~= "" then
      return rel
    end
  end
  return path
end

return M
