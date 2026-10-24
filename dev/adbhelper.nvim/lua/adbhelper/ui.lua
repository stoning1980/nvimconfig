local M = {}

--- Single-select over a list of items using Snacks.picker when available,
--- falling back to vim.ui.select. Each item is a table with a `text` field
--- (the display label); any other fields are preserved and handed back to the
--- callback on the chosen item.
---@param items table[] each item has `.text` plus arbitrary payload fields
---@param opts? { title?: string }
---@param on_choice fun(item: table|nil)
function M.select(items, opts, on_choice)
  opts = opts or {}

  if Snacks and Snacks.picker then
    Snacks.picker.pick({
      source = "adbhelper",
      items = items,
      format = "text",
      title = opts.title,
      preview = "none",
      layout = { preset = "select", preview = false },
      confirm = function(picker, item)
        picker:close()
        on_choice(item)
      end,
    })
    return
  end

  vim.ui.select(items, {
    prompt = opts.title or "Select:",
    format_item = function(item)
      return item.text
    end,
  }, on_choice)
end

return M
