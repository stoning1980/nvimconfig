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

---@param line string
---@param byte_col integer 0-indexed byte column at a character start
---@return integer 0-indexed byte column immediately after the character
function M.byte_after_char(line, byte_col)
  if byte_col >= #line then
    return #line
  end
  local char_index = vim.str_utfindex(line, byte_col)
  return vim.str_byteindex(line, char_index + 1)
end

---@param lines string[]
---@param start_col integer 0-indexed byte column
---@param end_col integer 0-indexed byte column
---@return string
function M.block_text(lines, start_col, end_col)
  local selected = {}
  for _, line in ipairs(lines) do
    selected[#selected + 1] = line:sub(start_col + 1, M.byte_after_char(line, end_col))
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

---@param selection table
---@param project_root? string
---@param filetype? string
---@param selection_kind? "file"|"selection"
---@return table
function M.project_selection(selection, project_root, filetype, selection_kind)
  project_root = project_root or vim.uv.cwd() or vim.fn.getcwd()
  project_root = vim.uv.fs_realpath(project_root) or project_root
  local absolute_path = vim.uv.fs_realpath(selection.path) or vim.fn.fnamemodify(selection.path, ":p")
  local project_relative_path = M.relative_path(absolute_path, project_root)
  selection_kind = selection_kind or "selection"
  local is_file = selection_kind == "file"
  return {
    context_kind = "project",
    selection_kind = selection_kind,
    repo_root = project_root,
    project_root = project_root,
    path = project_relative_path or absolute_path,
    project_relative_path = project_relative_path,
    absolute_path = absolute_path,
    filetype = filetype ~= "" and filetype or nil,
    start_line = not is_file and selection.start_line or nil,
    start_col = not is_file and selection.start_col or nil,
    end_line = not is_file and selection.end_line or nil,
    end_col = not is_file and selection.end_col or nil,
    text = not is_file and selection.text or nil,
  }
end

return M
