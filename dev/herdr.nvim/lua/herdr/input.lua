local M = {}

---@param options table
---@param title string
---@param on_submit fun(comment: string)
function M.open(options, title, on_submit)
  local ok, snacks = pcall(require, "snacks")
  if not ok then
    vim.ui.input({ prompt = title .. ": " }, function(comment)
      if comment and vim.trim(comment) ~= "" then
        on_submit(comment)
      end
    end)
    return
  end

  local win = snacks.win({
    position = "float",
    width = options.width,
    height = options.height,
    border = "rounded",
    title = " " .. title .. " ",
    title_pos = "center",
    footer = " Enter = submit   Alt+Enter = newline   Esc = cancel ",
    footer_pos = "center",
    enter = true,
    bo = { filetype = "markdown", modifiable = true, buftype = "nofile" },
    wo = { wrap = true, linebreak = true },
  })

  local function submit()
    local comment = vim.trim(table.concat(vim.api.nvim_buf_get_lines(win.buf, 0, -1, false), "\n"))
    win:close()
    vim.cmd("stopinsert")
    if comment ~= "" then
      on_submit(comment)
    end
  end
  vim.keymap.set({ "i", "n" }, "<CR>", submit, { buffer = win.buf, nowait = true })
  vim.keymap.set("i", "<M-CR>", "<CR>", { buffer = win.buf, nowait = true, remap = false })
  vim.keymap.set({ "i", "n" }, "<Esc>", function()
    win:close()
    vim.cmd("stopinsert")
  end, { buffer = win.buf, nowait = true })
  vim.cmd("startinsert")
end

return M
