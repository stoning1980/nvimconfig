-- Switch git branches from a picker, then close the editor session.
--
-- <F5> lists local branches the way the shell `lbr` does: refs/heads, most
-- recently committed first, then `git checkout`. <S-F5> lists remote-tracking
-- branches the way `rbr` does, and checks out the short name (`origin/main`).
-- Symbolic `origin/HEAD` is omitted; `origin/main` is already in the list.
--
-- Each row is the branch, how long ago it was committed, and that commit's
-- subject — the same kind of one-line menu entry F1 uses for recent commits.
-- The picker title, and the message after a checkout, name the current HEAD
-- branch, such as `foo`. A detached checkout at `origin/foo` is shown as `foo`.
--
-- A checkout that does not move HEAD leaves every buffer alone. A checkout
-- that does closes tabs, files, terminals, and the CodeChat session, then
-- shows the dashboard. A saved session for the branch you land on can still
-- be restored from there.

local M = {}

-- Tab-separated so a subject that contains spaces stays one field. Ref names
-- cannot contain tabs.
local REF_FORMAT = "%(refname:short)\t%(committerdate:relative)\t%(subject)"
local NAME_CAP = 40
local WHEN_WIDTH = 16

local function notify(msg, level)
  pcall(vim.notify, msg, level or vim.log.levels.INFO, { title = "Git Branch" })
end

--- Checkout name for one `git branch -r` line, matching `rbr`'s two sed
--- expressions. nil when the line does not name a branch.
---@param line string
---@return string|nil
function M.remote_checkout_name(line)
  if type(line) ~= "string" then
    return nil
  end
  local name = line:gsub(".* remotes/origin/", "", 1)
  name = name:gsub(".* ", "", 1)
  name = vim.trim(name)
  if name == "" then
    return nil
  end
  return name
end

--- One `for-each-ref` line: name, relative commit time, subject.
---@param line string
---@return { branch: string, when: string, subject: string }?
function M.parse_ref_line(line)
  if type(line) ~= "string" then
    return nil
  end
  local name, when, subject = line:match("^([^\t]*)\t([^\t]*)\t(.*)$")
  if not name or vim.trim(name) == "" then
    return nil
  end
  return {
    branch = vim.trim(name),
    when = vim.trim(when or ""),
    subject = vim.trim(subject or ""),
  }
end

--- One picker row. `name_w` pads shorter branch names so the times line up,
--- and is capped so a very long name does not push the message off screen.
---@param entry { branch: string, when: string, subject: string }
---@param current boolean
---@param name_w number
---@return string
function M.format_branch(entry, current, name_w)
  local name = entry.branch
  if #name < name_w then
    name = name .. string.rep(" ", name_w - #name)
  end
  local when = entry.when
  if #when < WHEN_WIDTH then
    when = when .. string.rep(" ", WHEN_WIDTH - #when)
  end
  local text = (current and "* " or "  ") .. name .. "  " .. when
  if entry.subject ~= "" then
    text = text .. "  " .. entry.subject
  end
  return text
end

--- `git status --porcelain=v2 --branch` header. `(detached)` becomes `HEAD`,
--- matching `rev-parse --abbrev-ref HEAD`.
---@param lines string[]
---@return { head: string?, upstream: string? }
function M.parse_branch_status(lines)
  local head, upstream
  for _, line in ipairs(lines or {}) do
    local parsed_head = line:match("^# branch%.head (.+)$")
    if parsed_head then
      head = parsed_head == "(detached)" and "HEAD" or parsed_head
    end
    local parsed_upstream = line:match("^# branch%.upstream (.+)$")
    if parsed_upstream then
      upstream = parsed_upstream
    end
  end
  return { head = head, upstream = upstream }
end

--- A remote ref that points at a detached HEAD. Prefer `origin/` when several
--- remotes contain the same commit. Symbolic `origin/HEAD` is not a branch.
---@param names string[]?
---@return string?
function M.prefer_remote_ref(names)
  local best
  for _, name in ipairs(names or {}) do
    if name ~= "" and name ~= "HEAD" and not name:match("/HEAD$") then
      if name:match("^origin/") then
        return name
      end
      best = best or name
    end
  end
  return best
end

--- One line for the picker title and the checkout message. nil when HEAD is
--- unknown.
---@param info { head: string?, upstream: string?, detached_at: string? }
---@return string?
function M.head_summary(info)
  info = info or {}
  local head = info.head
  if head == "HEAD" then
    local name = info.detached_at
    if name and name ~= "" then
      -- `origin/foo` and `origin/feature/foo` become the branch name.
      return name:match("^[^/]+/(.+)$") or name
    end
    return "detached"
  end
  if not head or head == "" then
    return nil
  end
  if info.upstream and info.upstream ~= "" then
    return head .. " → " .. info.upstream
  end
  return head
end

---@param lines string[]
---@param opts { remote: boolean, head: string?, upstream: string? }
---@return { text: string, branch: string, idx: number }[]
function M.branch_items(lines, opts)
  local parsed = {}
  local seen = {}
  for _, line in ipairs(lines) do
    local entry = M.parse_ref_line(line)
    if entry then
      local name = entry.branch
      if opts.remote then
        if name == "HEAD" or name:match("/HEAD$") then
          name = nil
        else
          name = M.remote_checkout_name(name)
        end
      end
      if name and not seen[name] then
        seen[name] = true
        entry.branch = name
        parsed[#parsed + 1] = entry
      end
    end
  end

  local name_w = 0
  for _, entry in ipairs(parsed) do
    name_w = math.max(name_w, #entry.branch)
  end
  name_w = math.min(name_w, NAME_CAP)

  local items = {}
  for _, entry in ipairs(parsed) do
    local current = entry.branch == opts.head or (opts.upstream ~= nil and entry.branch == opts.upstream)
    items[#items + 1] = {
      text = M.format_branch(entry, current, name_w),
      branch = entry.branch,
      idx = #items + 1,
    }
  end
  return items
end

---@param cwd string
---@param args string[]
---@param cb fun(text: string?)
local function git_text(cwd, args, cb)
  vim.system({ "git", unpack(args) }, { cwd = cwd, text = true }, function(res)
    vim.schedule(function()
      if res.code ~= 0 then
        cb(nil)
        return
      end
      local text = vim.trim(res.stdout or "")
      cb(text ~= "" and text or nil)
    end)
  end)
end

---@param cwd string
---@param args string[]
---@param cb fun(lines: string[]?, err: string?)
local function git_lines(cwd, args, cb)
  vim.system({ "git", unpack(args) }, { cwd = cwd, text = true }, function(res)
    vim.schedule(function()
      if res.code ~= 0 then
        local err = vim.trim((res.stderr or "") ~= "" and res.stderr or (res.stdout or "git failed"))
        cb(nil, err ~= "" and err or "git failed")
        return
      end
      local lines = {}
      for line in (res.stdout or ""):gmatch("[^\r\n]+") do
        lines[#lines + 1] = line
      end
      cb(lines)
    end)
  end)
end

---@param res vim.SystemCompleted
---@return string
local function git_message(res)
  local msg = vim.trim((res.stderr or "") .. "\n" .. (res.stdout or ""))
  if msg == "" then
    return "git checkout failed"
  end
  return msg
end

--- Ask git where HEAD is, then call `cb` with a summary (`main → origin/main`,
--- or `foo` when detached at `origin/foo`) or nil when the status cannot be read.
---@param cwd string
---@param cb fun(summary: string?)
local function describe_head(cwd, cb)
  git_lines(cwd, { "status", "--porcelain=v2", "--branch" }, function(lines)
    if not lines then
      cb(nil)
      return
    end
    local info = M.parse_branch_status(lines)
    if info.head ~= "HEAD" then
      cb(M.head_summary(info))
      return
    end
    git_lines(cwd, {
      "for-each-ref",
      "--points-at",
      "HEAD",
      "--format=%(refname:short)",
      "refs/remotes",
    }, function(refs)
      info.detached_at = M.prefer_remote_ref(refs or {})
      cb(M.head_summary(info))
    end)
  end)
end

--- `where` is the HEAD summary when git can name it, otherwise the branch that
--- was requested.
---@param cwd string
---@param branch string
---@param cb fun(where: string)
local function head_where(cwd, branch, cb)
  describe_head(cwd, function(summary)
    cb(summary or branch)
  end)
end

--- Check out `branch` in `cwd`. On a real switch, close open files, tabs,
--- terminals, and the CodeChat session, then show the dashboard. The result
--- names the HEAD branch. A detached checkout at `origin/foo` is shown as `foo`.
---@param cwd string
---@param branch string
---@param head string?
function M.checkout(cwd, branch, head)
  if head and branch == head then
    head_where(cwd, branch, function(where)
      notify("Already on " .. where)
    end)
    return
  end
  if not require("config.goto").confirm_discard("Switch branch?") then
    return
  end

  -- No "--": that would check out a pathspec instead of a branch. Same command
  -- as the shell helpers (`git checkout <name>`).
  vim.system({ "git", "checkout", branch }, { cwd = cwd, text = true }, function(res)
    vim.schedule(function()
      local msg = git_message(res)
      if res.code ~= 0 then
        notify(msg, vim.log.levels.ERROR)
        return
      end
      -- `git checkout` of the branch already checked out exits 0 and prints
      -- "Already on". That is not a switch, so the open files stay.
      if msg:find("Already on", 1, true) then
        head_where(cwd, branch, function(where)
          notify("Already on " .. where)
        end)
        return
      end
      local wiped, err = require("config.goto").wipe_editor()
      head_where(cwd, branch, function(where)
        if wiped then
          notify("Switched to " .. where)
        else
          local why = (err and err ~= "in progress") and (": " .. err) or ""
          notify("Switched to " .. where .. "; open files are still open" .. why, vim.log.levels.WARN)
        end
      end)
    end)
  end)
end

---@param cwd string
---@param remote boolean
---@param lines string[]
---@param head string?
---@param upstream string?
---@param summary string?
local function open_picker(cwd, remote, lines, head, upstream, summary)
  local items = M.branch_items(lines, { remote = remote, head = head, upstream = upstream })
  if #items == 0 then
    notify(remote and "No remote branches" or "No local branches", vim.log.levels.WARN)
    return
  end

  local function choose(branch)
    if type(branch) ~= "string" or branch == "" then
      return
    end
    -- After the picker closes, so confirm is not nested inside its callback.
    vim.schedule(function()
      M.checkout(cwd, branch, head)
    end)
  end

  local title = remote and "Remote branch" or "Local branch"
  if summary and summary ~= "" then
    title = title .. "  ·  HEAD " .. summary
  end
  if Snacks and Snacks.picker then
    -- Wide list, no preview: the time and subject need the row, the way F1's
    -- menu puts the commit subject on the row itself.
    Snacks.picker.pick({
      source = "git_branch",
      items = items,
      format = "text",
      title = title,
      preview = "none",
      layout = {
        hidden = { "preview" },
        layout = {
          backdrop = false,
          width = 0.9,
          min_width = 90,
          height = 0.6,
          min_height = 10,
          box = "vertical",
          border = true,
          title = "{title}",
          title_pos = "center",
          { win = "input", height = 1, border = "bottom" },
          { win = "list", border = "none" },
        },
      },
      confirm = function(picker, item)
        picker:close()
        if item then
          choose(item.branch)
        end
      end,
    })
    return
  end

  vim.ui.select(items, {
    prompt = title,
    format_item = function(item)
      return item.text
    end,
  }, function(choice)
    if choice then
      choose(choice.branch)
    end
  end)
end

--- Open the branch picker. `opts.remote` selects remote-tracking branches.
---@param opts? { remote?: boolean }
function M.pick(opts)
  local remote = opts and opts.remote or false
  local cwd = vim.fn.getcwd()

  git_text(cwd, { "rev-parse", "--is-inside-work-tree" }, function(inside)
    if inside ~= "true" then
      notify("Not a git repository", vim.log.levels.ERROR)
      return
    end

    local list_args = {
      "for-each-ref",
      "--sort=-committerdate",
      remote and "refs/remotes" or "refs/heads",
      "--format=" .. REF_FORMAT,
    }

    local lines, list_err
    local info = {}
    local pending = 2
    local function open()
      if list_err then
        notify(list_err, vim.log.levels.ERROR)
        return
      end
      local function show(detached_at)
        local summary = M.head_summary({
          head = info.head,
          upstream = info.upstream,
          detached_at = detached_at,
        })
        -- A detached checkout still marks the remote branch it sits on.
        local mark = info.upstream or detached_at
        open_picker(cwd, remote, lines or {}, info.head, mark, summary)
      end
      if info.head == "HEAD" then
        git_lines(cwd, {
          "for-each-ref",
          "--points-at",
          "HEAD",
          "--format=%(refname:short)",
          "refs/remotes",
        }, function(refs)
          show(M.prefer_remote_ref(refs or {}))
        end)
        return
      end
      show(nil)
    end

    local function done()
      pending = pending - 1
      if pending > 0 then
        return
      end
      open()
    end

    git_lines(cwd, list_args, function(result, err)
      lines, list_err = result, err
      done()
    end)
    git_lines(cwd, { "status", "--porcelain=v2", "--branch" }, function(status_lines)
      if status_lines then
        info = M.parse_branch_status(status_lines)
      end
      done()
    end)
  end)
end

function M.setup()
  vim.api.nvim_create_user_command("GitBranch", function()
    M.pick({ remote = false })
  end, { desc = "Switch local git branch and close open files" })

  vim.api.nvim_create_user_command("GitRemoteBranch", function()
    M.pick({ remote = true })
  end, { desc = "Switch remote git branch and close open files" })
end

return M
