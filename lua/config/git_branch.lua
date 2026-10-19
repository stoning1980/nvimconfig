-- Switch git branches from a picker, then close the editor session.
--
-- <F5> lists local branches the way the shell `lbr` does: refs/heads, most
-- recently committed first, then `git checkout`. <S-F5> lists remote-tracking
-- branches the way `rbr` does, and checks out the short name (`origin/main`).
-- Symbolic `origin/HEAD` is omitted; `origin/main` is already in the list.
--
-- Each row is the branch, how long ago it was committed, and that commit's
-- subject — the same kind of one-line menu entry F1 uses for recent commits.
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

--- Check out `branch` in `cwd`. On a real switch, close open files, tabs,
--- terminals, and the CodeChat session, then show the dashboard.
---@param cwd string
---@param branch string
---@param head string?
function M.checkout(cwd, branch, head)
  if head and branch == head then
    notify("Already on " .. branch)
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
        notify("Already on " .. branch)
        return
      end
      local wiped, err = require("config.goto").wipe_editor()
      if wiped then
        notify("Switched to " .. branch)
      else
        local why = (err and err ~= "in progress") and (": " .. err) or ""
        notify("Switched to " .. branch .. "; open files are still open" .. why, vim.log.levels.WARN)
      end
    end)
  end)
end

---@param cwd string
---@param remote boolean
---@param lines string[]
---@param head string?
---@param upstream string?
local function open_picker(cwd, remote, lines, head, upstream)
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

    local lines, list_err, head, upstream
    local pending = remote and 3 or 2
    local function done()
      pending = pending - 1
      if pending > 0 then
        return
      end
      if list_err then
        notify(list_err, vim.log.levels.ERROR)
        return
      end
      open_picker(cwd, remote, lines or {}, head, upstream)
    end

    git_lines(cwd, list_args, function(result, err)
      lines, list_err = result, err
      done()
    end)
    git_text(cwd, { "rev-parse", "--abbrev-ref", "HEAD" }, function(text)
      head = text
      done()
    end)
    if remote then
      git_text(cwd, { "rev-parse", "--abbrev-ref", "@{upstream}" }, function(text)
        upstream = text
        done()
      end)
    end
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
