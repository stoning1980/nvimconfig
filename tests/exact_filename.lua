-- Run: nvim --headless -u NONE -l tests/exact_filename.lua
-- File search compares the query to the filename as one string.
vim.opt.rtp:prepend(vim.fn.getcwd())
vim.opt.rtp:prepend(vim.fn.expand("~/.local/share/nvim/lazy/snacks.nvim"))

local exact = require("config.exact_filename")

local function assert_eq(actual, expected, label)
  local a = vim.inspect(actual)
  local e = vim.inspect(expected)
  assert(a == e, (label or "") .. " expected " .. e .. " got " .. a)
end

local matcher = require("snacks.picker.core.matcher").new({
  fuzzy = false,
  smartcase = false,
  ignorecase = true,
})

local function matches(path, query)
  matcher:init(exact.pattern(query))
  local item = { text = exact.item_text(path), file = path, idx = 1, score = 0 }
  return matcher:match(item) > 0
end

assert_eq(matches("src/feed/MainActivity.kt", "MainActivity.kt"), true, "filename equals query")
assert_eq(matches("MainActivity.kt", "MainActivity.kt"), true, "basename with no directory")
assert_eq(matches("src/feed/MainActivity.kt", "mainactivity.kt"), true, "lowercase query matches")
assert_eq(matches("src/feed/MainActivity.kt", "Mainactivity.kt"), true, "mixed case still matches")
assert_eq(matches("src/feed/mainactivity.kt", "MainActivity.kt"), true, "uppercase query matches a lowercase name")
assert_eq(matches("src/feed/MainActivity.kt", "MainActivity"), false, "prefix of the filename is not enough")
assert_eq(matches("src/feed/MainActivity.kt", "Activity.kt"), false, "suffix of the filename is not enough")
assert_eq(matches("src/feed/MainActivity.kt", "MAty"), false, "fuzzy characters do not match")
assert_eq(matches("src/feed/MainActivity.kt", "feed"), false, "directory names are not compared")
assert_eq(matches("src/feed/MainActivity.kt", "src/feed/MainActivity.kt"), false, "a path is not the filename")
assert_eq(matches("src/feed/MainActivityTest.kt", "MainActivity.kt"), false, "a longer filename is not equal")
assert_eq(matches("src/My File.kt", "My File.kt"), true, "the whole query is one string, including spaces")
assert_eq(matches("src/My File.kt", "My"), false, "a space does not split the query into tokens")
assert_eq(matches("src/MyOther File.kt", "My File.kt"), false, "spaced query does not match a different name")
assert_eq(exact.pattern(""), "", "empty query stays empty so every file is listed")
assert_eq(exact.pattern(nil), "", "nil query stays empty")
assert_eq(exact.fd_query("agegatemanager.swift"), "^agegatemanager\\.swift$ -- -i", "fd regex escapes the dot")
assert_eq(exact.fd_query("My File.kt"), "^My File\\.kt$ -- -i", "fd regex keeps spaces and escapes the dot")
assert_eq(exact.fd_query("a+b"), "^a\\+b$ -- -i", "fd regex escapes plus")

local ios2 = vim.fs.normalize("/Users/bytedance/work/code/ios2")
local tiktok = vim.fs.normalize("/Users/bytedance/work/code/ios2/TikTok")
assert_eq(exact.search_cwd(ios2, tiktok), ios2, "a non-git parent of the repo is the search directory")
assert_eq(exact.search_cwd(tiktok, tiktok), tiktok, "cwd already at the git root stays there")
assert_eq(
  exact.search_cwd(vim.fs.normalize("/Users/bytedance/work/code"), tiktok),
  tiktok,
  "a higher directory is not the search directory"
)

local filter = { pattern = "agegatemanager.swift", search = "" }
exact.prepare_filter(filter)
assert_eq(filter.search, "^agegatemanager\\.swift$ -- -i", "typed filename is sent to fd")
assert(filter.pattern ~= "agegatemanager.swift", "matcher pattern is sealed")

local picker = {
  closed = false,
  input = { filter = { pattern = "agegatemanager.swift", search = "" } },
  finds = 0,
  seen = "",
}
function picker:find()
  self.finds = self.finds + 1
  self.seen = self.input.filter.search
end
exact.hold_fd(picker, { pattern = "a.swift", search = "" })
exact.hold_fd(picker, { pattern = "agegatemanager.swift", search = "" })
assert_eq(picker.finds, 0, "typing does not start fd")
assert(
  vim.wait(800, function()
    return picker.finds == 1
  end),
  "fd did not run after typing paused"
)
assert_eq(picker.finds, 1, "only the last pause starts fd")
assert_eq(picker.seen, exact.fd_query("agegatemanager.swift"), "fd receives the finished filename")

print("ok")
