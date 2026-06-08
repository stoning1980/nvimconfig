-- Discovery lock file management: ~/.claude/ide/<port>.lock

local util = require("claudeide.util")
local uv = vim.loop or vim.uv

local M = {}

local function lock_dir()
  return vim.fn.expand("~/.claude/ide")
end

---@param port integer
---@return string
local function lock_path(port)
  return lock_dir() .. "/" .. port .. ".lock"
end

M.current = nil ---@type string|nil current lock file path

--- Write the lock file for the given port and auth token.
---@param port integer
---@param auth_token string
---@return boolean ok
---@return string|nil err
function M.write(port, auth_token)
  vim.fn.mkdir(lock_dir(), "p")
  local data = {
    pid = vim.fn.getpid(),
    workspaceFolders = { vim.fn.getcwd() },
    ideName = "Neovim",
    transport = "ws",
    authToken = auth_token,
  }
  local ok, json = pcall(util.json_encode, data)
  if not ok then
    return false, "encode failed: " .. tostring(json)
  end

  local path = lock_path(port)
  local tmp = path .. ".tmp"
  local fd, err = uv.fs_open(tmp, "w", tonumber("600", 8))
  if not fd then
    return false, "open failed: " .. tostring(err)
  end
  uv.fs_write(fd, json)
  uv.fs_close(fd)
  local renamed = uv.fs_rename(tmp, path)
  if not renamed then
    pcall(uv.fs_unlink, tmp)
    return false, "rename failed"
  end
  M.current = path
  return true
end

--- Remove the current lock file (if any).
function M.remove()
  if M.current then
    pcall(uv.fs_unlink, M.current)
    M.current = nil
  end
end

return M
