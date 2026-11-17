local M = {}

M.defaults = {
  input = {
    width = 0.6,
    height = 0.3,
  },
  log_level = "info",
}

M.options = vim.deepcopy(M.defaults)

---@param opts table|nil
---@return table
function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
  return M.options
end

return M
