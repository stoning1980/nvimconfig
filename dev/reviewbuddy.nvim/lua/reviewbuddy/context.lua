local M = {}

---@param value string
---@return string
local function trim_trailing_slash(value)
  return value:gsub("/+$", "")
end

---@param path string
---@param root string
---@return string|nil
function M.relative_path(path, root)
  path = vim.uv.fs_realpath(path) or path
  root = vim.uv.fs_realpath(root) or root
  path = trim_trailing_slash(path)
  root = trim_trailing_slash(root)
  if path == root then
    return "."
  end
  local prefix = root .. "/"
  if vim.startswith(path, prefix) then
    return path:sub(#prefix + 1)
  end
  return nil
end

---@param lines string[]
---@param start_col integer 0-indexed byte column
---@param end_col integer 0-indexed byte column
---@return string
function M.block_text(lines, start_col, end_col)
  local selected = {}
  for _, line in ipairs(lines) do
    selected[#selected + 1] = line:sub(start_col + 1, end_col + 1)
  end
  return table.concat(selected, "\n")
end

---@param selection table
---@return table|nil
function M.selection(selection)
  local relpath = M.relative_path(selection.path, selection.repo_root)
  if not relpath then
    return nil
  end
  return {
    repo_root = selection.repo_root,
    path = relpath,
    start_line = selection.start_line,
    start_col = selection.start_col,
    end_line = selection.end_line,
    end_col = selection.end_col,
    text = selection.text,
    branch = selection.branch,
    revision = selection.revision,
  }
end

return M
