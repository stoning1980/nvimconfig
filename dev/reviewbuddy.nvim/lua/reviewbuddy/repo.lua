local M = {}

---@param command string[]
---@return string|nil
local function git(command)
  local output = vim.fn.systemlist(command)
  if vim.v.shell_error ~= 0 or #output == 0 then
    return nil
  end
  return output[1]
end

---@param root string
---@return table|nil
function M.for_root(root)
  if root == "" then
    return nil
  end
  root = vim.uv.fs_realpath(root) or root
  root = git({ "git", "-C", root, "rev-parse", "--show-toplevel" })
  if not root then
    return nil
  end
  root = vim.uv.fs_realpath(root) or root
  return {
    root = root,
    branch = git({ "git", "-C", root, "branch", "--show-current" }) or "HEAD",
    revision = git({ "git", "-C", root, "rev-parse", "HEAD" }) or "unknown",
  }
end

---@param path string
---@return table|nil
function M.for_path(path)
  if path == "" then
    return nil
  end
  path = vim.uv.fs_realpath(path) or path
  local directory = vim.fs.dirname(path)
  local info = M.for_root(directory)
  if not info then
    return nil
  end
  local relpath = vim.fs.relpath(info.root, path)
  if not relpath then
    return nil
  end
  info.relpath = relpath
  return info
end

return M
