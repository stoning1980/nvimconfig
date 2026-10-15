-- :Goto — switch projects without leaving Neovim.
--
-- Picks a directory (recently visited first, then the static list in
-- autojump.txt), then fully resets the session so it feels exactly like
-- quitting nvim and reopening it in the chosen directory: every buffer,
-- terminal, tab and window is closed, LSP clients are stopped, the global cwd
-- is changed, and the dashboard is shown.
--
-- The reset is ordered so a refusal or a bad path never touches the session,
-- and so plugin autocmds cannot rebuild the old UI while it is being torn
-- down. See goto_dir().

local M = {}

-- Static directory list, shared with the shell `j`/autojump helper.
local AUTOJUMP_FILE = "/Users/bytedance/work/tools/configfiles/autojump.txt"
-- MRU of directories visited via :Goto (persisted across sessions).
local RECENT_FILE = vim.fn.stdpath("state") .. "/goto_recent.txt"
local MAX_RECENT = 30

-- True while a switch is destroying windows and buffers. A DirChanged or
-- BufDelete handler that calls :Goto again would otherwise nest a second
-- teardown inside the first.
local switching = false

local function notify(msg, level)
  pcall(vim.notify, msg, level or vim.log.levels.INFO, { title = "Goto" })
end

--- Canonical absolute path: ~ and $VARS expanded, symlinks resolved, no
--- trailing slash. nil when `dir` is not a usable path. Resolution matters
--- because getcwd() returns the real path (`/tmp` → `/private/tmp` on macOS),
--- so an unresolved candidate would not match the directory we are already in.
---@param dir string
---@return string|nil
local function canonical(dir)
  if type(dir) ~= "string" then
    return nil
  end
  dir = vim.trim(dir)
  if dir == "" or dir:find("\n", 1, true) or dir:find("%z") then
    return nil
  end
  local abs = vim.fn.fnamemodify(vim.fn.expand(dir), ":p")
  abs = abs:gsub("/+$", "")
  if abs == "" then
    abs = "/"
  end
  local real = vim.uv.fs_realpath(abs)
  if type(real) == "string" and real ~= "" then
    abs = real:gsub("/+$", "")
  else
    abs = vim.fn.resolve(abs):gsub("/+$", "")
  end
  if abs == "" then
    return nil
  end
  return abs
end

--- Effective cwd, or nil if the current window/tab cannot answer (invalid
--- window, see haslocaldir()). Compared in canonical form.
---@return string|nil
local function current_dir()
  local ok, dir = pcall(vim.fn.getcwd)
  if not ok then
    return nil
  end
  return canonical(dir)
end

--- Read a newline-separated file into a list of trimmed, non-empty lines.
---@param path string
---@return string[]
local function read_lines(path)
  local ok, f = pcall(io.open, path, "r")
  if not ok or not f then
    return {}
  end
  local lines = {}
  local read_ok = pcall(function()
    for line in f:lines() do
      line = vim.trim(line)
      if line ~= "" then
        lines[#lines + 1] = line
      end
    end
  end)
  f:close()
  return read_ok and lines or {}
end

--- Replace `path` by writing a temp file in the same directory and renaming
--- it over the target, so a crash mid-write cannot truncate the MRU.
---@param path string
---@param lines string[]
---@return boolean ok
---@return string|nil err
local function write_lines_atomic(path, lines)
  local tmp = path .. ".tmp"
  local f, open_err = io.open(tmp, "w")
  if not f then
    return false, open_err or "cannot open recent file"
  end
  local body = table.concat(lines, "\n")
  if body ~= "" then
    body = body .. "\n"
  end
  local write_ok, write_err = pcall(function()
    f:write(body)
    f:flush()
  end)
  f:close()
  if not write_ok then
    os.remove(tmp)
    return false, tostring(write_err)
  end
  if not os.rename(tmp, path) then
    os.remove(tmp)
    return false, "cannot replace recent file"
  end
  return true
end

--- A directory we can actually enter. isdirectory() is true for a directory
--- we do not have search permission on, and :cd would then fail only after
--- the session was already gone.
---@param dir string
---@return boolean ok
---@return string|nil err
local function directory_ok(dir)
  if vim.fn.isdirectory(dir) == 0 then
    return false, "Not a directory: " .. dir
  end
  if vim.uv.fs_access(dir, "X") == false then
    return false, "Cannot enter directory: " .. dir
  end
  return true
end

--- Candidate directories: MRU (recents) first, then the static autojump
--- entries that are NOT already in the MRU. Excludes the current cwd and
--- anything that no longer exists or cannot be entered; de-duplicated by
--- real path so a symlink and its target are one entry.
---@return { dir: string, recent: boolean }[]
function M.candidates()
  local cwd = current_dir()
  local seen = {}
  local out = {}
  local function add(dir, recent)
    local ok, n = pcall(canonical, dir)
    if not ok or not n or n == cwd or seen[n] or not directory_ok(n) then
      return
    end
    seen[n] = true
    out[#out + 1] = { dir = n, recent = recent }
  end
  for _, d in ipairs(read_lines(RECENT_FILE)) do
    add(d, true)
  end
  for _, d in ipairs(read_lines(AUTOJUMP_FILE)) do
    add(d, false)
  end
  return out
end

--- Move a directory to the top of the recents MRU and persist it.
--- Failure is reported and ignored: the switch itself already happened.
---@param dir string
---@return boolean ok
---@return string|nil err
local function record_recent(dir)
  local n = canonical(dir)
  if not n then
    return false, "invalid directory"
  end
  local kept = { n }
  for _, d in ipairs(read_lines(RECENT_FILE)) do
    local cok, c = pcall(canonical, d)
    c = (cok and c) or d
    if c ~= n then
      kept[#kept + 1] = c
      if #kept >= MAX_RECENT then
        break
      end
    end
  end
  return write_lines_atomic(RECENT_FILE, kept)
end

--- File-like buffers whose text would be lost. Includes unnamed new files
--- (`:enew` then type): those have an empty name, so a name check would
--- discard them with no prompt. Terminals, help, quickfix and prompts are
--- not user files; they are closed unconditionally.
---@return integer[]
local function unsaved_buffers()
  local out = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].modified then
      local bt = vim.bo[buf].buftype
      if bt == "" or bt == "acwrite" then
        out[#out + 1] = buf
      end
    end
  end
  return out
end

local function stop_lsp()
  local get = vim.lsp and vim.lsp.get_clients
  if type(get) ~= "function" then
    return
  end
  for _, client in ipairs(get()) do
    -- One failing client must not skip the rest.
    pcall(vim.lsp.stop_client, client.id, true)
  end
end

local function stop_terminals()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].buftype == "terminal" then
      local job = vim.b[buf].terminal_job_id
      if type(job) == "number" and job > 0 then
        -- Deleting a terminal whose job is still running errors (E948) and
        -- leaves the buffer, and therefore the old cwd's shell, alive.
        pcall(vim.fn.jobstop, job)
      end
    end
  end
end

local function close_diffview()
  -- Diffview recreates its tabs from BufWinEnter. Close it while events still
  -- run, before the wipe below pretends those tabs were never there.
  if vim.fn.exists(":DiffviewClose") == 2 then
    pcall(vim.cmd, "silent! DiffviewClose")
  end
end

--- Leave exactly one real window. Floating windows survive `:only`, and
--- `:tabonly` without a bang refuses to close a tab that holds a modified
--- buffer — either one aborts the wipe with buffers still on screen.
--- Never closes the last window, which would quit Neovim.
---@return boolean
local function collapse_to_one_window()
  local keep
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(win) then
      local cfg = vim.api.nvim_win_get_config(win)
      if cfg.relative == "" then
        keep = win
        break
      end
    end
  end
  keep = keep or vim.api.nvim_get_current_win()
  if not (keep and vim.api.nvim_win_is_valid(keep)) then
    return false
  end
  pcall(vim.api.nvim_set_current_win, keep)
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if win ~= keep and vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
  -- Bang: hide modified buffers instead of aborting with E37.
  pcall(vim.cmd, "silent! tabonly!")
  return vim.api.nvim_win_is_valid(keep)
end

local function wipe_buffers(except)
  local function wipe_once()
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if buf ~= except and vim.api.nvim_buf_is_valid(buf) then
        for _, win in ipairs(vim.fn.win_findbuf(buf)) do
          if win ~= vim.api.nvim_get_current_win() and vim.api.nvim_win_is_valid(win) then
            pcall(vim.api.nvim_win_close, win, true)
          end
        end
        if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_get_current_buf() ~= buf then
          pcall(vim.api.nvim_buf_delete, buf, { force = true })
        end
      end
    end
  end
  -- A buffer still shown in a window the first pass could not close is
  -- wiped on the second pass, once that window is gone.
  wipe_once()
  wipe_once()
end

local function clear_lists()
  pcall(vim.fn.setqflist, {}, "r")
  local win = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_is_valid(win) then
    pcall(vim.fn.setloclist, win, {}, "r")
  end
  -- An old arglist would `:next` straight back into the previous project.
  -- `%argdelete` errors when the list is already empty; that is fine.
  pcall(vim.cmd, "silent! %argdelete")
end

local function show_dashboard(scratch)
  local dashboard = Snacks and Snacks.dashboard
  if type(dashboard) == "table" and type(dashboard.open) == "function" then
    local win = vim.api.nvim_get_current_win()
    if vim.api.nvim_win_is_valid(win) then
      pcall(dashboard.open, { win = win })
    end
  end
  if vim.api.nvim_buf_is_valid(scratch) and vim.api.nvim_get_current_buf() ~= scratch then
    pcall(vim.api.nvim_buf_delete, scratch, { force = true })
  end
end

--- Reset the whole session and switch to `dir`, as if reopening nvim there.
---
--- Nothing is destroyed until the path is a directory we can enter and the
--- user has agreed to drop unsaved file buffers. The cwd is changed only
--- after the old UI is gone, via nvim_set_current_dir(), so the path is not
--- parsed as an Ex command. That call also clears a window-local or
--- tab-local directory; either one would hide the new global cwd.
---@param dir string
function M.goto_dir(dir)
  if switching then
    notify("Project switch already in progress", vim.log.levels.WARN)
    return
  end

  local n = canonical(dir)
  if not n then
    notify("Invalid directory", vim.log.levels.ERROR)
    return
  end
  local ok_dir, why = directory_ok(n)
  if not ok_dir then
    notify(why, vim.log.levels.ERROR)
    return
  end
  if current_dir() == n then
    notify("Already in " .. vim.fn.fnamemodify(n, ":~"))
    return
  end

  local unsaved = unsaved_buffers()
  if #unsaved > 0 then
    local noun = #unsaved == 1 and "1 unsaved buffer" or (#unsaved .. " unsaved buffers")
    local choice = vim.fn.confirm(noun .. " will be discarded. Switch project?", "&Yes\n&No", 2)
    if choice ~= 1 then
      return
    end
  end

  -- The directory can disappear between the prompt and the wipe. Check again
  -- so a vanished path still leaves the session untouched.
  ok_dir, why = directory_ok(n)
  if not ok_dir then
    notify(why, vim.log.levels.ERROR)
    return
  end

  switching = true
  local saved_eventignore = vim.o.eventignore
  local function restore_events()
    if vim.o.eventignore ~= saved_eventignore then
      vim.o.eventignore = saved_eventignore
    end
  end

  local ok, err = xpcall(function()
    close_diffview()
    stop_lsp()

    -- Plugin autocmds (Diffview follow, file explorers, session savers,
    -- TermClose) fire on every buffer and window close and will try to
    -- rebuild the session we are throwing away. Silence them until the cwd
    -- change, which should be the one event the new project sees.
    vim.o.eventignore = "all"
    stop_terminals()

    if not collapse_to_one_window() then
      error("no window left to switch")
    end
    local scratch = vim.api.nvim_create_buf(false, true)
    local win = vim.api.nvim_get_current_win()
    local set_ok = pcall(vim.api.nvim_win_set_buf, win, scratch)
    if not set_ok then
      error("could not park the window on a scratch buffer")
    end
    wipe_buffers(scratch)
    clear_lists()

    restore_events()

    -- Drops a window-local or tab-local directory, which would otherwise
    -- hide the global cwd from this tab.
    local ch_ok, ch_err = pcall(vim.api.nvim_set_current_dir, n)
    if not ch_ok then
      notify("Could not enter " .. n .. ": " .. tostring(ch_err), vim.log.levels.ERROR)
      show_dashboard(scratch)
      return
    end

    pcall(vim.cmd, "silent! clearjumps")
    pcall(vim.cmd, "silent! delmarks!")
    show_dashboard(scratch)

    local rec_ok, rec_err = record_recent(n)
    if not rec_ok then
      notify("Switched, but could not save recents: " .. tostring(rec_err), vim.log.levels.WARN)
    end
    notify("Switched to " .. vim.fn.fnamemodify(n, ":~"))
  end, debug.traceback)

  restore_events()
  switching = false
  if not ok then
    notify("Project switch failed: " .. tostring(err), vim.log.levels.ERROR)
  end
end

--- Open the directory picker.
function M.pick()
  local dirs = M.candidates()
  if #dirs == 0 then
    notify("No directories to go to", vim.log.levels.WARN)
    return
  end

  local items = {}
  for i, entry in ipairs(dirs) do
    -- Mark MRU entries with a history icon; pad static ones so paths align.
    local marker = entry.recent and "󰋚 " or "   "
    items[#items + 1] = {
      text = marker .. vim.fn.fnamemodify(entry.dir, ":~"),
      dir = entry.dir,
      idx = i,
    }
  end

  local function go(dir)
    if type(dir) ~= "string" or dir == "" then
      return
    end
    -- After the picker closes, so its own window is not part of the wipe
    -- and confirm() is not nested inside the picker's callback.
    vim.schedule(function()
      M.goto_dir(dir)
    end)
  end

  if Snacks and Snacks.picker then
    Snacks.picker.pick({
      source = "goto",
      items = items,
      format = "text",
      title = "Goto Project",
      preview = "none",
      layout = { preset = "select", preview = false },
      confirm = function(picker, item)
        picker:close()
        if item then
          go(item.dir)
        end
      end,
    })
    return
  end

  vim.ui.select(items, {
    prompt = "Goto Project",
    format_item = function(item)
      return item.text
    end,
  }, function(choice)
    if choice then
      go(choice.dir)
    end
  end)
end

function M.setup()
  vim.api.nvim_create_user_command("Goto", function()
    M.pick()
  end, { desc = "Switch project: pick a directory and reset the session" })
end

return M
