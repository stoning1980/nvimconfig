-- Android Studio / JetBrains "Annotate" style git blame gutter.
--
-- Opens a scroll- and cursor-bound vertical split to the left of the current
-- window and prints `date author` for EVERY line of the file (unlike gitsigns'
-- blame window, which collapses consecutive lines from the same commit).

local M = {}

local ns = vim.api.nvim_create_namespace("git_annotate")

-- Upper bound on how long `git blame` may run before we cancel and tell the
-- user, so F4 can never leave a spinner spinning forever on a giant file or a
-- wedged git process.
local BLAME_TIMEOUT_MS = 30000

local state = {
  win = nil, --- @type integer? annotate window id
  buf = nil, --- @type integer? annotate buffer id
  src_win = nil, --- @type integer? source window id
  src_buf = nil, --- @type integer? source buffer the blame belongs to
  job = nil, --- @type vim.SystemObj? in-flight `git blame` handle
  gen = 0, --- @type integer bumped on every open/close to reject stale job callbacks
  spinner_win = nil, --- @type integer? progress spinner window id
  spinner_timer = nil, --- @type uv.uv_timer_t? spinner animation timer
  augroup = nil, --- @type integer? autocmd group that auto-closes on buffer change
}

local SPINNER = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

-- Floating spinner shown while `git blame` runs so the user knows work is in
-- flight (blame can take seconds on a huge repo). Anchored top-right.
local function start_spinner(msg)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  local function frame(sym)
    return " " .. sym .. " " .. msg .. " "
  end
  local text = frame(SPINNER[1])
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { text })
  local win = vim.api.nvim_open_win(buf, false, {
    relative = "editor",
    anchor = "NE",
    row = 1,
    col = vim.o.columns - 1,
    width = vim.fn.strdisplaywidth(text),
    height = 1,
    style = "minimal",
    border = "rounded",
    focusable = false,
    zindex = 200,
    noautocmd = true,
  })
  vim.wo[win].winhl = "Normal:NormalFloat"
  local i = 1
  local timer = assert(vim.uv.new_timer())
  timer:start(
    80,
    80,
    vim.schedule_wrap(function()
      if not (buf and vim.api.nvim_buf_is_valid(buf)) then
        return
      end
      i = i % #SPINNER + 1
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { frame(SPINNER[i]) })
    end)
  )
  state.spinner_win, state.spinner_timer = win, timer
end

local function stop_spinner()
  if state.spinner_timer then
    state.spinner_timer:stop()
    state.spinner_timer:close()
    state.spinner_timer = nil
  end
  if state.spinner_win and vim.api.nvim_win_is_valid(state.spinner_win) then
    vim.api.nvim_win_close(state.spinner_win, true)
  end
  state.spinner_win = nil
end

-- Distinct foreground colors so adjacent commits are visually separable, the
-- way Android Studio tints its annotate gutter.
local PALETTE = {
  "#7aa2f7",
  "#7dcfff",
  "#73daca",
  "#9ece6a",
  "#e0af68",
  "#ff9e64",
  "#f7768e",
  "#bb9af7",
  "#2ac3de",
  "#c0caf5",
}

local UNCOMMITTED = string.rep("0", 40)

-- Cap the author column so one long name/email can't blow up the panel width.
-- 10 keeps short usernames whole while staying compact; longer names are cut and
-- marked with an ellipsis (e.g. "junjiang.…").
local MAX_AUTHOR_WIDTH = 10

-- Truncate `s` to at most `max` display columns, replacing the overflow with a
-- single-column ellipsis. Works on character boundaries so multibyte names are
-- not split mid-codepoint.
local function truncate(s, max)
  if vim.fn.strdisplaywidth(s) <= max then
    return s
  end
  return vim.fn.strcharpart(s, 0, max - 1) .. "…"
end

local function ensure_highlights()
  for i, color in ipairs(PALETTE) do
    vim.api.nvim_set_hl(0, "GitAnnotateAuthor" .. i, { fg = color, default = true })
  end
  vim.api.nvim_set_hl(0, "GitAnnotateDate", { link = "Comment", default = true })
end

-- Deterministically map a commit sha to one of the palette highlight groups.
local function sha_color_group(sha)
  local h = 0
  for i = 1, #sha do
    h = (h + sha:byte(i)) % #PALETTE
  end
  return "GitAnnotateAuthor" .. (h + 1)
end

-- Parse `git blame --line-porcelain` output into commit metadata (keyed by sha)
-- and a per-source-line list of shas.
local function parse_blame(out)
  local commits = {}
  local entries = {}
  local cur
  for _, line in ipairs(out) do
    local sha = line:match("^(%x+) %d+ %d+")
    if sha then
      cur = sha
      commits[cur] = commits[cur] or {}
    elseif line:sub(1, 1) == "\t" then
      entries[#entries + 1] = cur
    else
      local key, val = line:match("^([%w%-]+) (.*)$")
      if key == "author" then
        commits[cur].author = val
      elseif key == "author-time" then
        commits[cur].time = tonumber(val)
      elseif key == "summary" then
        commits[cur].summary = val
      end
    end
  end
  return commits, entries
end

-- Build the text lines, per-line highlight ranges and required column width.
local function render(commits, entries)
  local lines = {}
  local hls = {}
  local width = 0
  for i, sha in ipairs(entries) do
    local c = commits[sha] or {}
    local date, author, group
    if sha == UNCOMMITTED then
      date, author, group = "        ", "Uncommitted", "Comment"
    else
      date = c.time and os.date("%y-%m-%d", c.time) or "--------"
      author = c.author or "?"
      group = sha_color_group(sha)
    end
    author = truncate(author, MAX_AUTHOR_WIDTH)
    local text = date .. " " .. author
    lines[i] = text
    hls[i] = {
      { s = 0, e = #date, hl = "GitAnnotateDate" },
      { s = #date + 1, e = #text, hl = group },
    }
    width = math.max(width, vim.fn.strdisplaywidth(text))
  end
  return lines, hls, width
end

function M.close()
  -- Invalidate any in-flight or already-queued blame callback so it can't
  -- resurrect a panel after we've torn this one down.
  state.gen = state.gen + 1
  if state.augroup then
    vim.api.nvim_del_augroup_by_id(state.augroup)
    state.augroup = nil
  end
  if state.job then
    state.job:kill("sigterm")
    state.job = nil
  end
  stop_spinner()
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    vim.api.nvim_win_close(state.win, true)
  end
  if state.src_win and vim.api.nvim_win_is_valid(state.src_win) then
    vim.wo[state.src_win].scrollbind = false
    vim.wo[state.src_win].cursorbind = false
  end
  state.win, state.buf, state.src_win, state.src_buf = nil, nil, nil, nil
end

-- Build the annotate split from parsed blame output. Runs after the async
-- `git blame` finishes, so it re-checks that the source window still shows the
-- same buffer (the user may have navigated away while blame was running).
local function build_panel(src_win, src_buf, out)
  if not vim.api.nvim_win_is_valid(src_win) or vim.api.nvim_win_get_buf(src_win) ~= src_buf then
    vim.notify("Buffer changed before blame finished; cancelled", vim.log.levels.WARN, { title = "Git Annotate" })
    return
  end

  -- Never stack two panels: tear down any existing one before building.
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    M.close()
  end

  local commits, entries = parse_blame(out)
  ensure_highlights()
  local lines, hls, width = render(commits, entries)

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  vim.api.nvim_set_current_win(src_win)
  vim.cmd("leftabove vsplit")
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  vim.api.nvim_win_set_width(win, math.min(width + 1, 60))

  local wo = vim.wo[win]
  wo.number = false
  wo.relativenumber = false
  wo.signcolumn = "no"
  wo.foldcolumn = "0"
  wo.wrap = false
  wo.list = false
  wo.cursorline = true
  wo.winfixwidth = true

  for i, line_hls in ipairs(hls) do
    for _, h in ipairs(line_hls) do
      vim.api.nvim_buf_set_extmark(buf, ns, i - 1, h.s, { end_col = h.e, hl_group = h.hl })
    end
  end

  vim.wo[src_win].scrollbind = true
  vim.wo[src_win].cursorbind = true
  wo.scrollbind = true
  wo.cursorbind = true

  state.win, state.buf, state.src_win, state.src_buf = win, buf, src_win, src_buf

  vim.keymap.set("n", "q", M.close, { buffer = buf, nowait = true, desc = "Close git annotate" })

  vim.api.nvim_win_set_cursor(win, vim.api.nvim_win_get_cursor(src_win))
  vim.cmd("syncbind")
  vim.api.nvim_set_current_win(src_win)
  vim.cmd("syncbind")

  -- The panel is bound to a specific buffer in src_win. Once that window shows a
  -- different file (`:edit`, a picker, etc.) the blame no longer lines up, so
  -- close rather than leave a misleading gutter. Also close if src_win goes away.
  state.augroup = vim.api.nvim_create_augroup("GitAnnotateAutoClose", { clear = true })
  vim.api.nvim_create_autocmd({ "BufWinEnter", "WinEnter" }, {
    group = state.augroup,
    desc = "Close git annotate when its source window changes file",
    callback = function()
      if not (state.win and vim.api.nvim_win_is_valid(state.win)) then
        return
      end
      if not (state.src_win and vim.api.nvim_win_is_valid(state.src_win)) then
        M.close()
      elseif vim.api.nvim_win_get_buf(state.src_win) ~= state.src_buf then
        M.close()
      end
    end,
  })
end

function M.open()
  local src_win = vim.api.nvim_get_current_win()
  local src_buf = vim.api.nvim_win_get_buf(src_win)
  local file = vim.api.nvim_buf_get_name(src_buf)
  if file == "" then
    vim.notify("No file in current buffer", vim.log.levels.WARN, { title = "Git Annotate" })
    return
  end
  if vim.bo[src_buf].modified then
    vim.notify(
      "Buffer has unsaved changes; blame reflects the file on disk",
      vim.log.levels.WARN,
      { title = "Git Annotate" }
    )
  end

  local dir = vim.fn.fnamemodify(file, ":h")
  -- Bump the generation before launching so a superseded or cancelled blame
  -- can't build a panel after the fact (see the gen check in the callback).
  state.gen = state.gen + 1
  local gen = state.gen
  -- Run blame off the main loop so the editor stays responsive on huge repos; a
  -- spinner float signals work is in progress and the timeout guarantees we
  -- never spin forever. `--porcelain` (not `--line-porcelain`) emits each
  -- commit's details once rather than per line — far less output to transfer
  -- and parse. build_panel runs on the scheduled callback once output is ready.
  start_spinner("Computing git blame…")
  state.job = vim.system(
    { "git", "-C", dir, "blame", "--porcelain", "--", file },
    { text = true, timeout = BLAME_TIMEOUT_MS },
    vim.schedule_wrap(function(res)
      -- Drop output from a blame that was cancelled or superseded by a newer one.
      if gen ~= state.gen then
        return
      end
      state.job = nil
      stop_spinner()
      if res.code ~= 0 then
        local err
        if res.signal and res.signal ~= 0 then
          err = "timed out or cancelled (file too large or git wedged?)"
        else
          err = (res.stderr and res.stderr ~= "") and res.stderr or "unknown error"
        end
        vim.notify("git blame failed: " .. err, vim.log.levels.ERROR, { title = "Git Annotate" })
        return
      end
      build_panel(src_win, src_buf, vim.split(res.stdout or "", "\n"))
    end)
  )
end

function M.toggle()
  if (state.win and vim.api.nvim_win_is_valid(state.win)) or state.job then
    M.close()
  else
    M.open()
  end
end

return M
