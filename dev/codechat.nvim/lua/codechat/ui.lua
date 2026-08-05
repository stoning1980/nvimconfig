-- A small Snacks float for typing a comment before sending to an agent.

local util = require("codechat.util")

local M = {}

--- Format history entries into display lines, newest-first.
---@param history table[] list of { time, agent, text }
---@return string[]
local function history_lines(history)
  local lines = {}
  for _, e in ipairs(history) do
    local when = os.date("%m-%d %H:%M", e.time)
    -- Collapse each message to a single line so the list stays scannable.
    local one = (e.text or ""):gsub("%s+", " ")
    lines[#lines + 1] = string.format("%s  [%s]  %s", when, e.agent or "?", one)
  end
  if #lines == 0 then
    lines[1] = "(no history yet)"
  end
  return lines
end

--- Open a comment input window.
---@param cfg table input config { width, height }
---@param opts table { title?: string, prefill?: string, history?: table[], on_submit: fun(text:string), on_send?: fun(text:string), on_cancel?: fun() }
function M.input(cfg, opts)
  local ok, s = pcall(require, "snacks")
  if not ok then
    util.error("snacks.nvim is required")
    return
  end

  local win
  local history_win
  local done = false

  local function get_text()
    local lines = vim.api.nvim_buf_get_lines(win.buf, 0, -1, false)
    return vim.trim(table.concat(lines, "\n"))
  end

  --- Return focus to the input window in insert mode at the buffer end.
  local function focus_input()
    if win.win and vim.api.nvim_win_is_valid(win.win) then
      pcall(vim.api.nvim_set_current_win, win.win)
      pcall(vim.api.nvim_win_set_cursor, win.win, { math.max(1, vim.api.nvim_buf_line_count(win.buf)), 0 })
    end
    vim.cmd("startinsert!")
  end

  --- Replace the input buffer with `text`, focus it, and drop into insert mode
  --- at the end so the recalled message can be edited and resent.
  local function load_into_input(text)
    vim.api.nvim_buf_set_lines(win.buf, 0, -1, false, vim.split(text or "", "\n", { plain = true }))
    focus_input()
  end

  --- Insert `text` into the input buffer at the cursor and leave the cursor
  --- just after it (used to drop an @path mention where the user was typing).
  local function insert_at_cursor(text)
    if not (win.win and vim.api.nvim_win_is_valid(win.win)) then
      return
    end
    local cursor = vim.api.nvim_win_get_cursor(win.win)
    local row, col = cursor[1], cursor[2]
    vim.api.nvim_buf_set_text(win.buf, row - 1, col, row - 1, col, { text })
    pcall(vim.api.nvim_win_set_cursor, win.win, { row, col + #text })
  end

  --- Open a file picker and insert the chosen file as an `@relpath` mention.
  --- Triggered by `@` in insert mode; agents resolve `@relpath` to the file.
  local function pick_file()
    local pok, snacks = pcall(require, "snacks")
    if not (pok and snacks.picker and type(snacks.picker.files) == "function") then
      util.warn("snacks.picker is required for @ file completion")
      return
    end
    vim.cmd("stopinsert")
    snacks.picker.files({
      confirm = function(picker, item)
        picker:close()
        if item then
          local full = snacks.picker.util.path(item) or item.file or ""
          if full ~= "" then
            insert_at_cursor("@" .. util.relpath(full))
          end
        end
        focus_input()
      end,
      -- If the picker is dismissed, return focus to the input box.
      on_close = function()
        focus_input()
      end,
    })
  end

  --- Open the Goto project picker and insert the chosen directory's path.
  --- Triggered by `#` in insert mode; reuses the same project list as `:Goto`.
  local function pick_project()
    local gok, goto_mod = pcall(require, "config.goto")
    local pok, snacks = pcall(require, "snacks")
    if not (gok and type(goto_mod.candidates) == "function") then
      util.warn("config.goto is required for # project completion")
      return
    end
    if not (pok and snacks.picker and type(snacks.picker.pick) == "function") then
      util.warn("snacks.picker is required for # project completion")
      return
    end
    local dirs = goto_mod.candidates()
    if #dirs == 0 then
      util.warn("no projects to pick from")
      focus_input()
      return
    end
    local items = {}
    for i, entry in ipairs(dirs) do
      local marker = entry.recent and "󰋚 " or "   "
      items[#items + 1] = { text = marker .. vim.fn.fnamemodify(entry.dir, ":~"), dir = entry.dir, idx = i }
    end
    vim.cmd("stopinsert")
    snacks.picker.pick({
      source = "codechat_goto",
      items = items,
      format = "text",
      title = "Goto Project",
      preview = "none",
      layout = { preset = "select", preview = false },
      confirm = function(picker, item)
        picker:close()
        if item and item.dir then
          insert_at_cursor(item.dir)
        end
        focus_input()
      end,
      on_close = function()
        focus_input()
      end,
    })
  end

  local function close()
    if history_win then
      pcall(function()
        history_win:close()
      end)
    end
    win:close()
    vim.cmd("stopinsert")
  end

  local function submit()
    if done then
      return
    end
    done = true
    local text = get_text()
    close()
    opts.on_submit(text)
  end

  local function send()
    if done then
      return
    end
    done = true
    local text = get_text()
    close()
    if opts.on_send then
      opts.on_send(text)
    end
  end

  local function cancel()
    if done then
      return
    end
    done = true
    close()
    if opts.on_cancel then
      opts.on_cancel()
    end
  end

  win = s.win({
    position = "float",
    width = cfg.width or 0.6,
    height = cfg.height or 0.3,
    border = "rounded",
    title = " " .. (opts.title or "Message") .. " ",
    title_pos = "center",
    footer = " Enter = submit   ^S = send   ^R = history   @ = file   # = project   ⌥+Enter = new line   Esc = cancel ",
    footer_pos = "center",
    enter = true,
    bo = { filetype = "markdown", modifiable = true, buftype = "nofile" },
    wo = { wrap = true, linebreak = true },
  })

  vim.keymap.set("i", "<CR>", submit, { buffer = win.buf, nowait = true })
  vim.keymap.set("n", "<CR>", submit, { buffer = win.buf, nowait = true })
  vim.keymap.set("i", "<M-CR>", "<CR>", { buffer = win.buf, nowait = true, remap = false })
  vim.keymap.set("i", "<C-s>", send, { buffer = win.buf, nowait = true })
  vim.keymap.set("n", "<C-s>", send, { buffer = win.buf, nowait = true })
  vim.keymap.set("i", "#", pick_project, { buffer = win.buf, nowait = true })
  vim.keymap.set("i", "@", pick_file, { buffer = win.buf, nowait = true })
  vim.keymap.set("n", "<Esc>", cancel, { buffer = win.buf, nowait = true })
  vim.keymap.set("n", "q", cancel, { buffer = win.buf, nowait = true })

  if opts.prefill and opts.prefill ~= "" then
    vim.api.nvim_buf_set_lines(win.buf, 0, -1, false, vim.split(opts.prefill, "\n", { plain = true }))
  end

  -- History panel just below the input. It lists recent messages so a lost or
  -- failed send can be recalled: press ^R in the input to jump here, move to an
  -- entry, and hit Enter to load its full text back into the edit box.
  if opts.history and #opts.history > 0 then
    local width = cfg.width or 0.6
    local input_h = cfg.height or 0.3
    local hist_h = cfg.history_height or 0.25
    -- The input is vertically centered, so its bottom edge is at
    -- 0.5 + input_h/2 of the screen; drop the panel one row beneath that.
    local row = 0.5 + input_h / 2 + 0.02
    history_win = s.win({
      position = "float",
      relative = "editor",
      row = row,
      width = width,
      height = hist_h,
      border = "rounded",
      title = " Recent messages -- Enter = reuse ",
      title_pos = "center",
      enter = false,
      bo = { filetype = "markdown", modifiable = false, buftype = "nofile" },
      wo = { wrap = false, cursorline = true },
    })
    local lines = history_lines(opts.history)
    vim.bo[history_win.buf].modifiable = true
    vim.api.nvim_buf_set_lines(history_win.buf, 0, -1, false, lines)
    vim.bo[history_win.buf].modifiable = false

    -- Line N (1-based) of the panel corresponds to opts.history[N] (newest-first).
    local function reuse_current()
      local lnum = vim.api.nvim_win_get_cursor(history_win.win)[1]
      local entry = opts.history[lnum]
      if entry then
        load_into_input(entry.text)
      end
    end

    local hb = history_win.buf
    vim.keymap.set("n", "<CR>", reuse_current, { buffer = hb, nowait = true })
    vim.keymap.set("n", "<Esc>", function()
      focus_input()
    end, { buffer = hb, nowait = true })
    vim.keymap.set("n", "q", function()
      focus_input()
    end, { buffer = hb, nowait = true })

    -- ^R from the input focuses the panel so the user can pick an entry.
    local function focus_history()
      if history_win.win and vim.api.nvim_win_is_valid(history_win.win) then
        vim.cmd("stopinsert")
        pcall(vim.api.nvim_set_current_win, history_win.win)
        pcall(vim.api.nvim_win_set_cursor, history_win.win, { 1, 0 })
      end
    end
    vim.keymap.set("i", "<C-r>", focus_history, { buffer = win.buf, nowait = true })
    vim.keymap.set("n", "<C-r>", focus_history, { buffer = win.buf, nowait = true })
  end

  vim.cmd("startinsert")
  return win
end

return M
