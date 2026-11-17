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

---@param path string
---@return table|nil
function M.for_path(path)
  if path == "" then
    return nil
  end
  path = vim.uv.fs_realpath(path) or path
  local directory = vim.fs.dirname(path)
  local root = git({ "git", "-C", directory, "rev-parse", "--show-toplevel" })
  if not root then
    return nil
  end
  root = vim.uv.fs_realpath(root) or root
  local relpath = vim.fs.relpath(root, path)
  if not relpath then
    return nil
  end
  return {
    root = root,
    relpath = relpath,
    branch = git({ "git", "-C", root, "branch", "--show-current" }) or "HEAD",
    revision = git({ "git", "-C", root, "rev-parse", "HEAD" }) or "unknown",
  }
end

return M
