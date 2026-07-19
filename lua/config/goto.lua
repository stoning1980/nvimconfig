-- :Goto — switch projects without leaving Neovim.
--
-- Picks a directory (recently visited first, then the static list in
-- autojump.txt), then fully resets the session so it feels exactly like
-- quitting nvim and reopening it in the chosen directory: every buffer,
-- terminal, tab and window is closed, LSP clients are stopped, the global cwd
-- is changed, and the dashboard is shown.

local M = {}

-- Static directory list, shared with the shell `j`/autojump helper.
local AUTOJUMP_FILE = "/Users/bytedance/work/tools/configfiles/autojump.txt"
-- MRU of directories visited via :Goto (persisted across sessions).
local RECENT_FILE = vim.fn.stdpath("state") .. "/goto_recent.txt"
local MAX_RECENT = 30

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = "Goto" })
end

--- Absolute, ~-expanded path with any trailing slash removed.
---@param dir string
---@return string
local function normalize(dir)
  local abs = vim.fn.fnamemodify(vim.fn.expand(dir), ":p")
  abs = abs:gsub("/+$", "")
  return abs == "" and "/" or abs
end

--- Read a newline-separated file into a list of trimmed, non-empty lines.
---@param path string
---@return string[]
local function read_lines(path)
  local lines = {}
  local f = io.open(path, "r")
  if not f then
    return lines
  end
  for line in f:lines() do
    line = vim.trim(line)
    if line ~= "" then
      lines[#lines + 1] = line
    end
  end
  f:close()
  return lines
end

--- Candidate directories: MRU (recents) first, then the static autojump
--- entries that are NOT already in the MRU. Excludes the current cwd and
--- anything that no longer exists on disk; de-duplicated.
---@return { dir: string, recent: boolean }[]
function M.candidates()
  local cwd = normalize(vim.fn.getcwd())
  local seen = {}
  local out = {}
  local function add(dir, recent)
    local n = normalize(dir)
    if n == cwd or seen[n] or vim.fn.isdirectory(n) == 0 then
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
---@param dir string
local function record_recent(dir)
  local n = normalize(dir)
  local kept = { n }
  for _, d in ipairs(read_lines(RECENT_FILE)) do
    if normalize(d) ~= n then
      kept[#kept + 1] = normalize(d)
      if #kept >= MAX_RECENT then
        break
      end
    end
  end
  local f = io.open(RECENT_FILE, "w")
  if f then
    f:write(table.concat(kept, "\n") .. "\n")
    f:close()
  end
end

--- Whether any modifiable file buffer has unsaved changes.
---@return boolean
local function has_unsaved()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if
      vim.api.nvim_buf_is_valid(buf)
      and vim.bo[buf].modified
      and vim.bo[buf].buftype == ""
      and vim.api.nvim_buf_get_name(buf) ~= ""
    then
      return true
    end
  end
  return false
end

--- Reset the whole session and switch to `dir`, as if reopening nvim there.
---@param dir string
function M.goto_dir(dir)
  local n = normalize(dir)
  if vim.fn.isdirectory(n) == 0 then
    notify("Not a directory: " .. n, vim.log.levels.ERROR)
    return
  end

  if has_unsaved() then
    local choice = vim.fn.confirm("Unsaved changes will be discarded. Switch project?", "&Yes\n&No", 2)
    if choice ~= 1 then
      return
    end
  end

  record_recent(n)

  -- Stop LSP clients attached to the previous project so the new one starts
  -- clean (they re-attach on demand for buffers opened afterwards).
  pcall(function()
    for _, client in ipairs(vim.lsp.get_clients()) do
      vim.lsp.stop_client(client.id, true)
    end
  end)

  -- Collapse to a single tab/window holding a throwaway scratch buffer, then
  -- wipe every real buffer (files, terminals, help, etc.).
  vim.cmd("silent! tabonly")
  vim.cmd("silent! only")
  local scratch = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(0, scratch)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if buf ~= scratch and vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end

  -- Switch the global working directory and drop stale jump history.
  vim.cmd("cd " .. vim.fn.fnameescape(n))
  vim.cmd("silent! clearjumps")
  pcall(vim.cmd, "delmarks!")

  -- Show the dashboard in the current window, mimicking a fresh launch.
  if Snacks and Snacks.dashboard then
    Snacks.dashboard.open({ win = vim.api.nvim_get_current_win() })
    if vim.api.nvim_buf_is_valid(scratch) and vim.api.nvim_get_current_buf() ~= scratch then
      pcall(vim.api.nvim_buf_delete, scratch, { force = true })
    end
  end

  notify("Switched to " .. vim.fn.fnamemodify(n, ":~"))
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
          vim.schedule(function()
            M.goto_dir(item.dir)
          end)
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
      M.goto_dir(choice.dir)
    end
  end)
end

function M.setup()
  vim.api.nvim_create_user_command("Goto", function()
    M.pick()
  end, { desc = "Switch project: pick a directory and reset the session" })
end

return M
