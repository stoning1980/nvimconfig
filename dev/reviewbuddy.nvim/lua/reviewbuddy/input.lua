local M = {}

---@param items table[]
---@return string[]
function M.queue_lines(items)
  local lines = {}
  for index, item in ipairs(items) do
    local selection = item.selection
    local location = selection.path
    if selection.selection_kind ~= "file" and selection.selection_kind ~= "image" then
      location = location .. ":" .. selection.start_line
      if selection.end_line and selection.end_line ~= selection.start_line then
        location = location .. "-" .. selection.end_line
      end
    end
    lines[#lines + 1] = string.format("%d. %s — %s", index, location, (item.comment or ""):gsub("%s+", " "))
  end
  return lines
end

---@param options table
---@param title string
---@param actions table {
---  items?: table[],
---  on_add: fun(comment: string),
---  on_submit: fun(comment: string),
---  on_delete: fun(item: table),
---}
function M.open(options, title, actions)
  local items = vim.deepcopy(actions.items or {})
  local function composer_title()
    return string.format("%s (queued: %d)", title, #items)
  end

  local ok, snacks = pcall(require, "snacks")
  if not ok then
    vim.ui.input({ prompt = composer_title() .. ": " }, function(comment)
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
    title = " " .. composer_title() .. " ",
    title_pos = "center",
    footer = " Enter Submit all   Ctrl+S Queue   Ctrl+D Delete one   Alt+Enter Newline   Esc Cancel ",
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

  local function focus_input()
    if queue_win and queue_win.win and vim.api.nvim_win_is_valid(queue_win.win) then
      vim.wo[queue_win.win].cursorline = false
    end
    win:focus()
    vim.cmd("startinsert")
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
  vim.keymap.set({ "i", "n" }, "<CR>", submit, { buf = win.buf, nowait = true })
  vim.keymap.set({ "i", "n" }, "<C-s>", add, { buf = win.buf, nowait = true })
  vim.keymap.set("i", "<M-CR>", "<CR>", { buf = win.buf, nowait = true, remap = false })
  vim.keymap.set({ "i", "n" }, "<C-d>", function()
    if not queue_win or not queue_win.win or not vim.api.nvim_win_is_valid(queue_win.win) then
      return
    end
    vim.cmd("stopinsert")
    vim.wo[queue_win.win].cursorline = true
    queue_win:focus()
  end, { buf = win.buf, nowait = true })
  vim.keymap.set({ "i", "n" }, "<Esc>", function()
    close()
  end, { buf = win.buf, nowait = true })

  local function render_queue()
    local lines = M.queue_lines(items)
    if #lines == 0 then
      if queue_win then
        queue_win:close()
        queue_win = nil
      end
      return
    end

    if not queue_win then
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
      vim.keymap.set("n", "<CR>", function()
        local index = vim.api.nvim_win_get_cursor(queue_win.win)[1]
        local item = items[index]
        if not item then
          focus_input()
          return
        end
        actions.on_delete(item)
        table.remove(items, index)
        win:set_title(composer_title())
        render_queue()
        focus_input()
      end, { buf = queue_win.buf, nowait = true })
      vim.keymap.set("n", "<Esc>", focus_input, { buf = queue_win.buf, nowait = true })
    end

    vim.bo[queue_win.buf].modifiable = true
    vim.api.nvim_buf_set_lines(queue_win.buf, 0, -1, false, lines)
    vim.bo[queue_win.buf].modifiable = false
  end

  if #items > 0 then
    render_queue()
  end
  vim.cmd("startinsert")
end

return M
