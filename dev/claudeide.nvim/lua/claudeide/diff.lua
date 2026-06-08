-- Native Neovim diff support for the blocking `openDiff` MCP tool.

local util = require("claudeide.util")

local M = {}

-- Only one active diff at a time for the MVP.
M.pending = nil
---@type nil|{ respond: fun(result: table), old_path: string, contents: string, tabpage: integer, answered: boolean }

local function content_lines(contents)
  contents = contents or ""
  -- Drop a single trailing newline so we don't get a spurious empty last line.
  if contents:sub(-1) == "\n" then
    contents = contents:sub(1, -2)
  end
  return vim.split(contents, "\n", { plain = true })
end

local function reply(result_text)
  if not M.pending or M.pending.answered then
    return
  end
  M.pending.answered = true
  M.pending.respond({ content = { { type = "text", text = result_text } } })
end

local function close_diff_tab()
  if not M.pending then
    return
  end
  pcall(vim.api.nvim_del_augroup_by_name, "ClaudeIdeDiffWatch")
  local tabpage = M.pending.tabpage
  M.pending = nil
  if tabpage and vim.api.nvim_tabpage_is_valid(tabpage) then
    pcall(function()
      local tabnr = vim.api.nvim_tabpage_get_number(tabpage)
      vim.cmd(tabnr .. "tabclose")
    end)
  end
end

--- Open a diff between an existing file and proposed contents. Blocking: the
--- response is sent later via :ClaudeIdeDiffAccept / :ClaudeIdeDiffDeny.
---@param params table { old_file_path, new_file_path, new_file_contents, tab_name }
---@param respond fun(result: table)
function M.open(params, respond)
  -- If a previous diff is still open, reject it first.
  if M.pending and not M.pending.answered then
    reply("DIFF_REJECTED")
    close_diff_tab()
  end

  local old_path = params.old_file_path or params.new_file_path
  local contents = params.new_file_contents or ""
  local tab_name = params.tab_name or "Claude diff"

  local filetype
  if old_path and vim.fn.filereadable(old_path) == 1 then
    filetype = vim.filetype.match({ filename = old_path }) or ""
  end

  vim.cmd("tabnew")
  local tabpage = vim.api.nvim_get_current_tabpage()

  -- Left: original file (or empty for new files).
  if old_path and vim.fn.filereadable(old_path) == 1 then
    vim.cmd("edit " .. vim.fn.fnameescape(old_path))
  else
    vim.cmd("enew")
  end
  vim.cmd("diffthis")

  -- Right: scratch buffer with proposed contents.
  vim.cmd("vsplit")
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, content_lines(contents))
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  if filetype and filetype ~= "" then
    vim.bo[buf].filetype = filetype
  end
  pcall(vim.api.nvim_buf_set_name, buf, tab_name)
  vim.api.nvim_win_set_buf(0, buf)
  vim.cmd("diffthis")

  M.pending = {
    respond = respond,
    old_path = old_path,
    contents = contents,
    tabpage = tabpage,
    answered = false,
  }

  -- If the user closes the diff tab without accepting/denying, treat it as a
  -- rejection so the blocking openDiff call on Claude's side never hangs.
  local group = vim.api.nvim_create_augroup("ClaudeIdeDiffWatch", { clear = true })
  vim.api.nvim_create_autocmd("TabClosed", {
    group = group,
    callback = function()
      if M.pending and not M.pending.answered and not vim.api.nvim_tabpage_is_valid(M.pending.tabpage) then
        reply("DIFF_REJECTED")
        M.pending = nil
        util.info("diff tab closed - rejected")
      end
    end,
  })

  util.info("Claude proposed a diff. :ClaudeIdeDiffAccept to apply, :ClaudeIdeDiffDeny to reject")
end

--- Accept the pending diff: write contents to disk and reply FILE_SAVED.
function M.accept()
  if not M.pending then
    util.warn("no pending diff")
    return
  end
  local old_path = M.pending.old_path
  local contents = M.pending.contents
  if old_path then
    local ok, err = pcall(vim.fn.writefile, content_lines(contents), old_path)
    if not ok then
      util.error("failed to write file: " .. tostring(err))
    else
      -- Reload any open buffer for this file.
      local bufnr = vim.fn.bufnr(old_path)
      if bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr) then
        vim.api.nvim_buf_call(bufnr, function()
          vim.cmd("checktime")
        end)
      end
    end
  end
  reply("FILE_SAVED")
  close_diff_tab()
  util.info("diff accepted")
end

--- Reject the pending diff: reply DIFF_REJECTED.
function M.deny()
  if not M.pending then
    util.warn("no pending diff")
    return
  end
  reply("DIFF_REJECTED")
  close_diff_tab()
  util.info("diff rejected")
end

function M.has_pending()
  return M.pending ~= nil
end

return M
