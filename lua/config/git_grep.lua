-- :GitGrep — live grep restricted to git-tracked files, backed by `git grep`.
--
--   :GitGrep            open the picker with an empty prompt
--   :GitGrep <text>     open it seeded with <text> (matched literally)
--   :GitGrep! <re>      match <re> as a POSIX extended regex instead
--
-- Type ` -- <pathspec>` after the pattern to scope the search, e.g.
-- `onCreate -- *.kt *.java`, or to exclude noisy trees: `onCreate -- :!Vendors/*`.
-- No shell quoting is needed — git is spawned directly, not through a shell.
--
-- Why a separate picker instead of Snacks' rg-based grep: it is not the search
-- algorithm, it is which binary opens the files. Microsoft Defender's endpoint
-- security extension scans every open() from binaries it does not trust, and
-- Homebrew's rg is only ad-hoc signed while this git is corporate-signed
-- ("com.tiktok.git"). Given the identical 203k-file list and identical xargs
-- parallelism, that costs 304s for rg versus 8s for git grep and 7.9s for
-- Apple-signed /usr/bin/grep. It is not the file set (rg fed `git ls-files` is
-- still 194s), not mmap (--no-mmap is 191s) and not traversal (`rg --files` is
-- 1.5s). If rg ever gets allowlisted, plain `<leader>/` becomes fast again and
-- this picker loses its reason to exist.
--
-- Two trade-offs come with it:
--   * Untracked-but-not-ignored files are invisible here (rg would search them).
--     Pass `untracked = true` to include them.
--   * This git build has no PCRE (`git grep -P` fails), so regex mode is plain
--     POSIX ERE: `\w`, `\d` and `\b` are not supported. Hence the literal
--     default, which also matches what `<leader>/` and <F7> do in visual mode.
local M = {}

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = "GitGrep" })
end

-- Absolute path of the repo owning the current buffer (falling back to nvim's
-- cwd for unnamed/special buffers), or nil when there is no repo. Asking git
-- rather than looking for a `.git` entry keeps this correct inside linked
-- worktrees and submodules, where `.git` is a file or lives elsewhere.
local function repo_root()
  local dir = vim.fn.expand("%:p:h")
  if dir == "" or vim.bo.buftype ~= "" then
    dir = vim.uv.cwd()
  end
  local out = vim.fn.systemlist({ "git", "-C", dir, "rev-parse", "--show-toplevel" })
  if vim.v.shell_error ~= 0 then
    return nil
  end
  local root = vim.trim(out[1] or "")
  return root ~= "" and root or nil
end

-- Worker threads for `git grep`. This search is bound by per-file open()
-- latency rather than CPU, so oversubscribing the cores hides that latency:
-- on the 203k-file monorepo, 14 threads (git's default = core count) takes
-- 7.9s while 28 takes 5.9s, flattening out past ~42 and degrading past ~80.
-- Small repos are unaffected (16ms vs 22ms for five runs of this config's repo).
local function thread_count()
  local cpus = #(vim.uv.cpu_info() or {})
  return math.max(8, math.min(32, (cpus > 0 and cpus or 8) * 2))
end

-- Split a query into its pattern and an optional trailing git pathspec, using
-- ` -- ` as the separator (the same spelling git itself uses).
local function split_query(query)
  local pattern, rest = query:match("^(.-)%s+%-%-%s+(.+)$")
  if not pattern then
    return query, {}
  end
  return vim.trim(pattern), vim.split(vim.trim(rest), "%s+", { trimempty = true })
end

---@param opts table picker opts (`regex`, `untracked`, `exclude`, `threads`, `args`)
---@param query string the live search string
---@return string[] args, string pattern
local function build_args(opts, query)
  local pattern, pathspec = split_query(query)
  local args = {
    -- Live search respawns git on every keystroke; don't let those runs contend
    -- for .git/index.lock with git commands running elsewhere. (The env-var
    -- spelling, GIT_OPTIONAL_LOCKS=0, is unusable here: libuv's `env` replaces
    -- the whole environment rather than extending it.)
    "--no-optional-locks",
    "grep",
    "--threads=" .. (opts.threads or thread_count()),
    "--no-color",
    "--line-number",
    "--column",
    -- NUL-separate the fields so paths containing ':' or spaces stay parseable.
    "--null",
    -- Skip binary files, and don't run .gitattributes textconv filters on them.
    "-I",
    "--no-textconv",
    -- Report paths from the repo root even though we already spawn git there.
    "--full-name",
    opts.regex and "--extended-regexp" or "--fixed-strings",
  }
  -- Smart case, like rg's --smart-case: case-insensitive until the pattern
  -- itself contains an uppercase letter.
  if not pattern:find("%u") then
    args[#args + 1] = "--ignore-case"
  end
  if opts.untracked then
    args[#args + 1] = "--untracked"
  end
  vim.list_extend(args, opts.args or {})
  -- `-e` guards patterns that start with '-'; a bare `--` with no pathspec is
  -- valid and simply means "no path restriction".
  args[#args + 1] = "-e"
  args[#args + 1] = pattern
  args[#args + 1] = "--"
  vim.list_extend(args, pathspec)
  -- Skipping vendored trees is the other big lever: dropping `Vendors/` (69k of
  -- the monorepo's 203k files) takes a search from 6.8s to 4.0s. Exclude-only
  -- pathspecs are valid on their own — git then means "everything but these".
  for _, pat in ipairs(opts.exclude or {}) do
    args[#args + 1] = ":!" .. pat
  end
  return args, pattern
end

-- Split one output record into its four NUL-separated fields. Done with plain
-- (non-pattern) finds because embedded NULs are awkward to match portably.
local function split_record(text)
  local a = text:find("\0", 1, true)
  local b = a and text:find("\0", a + 1, true)
  local c = b and text:find("\0", b + 1, true)
  if not c then
    return nil
  end
  return text:sub(1, a - 1), tonumber(text:sub(a + 1, b - 1)), tonumber(text:sub(b + 1, c - 1)), text:sub(c + 1)
end

---@param root string repo root, used as both cwd and the items' base directory
local function make_finder(root)
  ---@type snacks.picker.finder
  return function(opts, ctx)
    local query = ctx.filter.search
    if query == "" then
      return function() end
    end
    local args, pattern = build_args(opts, query)
    if pattern == "" then
      return function() end
    end
    -- Length of the run to highlight in the list. `git grep` reports only the
    -- start column (unlike rg's --replace trick for marking every match), so we
    -- can only know the extent for literal searches.
    local hl_len = not opts.regex and #pattern or nil

    return require("snacks.picker.source.proc").proc({
      cmd = "git",
      args = args,
      cwd = root,
      -- `git grep` exits 1 when nothing matched, which is not an error here.
      notify = false,
      transform = function(item)
        local file, line, col, text = split_record(item.text)
        if not file then
          return false
        end
        item.cwd = root
        item.file = file
        item.pos = { line, col - 1 }
        item.line = text
        -- What the picker's own matcher sees, mirroring Snacks' grep source.
        item.text = ("%s:%d:%d:%s"):format(file, line, col, text)
        if hl_len then
          item.end_pos = { line, col - 1 + hl_len }
          local positions = {}
          for i = col, col + hl_len - 1 do
            positions[#positions + 1] = i
          end
          item.positions = positions
        end
      end,
    }, ctx)
  end
end

-- Open the picker. `opts.regex` selects ERE over literal matching,
-- `opts.untracked` widens the search to untracked (but not ignored) files, and
-- `opts.exclude` is a list of pathspecs to skip, e.g. `{ "Vendors/*" }` — set it
-- per project to keep vendored code out of every search.
function M.open(opts)
  opts = opts or {}
  if not (Snacks and Snacks.picker) then
    notify("Snacks picker not available", vim.log.levels.ERROR)
    return
  end
  local root = repo_root()
  if not root then
    notify("Not a git repo", vim.log.levels.ERROR)
    return
  end

  return Snacks.picker.pick(vim.tbl_deep_extend("force", {
    source = "git_grep",
    title = ("Git Grep (%s)"):format(opts.regex and "regex" or "literal"),
    finder = make_finder(root),
    format = "file",
    -- Re-run git grep as the prompt changes; the previous process is killed.
    live = true,
    supports_live = true,
    show_empty = true,
    cwd = root,
    regex = false,
    untracked = false,
    exclude = {},
  }, opts))
end

function M.setup()
  vim.api.nvim_create_user_command("GitGrep", function(cmd)
    M.open({ search = cmd.args, regex = cmd.bang })
  end, {
    nargs = "*",
    bang = true,
    desc = "Grep git-tracked files (! = extended regex instead of literal)",
  })
end

return M
