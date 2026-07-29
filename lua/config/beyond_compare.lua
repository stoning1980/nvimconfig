-- Open the two sides of the current diff in Beyond Compare (`:BeyondCompare`).
--
-- Works from a Diffview (git revisions, index, working tree) and from any plain
-- diff-mode split such as the one `:CompareFiles` / `:diffsplit` creates.
--
-- Git revisions don't exist on disk, so their buffer contents are dumped into a
-- temp file and passed read-only. The working-tree side is passed as its real
-- path so edits made in Beyond Compare land on the actual file (the autoread
-- autocmd in config.autocmds reloads the buffer when Neovim regains focus).
-- A working-tree buffer with unsaved changes is dumped to a temp file too,
-- since the file on disk no longer matches what the diff is showing.
local M = {}

local BCOMP_CANDIDATES = {
  "bcomp",
  "bcompare",
  "/Applications/Beyond Compare.app/Contents/MacOS/bcomp",
}

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = "Beyond Compare" })
end

local function find_bcomp()
  for _, cmd in ipairs(BCOMP_CANDIDATES) do
    if vim.fn.executable(cmd) == 1 then
      return cmd:sub(1, 1) == "/" and cmd or vim.fn.exepath(cmd)
    end
  end
  return nil
end

-- Path components must survive as a real filename: Beyond Compare picks its
-- syntax rules from the extension, and ":" confuses macOS file APIs.
local function sanitize(name)
  return (vim.trim(name or ""):gsub("[/\\:]", "_"):gsub("%s+", "_"))
end

-- Each side is written as <tmp>/<tag>/<basename> so the extension is preserved
-- and the parent directory alone identifies which revision it came from. These
-- live under Neovim's per-instance temp directory, which it removes on exit.
local function write_side(dir, tag, basename, lines)
  local sub = dir .. "/" .. sanitize(tag)
  vim.fn.mkdir(sub, "p")
  local path = sub .. "/" .. (basename ~= "" and basename or "buffer")
  if vim.fn.writefile(lines, path) ~= 0 then
    return nil
  end
  return path
end

local function buf_lines(bufnr)
  if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then
    return {}
  end
  vim.fn.bufload(bufnr)
  return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
end

-- Short identifier for a Diffview side, used both as the temp directory name
-- and (with the path appended) as the Beyond Compare pane title.
local function rev_tag(file, index)
  local rev = file.rev
  local ok, rev_mod = pcall(require, "diffview.vcs.rev")
  if ok and rev and rev.type then
    local RevType = rev_mod.RevType
    if rev.type == RevType.LOCAL then
      return "WORKING TREE"
    elseif rev.type == RevType.STAGE then
      return "INDEX"
    elseif rev.type == RevType.COMMIT then
      return rev:abbrev(8) or "COMMIT"
    end
  end
  return "side" .. index
end

-- Describe one Diffview pane: where its content lives and how to label it.
local function diffview_side(file, index)
  local tag = rev_tag(file, index)
  local side = {
    tag = tag,
    basename = file.basename or "",
    title = tag .. " - " .. (file.path or file.basename or ""),
  }

  if file.nulled then
    -- Added or deleted on this side: an empty pane is the honest representation.
    -- Diffview's binary probe (`git grep` against the rev) fails for a path that
    -- doesn't exist there, so its `binary` flag is meaningless here.
    side.lines = {}
    return side
  end

  side.binary = file.binary == true

  local ok, rev_mod = pcall(require, "diffview.vcs.rev")
  local is_local = ok and file.rev and file.rev.type == rev_mod.RevType.LOCAL
  local modified = file.bufnr and vim.api.nvim_buf_is_valid(file.bufnr) and vim.bo[file.bufnr].modified

  if is_local and not modified and file.absolute_path and vim.fn.filereadable(file.absolute_path) == 1 then
    side.path = file.absolute_path
    side.editable = true
    return side
  end

  side.unsaved = is_local and modified or nil
  side.lines = buf_lines(file.bufnr)
  return side
end

local function diffview_sides()
  local ok, lib = pcall(require, "diffview.lib")
  if not ok then
    return nil
  end
  local view = lib.get_current_view()
  local layout = view and view.cur_layout
  if not (layout and layout.windows) then
    return nil
  end

  local sides = {}
  for i, win in ipairs(layout.windows) do
    if win.file then
      table.insert(sides, diffview_side(win.file, i))
    end
  end
  return #sides >= 2 and sides or nil
end

-- Fall back to plain diff-mode windows (`:CompareFiles`, `:diffsplit`), ordered
-- the way they appear on screen so left/top becomes Beyond Compare's left pane.
local function diff_window_sides()
  local wins = {}
  for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.wo[winid].diff then
      table.insert(wins, winid)
    end
  end
  if #wins < 2 then
    return nil
  end

  table.sort(wins, function(a, b)
    local pa, pb = vim.fn.win_screenpos(a), vim.fn.win_screenpos(b)
    if pa[1] ~= pb[1] then
      return pa[1] < pb[1]
    end
    return pa[2] < pb[2]
  end)

  local sides = {}
  for i, winid in ipairs(wins) do
    local bufnr = vim.api.nvim_win_get_buf(winid)
    local name = vim.api.nvim_buf_get_name(bufnr)
    local basename = name ~= "" and vim.fn.fnamemodify(name, ":t") or ""
    local side = {
      tag = basename ~= "" and ("side" .. i) or ("buffer" .. i),
      basename = basename,
      title = name ~= "" and vim.fn.fnamemodify(name, ":~") or ("[No Name] " .. i),
    }
    if name ~= "" and vim.fn.filereadable(name) == 1 and not vim.bo[bufnr].modified then
      side.path = name
      side.editable = true
    else
      side.unsaved = vim.bo[bufnr].modified or nil
      side.lines = buf_lines(bufnr)
    end
    table.insert(sides, side)
  end
  return sides
end

-- Open the current diff's two sides in Beyond Compare.
function M.open()
  local bcomp = find_bcomp()
  if not bcomp then
    notify("Beyond Compare not found (looked for bcomp / bcompare on $PATH)", vim.log.levels.ERROR)
    return
  end

  local sides = diffview_sides() or diff_window_sides()
  if not sides then
    notify("No diff to compare — open a Diffview or a diff split first", vim.log.levels.ERROR)
    return
  end

  if sides[1].binary or sides[2].binary then
    notify("Binary file — Beyond Compare needs the files on disk, not the diff buffers", vim.log.levels.WARN)
    return
  end

  local extra = #sides > 2 and #sides - 2 or 0
  sides = { sides[1], sides[2] }

  local dir
  for _, side in ipairs(sides) do
    if not side.path then
      dir = dir or vim.fn.tempname()
      local path = write_side(dir, side.tag, side.basename, side.lines or {})
      if not path then
        notify("Failed to write temp file for " .. side.title, vim.log.levels.ERROR)
        return
      end
      side.path = path
    end
  end

  local cmd = { bcomp, sides[1].path, sides[2].path }
  for i, side in ipairs(sides) do
    table.insert(cmd, "-title" .. i .. "=" .. side.title)
    if not side.editable then
      table.insert(cmd, "-ro" .. i)
    end
  end

  vim.system(cmd, { detach = true }, function(res)
    -- Beyond Compare uses low exit codes to report the comparison result
    -- (0 same … 14 conflicts); only 100+ means the launch itself failed.
    if res.code >= 100 then
      vim.schedule(function()
        notify("Beyond Compare exited with " .. res.code .. "\n" .. (res.stderr or ""), vim.log.levels.ERROR)
      end)
    end
  end)

  local msgs = { sides[1].title .. "  ↔  " .. sides[2].title }
  if sides[1].unsaved or sides[2].unsaved then
    table.insert(msgs, "Unsaved buffer copied to a temp file (read-only) — save to compare the real file.")
  end
  if extra > 0 then
    table.insert(msgs, ("Compared the first two of %d panes."):format(extra + 2))
  end
  notify(table.concat(msgs, "\n"))
end

function M.setup()
  vim.api.nvim_create_user_command("BeyondCompare", function()
    M.open()
  end, { nargs = 0, desc = "Open the current diff's two sides in Beyond Compare" })
end

return M
