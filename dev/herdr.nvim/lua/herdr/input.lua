local M = {}

---@param items table[]
---@return string[]
function M.queue_lines(items)
  local lines = {}
  for index, item in ipairs(items) do
    local selection = item.selection
    local location = selection.path .. ":" .. selection.start_line
    if selection.end_line and selection.end_line ~= selection.start_line then
      location = location .. "-" .. selection.end_line
    end
    lines[#lines + 1] = string.format("%d. %s — %s", index, location, (item.comment or ""):gsub("%s+", " "))
  end
  return lines
end

---@param options table
---@param title string
---@param actions table { items?: table[], on_add: fun(comment: string), on_submit: fun(comment: string) }
function M.open(options, title, actions)
  local ok, snacks = pcall(require, "snacks")
  if not ok then
    vim.ui.input({ prompt = title .. ": " }, function(comment)
      if comment and vim.trim(comment) ~= "" then
        actions.on_submit(comment)
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
    footer = " Enter = Submit all   Ctrl+S = Add to queue   Alt+Enter = newline   Esc = cancel ",
    footer_pos = "center",
    enter = true,
    bo = { filetype = "markdown", modifiable = true, buftype = "nofile" },
    wo = { wrap = true, linebreak = true },
  })
  local queue_win

  local function close()
    if queue_win then
      pcall(function()
        queue_win:close()
      end)
    end
    win:close()
    vim.cmd("stopinsert")
  end

  local function comment_text()
    return vim.trim(table.concat(vim.api.nvim_buf_get_lines(win.buf, 0, -1, false), "\n"))
  end

  local function add()
    local comment = comment_text()
    close()
    if comment ~= "" then
      actions.on_add(comment)
    end
  end

  local function submit()
    local comment = comment_text()
    close()
    actions.on_submit(comment)
  end
  vim.keymap.set({ "i", "n" }, "<CR>", submit, { buffer = win.buf, nowait = true })
  vim.keymap.set({ "i", "n" }, "<C-s>", add, { buffer = win.buf, nowait = true })
  vim.keymap.set("i", "<M-CR>", "<CR>", { buffer = win.buf, nowait = true, remap = false })
  vim.keymap.set({ "i", "n" }, "<Esc>", function()
    close()
  end, { buffer = win.buf, nowait = true })

  local lines = M.queue_lines(actions.items or {})
  if #lines > 0 then
    local input_height = options.height or 0.3
    queue_win = snacks.win({
      position = "float",
      relative = "editor",
      row = 0.5 + input_height / 2 + 0.02,
      width = options.width,
      height = math.min(#lines + 2, 8),
      border = "rounded",
      title = " Queued review comments ",
      title_pos = "center",
      enter = false,
      bo = { filetype = "markdown", modifiable = false, buftype = "nofile" },
      wo = { wrap = true, cursorline = false },
    })
    vim.bo[queue_win.buf].modifiable = true
    vim.api.nvim_buf_set_lines(queue_win.buf, 0, -1, false, lines)
    vim.bo[queue_win.buf].modifiable = false
  end
  vim.cmd("startinsert")
end

return M
