-- Let buffer switches inside a Diffview tab move the Diffview instead of
-- breaking it.
--
-- Switching buffers (e.g. `,,`) while in a Diffview tab drops the plain file
-- into whichever window has focus — a diff window or the file panel — and the
-- view only recovers on :DiffviewRefresh
-- — back to the file it had selected, not the one you picked. This watches for
-- that: when a diff window ends up showing a file from the view's change set,
-- that file is selected in the view instead, so its diff opens and the file
-- panel moves to it. Files outside the change set are left alone.
--
-- `:DiffviewShowFile` does the same from any tab: it jumps to the open
-- Diffview and selects the current buffer's file there.
local M = {}

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = "Diffview" })
end

-- Open DiffViews (file-history views have no change set to select from). Reads
-- package.loaded rather than require() so a buffer switch never pulls in the
-- lazy-loaded plugin.
local function diff_views()
  local lib = package.loaded["diffview.lib"]
  if not lib then
    return {}
  end
  return vim.tbl_filter(function(view)
    return view.files ~= nil and view.set_file_by_path ~= nil
  end, lib.views)
end

local function realpath(path)
  return vim.uv.fs_realpath(path) or vim.fs.normalize(path)
end

-- The repo-relative path Diffview keys `abs` by, or nil when the file is not
-- part of the view's change set.
local function entry_path(view, abs)
  local root = view.adapter and view.adapter.ctx and view.adapter.ctx.toplevel
  if not root then
    return nil
  end
  root = realpath(root)
  abs = realpath(abs)
  if abs:sub(1, #root + 1) ~= root .. "/" then
    return nil
  end
  local rel = abs:sub(#root + 2)
  for _, file in view.files:iter() do
    if file.path == rel then
      return rel
    end
  end
end

-- If `win` is one of a Diffview's diff windows, or its file panel, and now
-- shows `buf`, a file the view did not put there, select that file in the view.
-- The panel gets its own buffer back first; it is `bufhidden=hide`, so it
-- survives being swapped out.
local function follow(win, buf)
  if not (vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == buf) then
    return
  end
  local tab = vim.api.nvim_win_get_tabpage(win)
  for _, view in ipairs(diff_views()) do
    if view.tabpage == tab and view.cur_layout then
      local panel = view.panel
      if panel and win == panel.winid and buf ~= panel.bufid then
        local rel = entry_path(view, vim.api.nvim_buf_get_name(buf))
        if rel and panel:buf_loaded() then
          vim.api.nvim_win_set_buf(win, panel.bufid)
          panel:resize()
          view:set_file_by_path(rel, true, true)
        end
        return
      end
      for _, w in ipairs(view.cur_layout.windows) do
        if w.id == win then
          if w.file and w.file.bufnr == buf then
            return
          end
          local rel = entry_path(view, vim.api.nvim_buf_get_name(buf))
          if rel then
            view:set_file_by_path(rel, true, true)
          end
          return
        end
      end
    end
  end
end

-- Jump to the open Diffview and select the current buffer's file. Prefers the
-- Diffview in the current tab, then any other one containing the file.
function M.show_file()
  local abs = vim.api.nvim_buf_get_name(0)
  if abs == "" or vim.bo.buftype ~= "" then
    notify("Current buffer is not a file", vim.log.levels.WARN)
    return
  end
  local views = diff_views()
  if #views == 0 then
    notify("No Diffview open (<F1> opens one)", vim.log.levels.WARN)
    return
  end
  local cur_tab = vim.api.nvim_get_current_tabpage()
  table.sort(views, function(a, b)
    return a.tabpage == cur_tab and b.tabpage ~= cur_tab
  end)
  for _, view in ipairs(views) do
    local rel = entry_path(view, abs)
    if rel then
      vim.api.nvim_set_current_tabpage(view.tabpage)
      view:set_file_by_path(rel, true, true)
      return
    end
  end
  notify(vim.fn.fnamemodify(abs, ":t") .. " is not in the open Diffview's changes", vim.log.levels.WARN)
end

function M.setup()
  vim.api.nvim_create_autocmd("BufWinEnter", {
    group = vim.api.nvim_create_augroup("DiffviewFollow", { clear = true }),
    callback = function(ev)
      if vim.bo[ev.buf].buftype ~= "" or #diff_views() == 0 then
        return
      end
      local win = vim.api.nvim_get_current_win()
      -- Let Diffview finish any buffer placement of its own first.
      vim.schedule(function()
        follow(win, ev.buf)
      end)
    end,
  })

  vim.api.nvim_create_user_command("DiffviewShowFile", M.show_file, {
    nargs = 0,
    desc = "Jump to the open Diffview and select the current buffer's file",
  })
end

return M
