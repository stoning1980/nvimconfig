local M = {}

local LEVELS = { error = 1, warn = 2, info = 3, debug = 4 }

M.log_level = "info"

local function should_log(level)
  return (LEVELS[level] or 99) <= (LEVELS[M.log_level] or 3)
end

---@param level "error"|"warn"|"info"|"debug"
---@param msg string
function M.log(level, msg)
  if not should_log(level) then
    return
  end
  local vim_level = ({
    error = vim.log.levels.ERROR,
    warn = vim.log.levels.WARN,
    info = vim.log.levels.INFO,
    debug = vim.log.levels.DEBUG,
  })[level] or vim.log.levels.INFO
  vim.schedule(function()
    vim.notify("[claudeide] " .. msg, vim_level)
  end)
end

function M.error(msg)
  M.log("error", msg)
end
function M.warn(msg)
  M.log("warn", msg)
end
function M.info(msg)
  M.log("info", msg)
end
function M.debug(msg)
  M.log("debug", msg)
end

--- Generate a random UUID v4 string.
---@return string
function M.uuid()
  local template = "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx"
  return (
    template:gsub("[xy]", function(c)
      local v = (c == "x") and math.random(0, 15) or math.random(8, 11)
      return string.format("%x", v)
    end)
  )
end

--- Encode a Lua value to JSON.
---@param value any
---@return string
function M.json_encode(value)
  return vim.json.encode(value)
end

--- Decode a JSON string. Returns ok, value|err.
---@param str string
---@return boolean ok
---@return any value
function M.json_decode(str)
  return pcall(vim.json.decode, str)
end

--- Convert an absolute file path to a file:// URI.
---@param path string
---@return string
function M.path_to_uri(path)
  if vim.uri_from_fname then
    return vim.uri_from_fname(path)
  end
  return "file://" .. path
end

return M
