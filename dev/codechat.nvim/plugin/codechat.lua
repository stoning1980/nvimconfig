if vim.g.loaded_codechat then
  return
end
vim.g.loaded_codechat = true

-- Setup is performed by the lazy.nvim spec calling require("codechat").setup().
-- This file only guards against double loading.
