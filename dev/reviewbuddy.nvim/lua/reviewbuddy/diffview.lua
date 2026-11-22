local M = {}

local CONTEXT_LINES = 3
local FALLBACK_REV_TYPE = { LOCAL = 1, COMMIT = 2, STAGE = 3, CUSTOM = 4 }
local ok, rev_module = pcall(require, "diffview.vcs.rev")
local REV_TYPE = ok and rev_module.RevType or FALLBACK_REV_TYPE

---@param file table
---@return string
local function file_text(file)
  if file.nulled then
    return ""
  end
  local bufnr = file.bufnr
  if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then
    return ""
  end
  vim.fn.bufload(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  return #lines == 0 and "" or table.concat(lines, "\n") .. "\n"
end

---@param file table
---@param head string
---@return table
---@param value string
---@return integer
local function hunk_count(value)
  if value == "" then
    return 1
  end
  return tonumber(value) or 0
end

---@param start_line integer
---@param count integer
---@param selection_start integer
---@param selection_end integer
---@return boolean
local function overlaps(start_line, count, selection_start, selection_end)
  if count == 0 then
    return false
  end
  return start_line <= selection_end and start_line + count - 1 >= selection_start
end

---@param window table
---@return boolean
local function displays_null_buffer(window)
  if type(window.is_nulled) ~= "function" then
    return false
  end
  local ok, nulled = pcall(window.is_nulled, window)
  return ok and nulled or false
end

---@param window table
---@return boolean
local function displays_file(window)
  if type(window.is_file_open) ~= "function" then
    return false
  end
  local call_ok, open = pcall(window.is_file_open, window)
  return call_ok and open or false
end

---@param file table
---@return boolean
local function is_conflict_stage(file)
  local stage = file.rev and file.rev.stage
  return type(stage) == "number" and stage > 0
end

---@param patch string
---@param start_line integer
---@param end_line integer
---@return string[]
local function relevant_hunks(patch, start_line, end_line)
  local hunks = {}
  local current
  for line in (patch .. "\n"):gmatch("(.-)\n") do
    local base_start, base_count, target_start, target_count = line:match("^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@")
    if base_start then
      current = {
        lines = { line },
        base_start = tonumber(base_start),
        base_count = hunk_count(base_count),
        target_start = tonumber(target_start),
        target_count = hunk_count(target_count),
      }
      hunks[#hunks + 1] = current
    elseif current then
      current.lines[#current.lines + 1] = line
    end
  end

  local selected = {}
  for _, hunk in ipairs(hunks) do
    if overlaps(hunk.target_start, hunk.target_count, start_line, end_line) then
      selected[#selected + 1] = table.concat(hunk.lines, "\n")
    end
  end
  return selected
end

---@param base_file table
---@param target_file table
---@param start_line integer
---@param end_line integer
---@return string|nil
local function patch_for_selection(base_file, target_file, start_line, end_line)
  local patch = vim.diff(file_text(base_file), file_text(target_file), {
    result_type = "unified",
    algorithm = "histogram",
    ctxlen = CONTEXT_LINES,
  })
  if not patch or patch == "" then
    return nil
  end
  local hunks = relevant_hunks(patch, start_line, end_line)
  if #hunks == 0 then
    return nil
  end
  return table.concat({
    "--- before:" .. base_file.path,
    "+++ current:" .. target_file.path,
    table.concat(hunks, "\n"),
  }, "\n")
end

---@param file table
---@return boolean
function M.matches_worktree(file)
  if file.nulled or not file.absolute_path or vim.fn.filereadable(file.absolute_path) ~= 1 then
    return false
  end
  local bufnr = file.bufnr
  if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then
    return false
  end
  vim.fn.bufload(bufnr)
  local buffer_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local disk_lines = vim.fn.readfile(file.absolute_path)
  if #disk_lines == 0 and #buffer_lines == 1 and buffer_lines[1] == "" then
    return true
  end
  return vim.deep_equal(buffer_lines, disk_lines)
end

---@param file table
---@return boolean
function M.is_worktree(file)
  return file.rev and file.rev.type == REV_TYPE.LOCAL or false
end

---@param file table
---@param head string
---@return boolean
local function is_current_right_side(file, head)
  local revision = file.rev or {}
  if revision.type == REV_TYPE.COMMIT then
    return revision.commit == head
  end
  return revision.type == REV_TYPE.LOCAL
end

---@param view table
---@param winid integer
---@return boolean
function M.contains_window(view, winid)
  local windows = view and view.cur_layout and view.cur_layout.windows or {}
  for _, window in ipairs(windows) do
    if window.id == winid then
      return true
    end
  end
  return false
end

---@param view table
---@param winid integer
---@param selection table
---@param metadata table
---@return table|nil, string|nil
function M.snapshot(view, winid, selection, metadata)
  local layout = view and view.cur_layout
  local windows = layout and layout.windows
  if not windows or #windows ~= 2 then
    return nil, "Review comments support only two-way Diffview layouts"
  end

  local anchor_index
  for index, window in ipairs(windows) do
    if window.id == winid then
      anchor_index = index
      break
    end
  end
  if not anchor_index then
    return nil, "current window is not a Diffview file pane"
  end
  if anchor_index ~= 2 then
    return nil, "Review comments must be made from the right/current Diffview pane"
  end

  local base_file = windows[1].file
  local target_file = windows[2].file
  if not (base_file and target_file) then
    return nil, "Diffview file context is unavailable"
  end
  if target_file.binary or (base_file.binary and not base_file.nulled) then
    return nil, "binary Diffview files cannot be reviewed as text"
  end
  if is_conflict_stage(base_file) or is_conflict_stage(target_file) then
    return nil, "conflicting Diffview stages cannot be reviewed as a two-way comparison"
  end
  if not is_current_right_side(target_file, metadata.revision) then
    return nil, "right Diffview pane is not the checked-out HEAD or working tree"
  end

  local target_window = windows[2]
  if target_file.nulled then
    return nil, "the selected Diffview side has no file content"
  end
  if displays_null_buffer(target_window) then
    return nil, "the selected Diffview side is displaying the null buffer"
  end
  if not displays_file(target_window) then
    return nil, "right Diffview pane is not displaying its current file"
  end

  local base_window = windows[1]
  if base_file.nulled then
    if type(base_window.is_nulled) == "function" and not displays_null_buffer(base_window) then
      return nil, "left Diffview pane is not displaying its expected null file"
    end
  elseif displays_null_buffer(base_window) then
    return nil, "the other Diffview side is displaying the null buffer"
  elseif not displays_file(base_window) then
    return nil, "left Diffview pane is not displaying its comparison file"
  end

  local root = view.adapter and view.adapter.ctx and view.adapter.ctx.toplevel
  if not root then
    return nil, "Diffview repository context is unavailable"
  end

  local change = {
    patch = patch_for_selection(base_file, target_file, selection.start_line, selection.end_line),
  }
  if not change.patch then
    change.note = "No changed hunk overlaps the selected current lines."
  end

  return {
    repo_root = root,
    path = target_file.path,
    start_line = selection.start_line,
    start_col = selection.start_col,
    end_line = selection.end_line,
    end_col = selection.end_col,
    text = selection.text,
    branch = metadata.branch,
    revision = metadata.revision,
    change = change,
  }
end

return M
