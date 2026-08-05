-- Autocmds are automatically loaded on the VeryLazy event
-- Default autocmds that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/autocmds.lua
--
-- Add any additional autocmds here
-- with `vim.api.nvim_create_autocmd`
--
-- Or remove existing autocmds by their group name (which is prefixed with `lazyvim_` for the defaults)
-- e.g. vim.api.nvim_del_augroup_by_name("lazyvim_wrap_spell")

-- Make split lines and float/panel borders easier to see (tokyonight's default
-- WinSeparator is very close to the background).
local function brighten_separators()
  local border = vim.api.nvim_get_hl(0, { name = "FloatBorder", link = false })
  local fg = border.fg
  if not fg then
    border = vim.api.nvim_get_hl(0, { name = "Comment", link = false })
    fg = border.fg
  end
  if not fg then
    return
  end

  local sep = { fg = fg, bg = "NONE", bold = true }
  vim.api.nvim_set_hl(0, "WinSeparator", sep)
  vim.api.nvim_set_hl(0, "VertSplit", { link = "WinSeparator" })
  vim.api.nvim_set_hl(0, "HorizSplit", { link = "WinSeparator" })
  vim.api.nvim_set_hl(0, "SnacksWinSeparator", { link = "WinSeparator" })
end

vim.api.nvim_create_autocmd("ColorScheme", {
  group = vim.api.nvim_create_augroup("user_bright_separators", { clear = true }),
  callback = brighten_separators,
})

-- Colorscheme is already loaded by the time VeryLazy runs; apply once now too.
brighten_separators()

-- Make diff highlights (Diffview, :diffthis, gitsigns preview) much more
-- visible: stronger line backgrounds plus a bright "changed word" color so the
-- exact edits inside a line stand out.
local function improve_diff_colors()
  -- Added / deleted / changed line backgrounds.
  vim.api.nvim_set_hl(0, "DiffAdd", { bg = "#1f3b2b", fg = "NONE" })
  vim.api.nvim_set_hl(0, "DiffDelete", { bg = "#48232b", fg = "NONE" })
  vim.api.nvim_set_hl(0, "DiffChange", { bg = "#25324d", fg = "NONE" })
  -- The actual changed text within a line (the most important part).
  vim.api.nvim_set_hl(0, "DiffText", { bg = "#3f6d9c", fg = "NONE", bold = true })

  -- Diffview's own enhanced groups: emphasize changed regions, dim the rest.
  vim.api.nvim_set_hl(0, "DiffviewDiffAddAsDelete", { bg = "#48232b" })
  vim.api.nvim_set_hl(0, "DiffAddText", { bg = "#2f6b3a", fg = "NONE", bold = true })
  vim.api.nvim_set_hl(0, "DiffDeleteText", { bg = "#8a2f3a", fg = "NONE", bold = true })
end

vim.api.nvim_create_autocmd("ColorScheme", {
  group = vim.api.nvim_create_augroup("user_diff_colors", { clear = true }),
  callback = improve_diff_colors,
})

improve_diff_colors()

-- Auto-reload files changed outside Neovim. `autoread` lets Nvim pick up the
-- new contents, but only when it actually checks the file -- so trigger a
-- `checktime` on focus, buffer enter, and when idle, then announce reloads.
vim.o.autoread = true

local autoread = vim.api.nvim_create_augroup("user_autoread", { clear = true })

vim.api.nvim_create_autocmd({ "FocusGained", "BufEnter", "CursorHold", "CursorHoldI", "TermClose", "TermLeave" }, {
  group = autoread,
  callback = function()
    -- Don't run checktime in command-line window or for non-file buffers.
    if vim.fn.getcmdwintype() ~= "" then
      return
    end
    if vim.bo.buftype ~= "" then
      return
    end
    vim.cmd("checktime")
  end,
})

vim.api.nvim_create_autocmd("FileChangedShellPost", {
  group = autoread,
  callback = function()
    vim.notify("File changed on disk. Buffer reloaded.", vim.log.levels.INFO, { title = "autoread" })
  end,
})

-- Autosave, modeled on VSCode's `afterDelay` + `onFocusChange` and IntelliJ's
-- save-on-frame-deactivation. Two triggers:
--   1. Debounced while typing -- a timer restarts on every change and only
--      writes ~1000ms after you stop, so we never save on each keystroke.
--   2. Immediate flush when a buffer or the editor loses focus.
-- All writes are guarded to touch only real, modifiable, named file buffers
-- with unsaved changes, and use `noautocmd` to avoid churning other autocmds.
local autosave = vim.api.nvim_create_augroup("user_autosave", { clear = true })
local autosave_delay = 1000
local autosave_timer = assert(vim.uv.new_timer())

local function autosave_eligible(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return false
  end
  if not vim.bo[buf].modifiable or vim.bo[buf].readonly then
    return false
  end
  -- Only ordinary file buffers (skip terminals, help, quickfix, prompts...).
  if vim.bo[buf].buftype ~= "" then
    return false
  end
  if not vim.bo[buf].modified then
    return false
  end
  if vim.api.nvim_buf_get_name(buf) == "" then
    return false
  end
  return true
end

local function autosave_write(buf)
  if not autosave_eligible(buf) then
    return
  end
  -- `keepjumps`/`noautocmd` keep the write side-effect-free; `silent` avoids
  -- the "written" message on every debounce tick.
  vim.api.nvim_buf_call(buf, function()
    vim.cmd("silent noautocmd keepjumps write")
  end)
end

local function autosave_schedule(buf)
  autosave_timer:stop()
  autosave_timer:start(
    autosave_delay,
    0,
    vim.schedule_wrap(function()
      autosave_write(buf)
    end)
  )
end

-- Debounced trigger while editing (VSCode `afterDelay`).
vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "InsertLeave" }, {
  group = autosave,
  callback = function(args)
    if autosave_eligible(args.buf) then
      autosave_schedule(args.buf)
    end
  end,
})

-- Immediate flush on focus/buffer leave (VSCode `onFocusChange`, IntelliJ
-- frame deactivation). Cancel any pending debounce first so we don't
-- double-write.
vim.api.nvim_create_autocmd({ "BufLeave", "FocusLost" }, {
  group = autosave,
  callback = function(args)
    autosave_timer:stop()
    autosave_write(args.buf)
  end,
})

-- :FileAbsolutePath -- copy the current file's absolute path to the system
-- clipboard (the `+` register).
vim.api.nvim_create_user_command("FileAbsolutePath", function()
  local path = vim.api.nvim_buf_get_name(0)
  if path == "" then
    vim.notify("No file associated with the current buffer", vim.log.levels.WARN, { title = "FileAbsolutePath" })
    return
  end
  path = vim.fn.fnamemodify(path, ":p")
  vim.fn.setreg("+", path)
  vim.notify("Copied to clipboard:\n" .. path, vim.log.levels.INFO, { title = "FileAbsolutePath" })
end, { desc = "Copy the current file's absolute path to the system clipboard" })

-- :FileRepoPath -- copy the current file's path relative to the project root
-- (the git repo root, or the nearest .git/package.json/etc.) to the system
-- clipboard. Falls back to the absolute path when no root can be found.
vim.api.nvim_create_user_command("FileRepoPath", function()
  local abs = vim.api.nvim_buf_get_name(0)
  if abs == "" then
    vim.notify("No file associated with the current buffer", vim.log.levels.WARN, { title = "FileRepoPath" })
    return
  end
  abs = vim.fn.fnamemodify(abs, ":p")
  local root = vim.fs.root(abs, { ".git", ".hg", ".svn" }) or vim.fn.getcwd()
  local rel = abs
  if root and root ~= "" then
    root = vim.fn.fnamemodify(root, ":p"):gsub("/$", "")
    if abs:sub(1, #root + 1) == root .. "/" then
      rel = abs:sub(#root + 2)
    end
  end
  vim.fn.setreg("+", rel)
  vim.notify("Copied to clipboard:\n" .. rel, vim.log.levels.INFO, { title = "FileRepoPath" })
end, { desc = "Copy the current file's path relative to the repo/project root to the system clipboard" })
