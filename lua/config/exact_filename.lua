-- Whole-string filename matching for the Snacks files picker.
--
-- The picker matcher is fuzzy and scores the full path. File search instead
-- compares the query to the filename only, as one string: the filename must
-- equal the query. Directory names are not part of the comparison.
--
-- The matcher trims bytes <= 32 and splits the query on spaces, so the query
-- and the filename are wrapped in private-use sentinels before matching.
-- A literal find of the wrapped query then succeeds only when the two strings
-- are equal.

local M = {}

-- U+E000 / U+E001 are private-use and do not occur in filenames.
local MARK = "\u{E000}"
local SPACE = "\u{E001}"

--- Last path component. Empty input stays empty.
---@param path string?
---@return string
function M.basename(path)
  return (path or ""):match("[^/\\]+$") or path or ""
end

--- Collapse spaces so the matcher treats the query as one string.
---@param text string
---@return string
local function seal(text)
  return MARK .. text:gsub(" ", SPACE) .. MARK
end

--- `item.text` value: the sealed filename, not the path.
---@param path string?
---@return string
function M.item_text(path)
  return seal(M.basename(path))
end

--- Matcher pattern. Empty query stays empty so the picker still lists every file.
---@param query string?
---@return string
function M.pattern(query)
  if not query or query == "" then
    return ""
  end
  return seal(query)
end

--- fd regex for one filename, plus `-i` so letter case is ignored.
--- fd matches this against the filename, not the directory path.
---@param query string
---@return string
function M.fd_query(query)
  local escaped = query:gsub("[\\^$.|?*+()[%]{}]", "\\%0")
  return "^" .. escaped .. "$ -- -i"
end

--- True when `fd` can take the filename query. Without it, the picker lists
--- files and the matcher filters them.
function M.fd_available()
  return vim.fn.executable("fd") == 1 or vim.fn.executable("fdfind") == 1
end

--- Point the file finder at an exact filename when the user has typed one.
--- `fd` then returns only that name, which matters in a tree of hundreds of
--- thousands of files: the match no longer waits until every other path has
--- been read.
---@param filter snacks.picker.Filter|{pattern: string, search: string}
function M.prepare_filter(filter)
  local raw = filter.pattern or ""
  if raw == "" then
    return
  end
  filter.pattern = M.pattern(raw)
  if M.fd_available() then
    filter.search = M.fd_query(raw)
  end
end

-- Wait until typing pauses before starting `fd`. Each keystroke otherwise
-- walks the whole tree and kills the previous walk.
local FD_DEBOUNCE_MS = 300

---@param picker snacks.Picker
function M.disarm_fd(picker)
  local timer = picker._exact_fd_timer
  if not timer then
    return
  end
  timer:stop()
  timer:close()
  picker._exact_fd_timer = nil
end

--- Seal the query for the matcher, and start one `fd` search after typing pauses.
--- An empty query does not list the tree.
---@param picker snacks.Picker
---@param filter snacks.picker.Filter|{pattern: string, search: string}
function M.hold_fd(picker, filter)
  local raw = filter.pattern or ""
  if raw == "" then
    M.disarm_fd(picker)
    filter.pattern = ""
    filter.search = ""
    return
  end
  filter.pattern = M.pattern(raw)
  if not M.fd_available() then
    return
  end
  local fd = M.fd_query(raw)
  if filter.search == fd then
    M.disarm_fd(picker)
    return
  end
  M.disarm_fd(picker)
  local timer = vim.uv.new_timer()
  picker._exact_fd_timer = timer
  timer:start(
    FD_DEBOUNCE_MS,
    0,
    vim.schedule_wrap(function()
      if picker._exact_fd_timer == timer then
        timer:stop()
        timer:close()
        picker._exact_fd_timer = nil
      end
      if picker.closed or not picker.input or not picker.input.filter then
        return
      end
      if vim.trim(picker.input.filter.pattern or "") ~= raw then
        return
      end
      if picker.input.filter.search == fd then
        return
      end
      picker.input.filter.search = fd
      picker:find({ refresh = false })
    end)
  )
end

--- Directory `<leader><space>` should search.
---
--- `~/work/code/ios2` is not a git repo. It holds `TikTok/` and `pnsSDK/`,
--- each with its own `.git`. Root detection follows the current file into one
--- of those, so a filename that lives in the other repo never appears.
--- When the working directory is that parent, search the parent.
---@param cwd string?
---@param root string?
---@return string
function M.search_cwd(cwd, root)
  cwd = vim.fs.normalize(cwd or "")
  root = vim.fs.normalize(root or "")
  if cwd == "" then
    return root
  end
  if root == "" or cwd == root then
    return cwd
  end
  if vim.fs.dirname(root) ~= cwd then
    return root
  end
  if vim.uv.fs_stat(cwd .. "/.git") then
    return root
  end
  return cwd
end

return M
