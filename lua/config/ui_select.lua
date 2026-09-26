-- Workaround for a crash in Snacks' `vim.ui.select` picker.
--
-- snacks/picker/select.lua fits the list height to the item count with
--
--   box.height = math.max(math.min(#items, vim.o.lines * 0.8 - 10), 2)
--
-- `vim.o.lines * 0.8 - 10` is fractional for every terminal height that is not
-- a multiple of 5 (24 lines gives 9.2). While the list is shorter than that the
-- integral `#items` wins, so short prompts work; as soon as there are more
-- items the fraction reaches nvim_open_win, which rejects it with "Invalid
-- 'height': Number is not integral" and the whole picker blows up.
--
-- Wrapping `vim.ui.select` lets us pass the same fit through the `snacks`
-- option, which select.lua merges over its own layout config, so every caller
-- (`<F1>`, `:Goto`, adbhelper, LSP code actions, …) gets an integral height.
-- The extra option is inert if something other than Snacks handles the select.
local M = {}

local function fit_list_height(items)
  return function(layout)
    for _, box in ipairs(layout.layout) do
      if box.win == "list" and not box.height then
        box.height = math.max(math.min(#items, math.floor(vim.o.lines * 0.8 - 10)), 2)
      end
    end
  end
end

function M.setup()
  local select = vim.ui.select
  vim.ui.select = function(items, opts, on_choice)
    opts = vim.tbl_extend("force", {}, opts or {})
    opts.snacks = vim.tbl_deep_extend("force", opts.snacks or {}, {
      layout = { config = fit_list_height(items) },
    })
    return select(items, opts, on_choice)
  end
end

return M
