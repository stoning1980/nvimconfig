-- A small Snacks float for typing a comment before sending to an agent.

local util = require("codechat.util")

local M = {}

--- Open a comment input window.
---@param cfg table input config { width, height }
---@param opts table { title?: string, prefill?: string, on_submit: fun(text:string), on_send?: fun(text:string), on_cancel?: fun() }
function M.input(cfg, opts)
  local ok, s = pcall(require, "snacks")
  if not ok then
    util.error("snacks.nvim is required")
    return
  end

  local win
  local done = false

  local function get_text()
    local lines = vim.api.nvim_buf_get_lines(win.buf, 0, -1, false)
    return vim.trim(table.concat(lines, "\n"))
  end

  local function close()
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
    footer = " Enter = submit   ^S = send   ⌥+Enter = new line   Esc = cancel ",
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
  vim.keymap.set("n", "<Esc>", cancel, { buffer = win.buf, nowait = true })
  vim.keymap.set("n", "q", cancel, { buffer = win.buf, nowait = true })

  if opts.prefill and opts.prefill ~= "" then
    vim.api.nvim_buf_set_lines(win.buf, 0, -1, false, vim.split(opts.prefill, "\n", { plain = true }))
  end
  vim.cmd("startinsert")
  return win
end

return M
