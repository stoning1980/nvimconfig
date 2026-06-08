if vim.g.loaded_claudeide then
  return
end
vim.g.loaded_claudeide = true

-- Actual setup is performed by the lazy.nvim spec calling require("claudeide").setup().
-- This file only guards against double loading.
