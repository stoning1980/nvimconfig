local M = {}

M.defaults = {
  input = {
    width = 0.6,
    height = 0.3,
  },
  log_level = "info",
  project_root = nil,
}

M.options = vim.deepcopy(M.defaults)

---@param opts table|nil
---@return table
function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
  local project_root = M.options.project_root or vim.uv.cwd() or vim.fn.getcwd()
  M.options.project_root = vim.uv.fs_realpath(project_root) or project_root
  return M.options
end

return M
