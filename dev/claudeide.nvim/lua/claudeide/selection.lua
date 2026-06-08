-- Selection tracking: sends selection_changed notifications (debounced) and
-- at_mentioned notifications when the user explicitly shares context.

local server = require("claudeide.server")
local util = require("claudeide.util")

local M = {}

M.enabled = false
M.debounce_ms = 50
local timer = nil
local augroup = nil
local last_sent = nil

local function is_real_file_buffer(bufnr)
  if vim.bo[bufnr].buftype ~= "" then
    return false
  end
  local name = vim.api.nvim_buf_get_name(bufnr)
  return name ~= ""
end

--- Format an absolute path as relative to cwd when it lives inside the
--- workspace (this is what the Claude CLI expects for at-mentions).
---@param path string
---@return string
local function format_path(path)
  local cwd = vim.fn.getcwd()
  if path:sub(1, #cwd) == cwd then
    local rel = path:sub(#cwd + 2)
    if rel ~= "" then
      return rel
    end
  end
  return path
end

--- Compute the current selection (or cursor position) in 0-based coordinates.
local function get_selection()
  local bufnr = vim.api.nvim_get_current_buf()
  if not is_real_file_buffer(bufnr) then
    return nil
  end
  local path = vim.api.nvim_buf_get_name(bufnr)
  local mode = vim.fn.mode()
  local is_visual = mode == "v" or mode == "V" or mode == "\22"

  if is_visual then
    local vpos = vim.fn.getpos("v")
    local cpos = vim.fn.getpos(".")
    -- Normalize so start <= end.
    local sl, sc = vpos[2], vpos[3]
    local el, ec = cpos[2], cpos[3]
    if sl > el or (sl == el and sc > ec) then
      sl, sc, el, ec = el, ec, sl, sc
    end
    local text = ""
    if vim.fn.getregion then
      local ok, region = pcall(vim.fn.getregion, vpos, cpos, { type = mode })
      if ok and region then
        text = table.concat(region, "\n")
      end
    end
    return {
      text = text,
      filePath = path,
      fileUrl = util.path_to_uri(path),
      selection = {
        start = { line = sl - 1, character = sc - 1 },
        ["end"] = { line = el - 1, character = ec },
        isEmpty = false,
      },
    }
  end

  local cursor = vim.api.nvim_win_get_cursor(0)
  local line = cursor[1] - 1
  local char = cursor[2]
  return {
    text = "",
    filePath = path,
    fileUrl = util.path_to_uri(path),
    selection = {
      start = { line = line, character = char },
      ["end"] = { line = line, character = char },
      isEmpty = true,
    },
  }
end

local function send_selection()
  if not server.is_running() or server.client_count() == 0 then
    return
  end
  local sel = get_selection()
  if not sel then
    return
  end
  -- Avoid spamming identical updates.
  local key = sel.filePath
    .. ":"
    .. sel.selection.start.line
    .. ":"
    .. sel.selection.start.character
    .. ":"
    .. sel.selection["end"].line
    .. ":"
    .. sel.selection["end"].character
  if key == last_sent then
    return
  end
  last_sent = key
  server.broadcast({ jsonrpc = "2.0", method = "selection_changed", params = sel })
end

local function schedule_send()
  if not M.enabled then
    return
  end
  if timer then
    timer:stop()
    timer:close()
    timer = nil
  end
  timer = (vim.loop or vim.uv).new_timer()
  timer:start(
    M.debounce_ms,
    0,
    vim.schedule_wrap(function()
      if timer then
        timer:stop()
        timer:close()
        timer = nil
      end
      send_selection()
    end)
  )
end

function M.setup()
  if augroup then
    return
  end
  M.enabled = true
  augroup = vim.api.nvim_create_augroup("ClaudeIdeSelection", { clear = true })
  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI", "ModeChanged" }, {
    group = augroup,
    callback = schedule_send,
  })
end

function M.teardown()
  M.enabled = false
  if augroup then
    vim.api.nvim_del_augroup_by_id(augroup)
    augroup = nil
  end
  if timer then
    timer:stop()
    timer:close()
    timer = nil
  end
end

--- Send an explicit at-mention for a file/line range (1-based lines as given).
---@param path string
---@param line_start? integer 0-based start line
---@param line_end? integer 0-based end line
function M.send_at_mention(path, line_start, line_end)
  if not server.is_running() then
    util.warn("Claude IDE server not running")
    return false
  end
  if server.client_count() == 0 then
    util.warn("no Claude client connected")
    return false
  end
  local params = { filePath = format_path(path) }
  if line_start then
    params.lineStart = line_start
    params.lineEnd = line_end or line_start
  end
  server.broadcast({ jsonrpc = "2.0", method = "at_mentioned", params = params })
  return true
end

--- Send the current visual selection as an at-mention.
function M.send_current_selection()
  local bufnr = vim.api.nvim_get_current_buf()
  if not is_real_file_buffer(bufnr) then
    util.warn("current buffer is not a file")
    return
  end
  local path = vim.api.nvim_buf_get_name(bufnr)
  -- Use the last visual selection marks.
  local sl = vim.fn.getpos("'<")[2]
  local el = vim.fn.getpos("'>")[2]
  if sl == 0 or el == 0 then
    local cur = vim.api.nvim_win_get_cursor(0)[1]
    sl, el = cur, cur
  end
  if M.send_at_mention(path, sl - 1, el - 1) then
    util.info(string.format("sent selection %s:%d-%d to Claude", vim.fn.fnamemodify(path, ":t"), sl, el))
  end
end

--- Add a whole buffer/file as context.
---@param path string
function M.add_file(path)
  path = (path == nil or path == "") and vim.api.nvim_buf_get_name(0) or vim.fn.fnamemodify(path, ":p")
  if path == "" then
    util.warn("no file to add")
    return
  end
  if M.send_at_mention(path) then
    util.info("added " .. vim.fn.fnamemodify(path, ":t") .. " to Claude context")
  end
end

return M
