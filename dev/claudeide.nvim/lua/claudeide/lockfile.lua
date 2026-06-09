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

---@param pid integer
---@return boolean
local function is_process_alive(pid)
  if not pid or pid <= 0 then
    return false
  end
  if pid == vim.fn.getpid() then
    return true
  end
  return pcall(uv.kill, pid, 0)
end

---@param path string
---@return table|nil
local function read_lock(path)
  local fd, err = uv.fs_open(path, "r", 0)
  if not fd then
    return nil
  end
  local stat = uv.fs_fstat(fd)
  local size = stat and stat.size or 0
  if size <= 0 or size > 4096 then
    uv.fs_close(fd)
    return nil
  end
  local data = uv.fs_read(fd, size)
  uv.fs_close(fd)
  if not data then
    return nil
  end
  local ok, decoded = util.json_decode(data)
  if not ok or type(decoded) ~= "table" then
    return nil
  end
  return decoded
end

--- Remove lock files left behind by dead Neovim instances (or orphaned .tmp files).
function M.remove_stale()
  local dir = lock_dir()
  local names = uv.fs_scandir(dir)
  if not names then
    return
  end
  while true do
    local name, typ = uv.fs_scandir_next(names)
    if not name then
      break
    end
    if typ == "file" and (name:match("%.lock$") or name:match("%.lock%.tmp$")) then
      local path = dir .. "/" .. name
      if name:match("%.tmp$") then
        pcall(uv.fs_unlink, path)
      else
        local lock = read_lock(path)
        if not lock or not is_process_alive(lock.pid) then
          pcall(uv.fs_unlink, path)
        end
      end
    end
  end
end

--- Remove every lock file owned by the current Neovim process.
function M.remove_owned()
  local pid = vim.fn.getpid()
  local dir = lock_dir()
  local names = uv.fs_scandir(dir)
  if names then
    while true do
      local name, typ = uv.fs_scandir_next(names)
      if not name then
        break
      end
      if typ == "file" and name:match("%.lock$") then
        local path = dir .. "/" .. name
        local lock = read_lock(path)
        if lock and lock.pid == pid then
          pcall(uv.fs_unlink, path)
        end
      end
    end
  end
  if M.current then
    pcall(uv.fs_unlink, M.current)
    M.current = nil
  end
end

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
    ideName = "TikTok VimPlugin",
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

--- Remove all lock files owned by this Neovim instance.
function M.remove()
  M.remove_owned()
end

return M
