local root = vim.fn.getcwd()

local function assert_missing(path)
  assert(not vim.uv.fs_stat(root .. "/" .. path), "unexpected removed plugin path: " .. path)
end

for _, path in ipairs({
  "dev/claudeide.nvim",
  "dev/codechat.nvim",
  "lua/plugins/claudeide.lua",
  "lua/plugins/codechat.lua",
  ".cursor/rules/claudeide.mdc",
  ".cursor/rules/codechat.mdc",
}) do
  assert_missing(path)
end

local patterns = {
  "claudeide",
  "ClaudeIde",
  "Claude IDE",
  "codechat",
  "CodeChat",
}
for _, path in ipairs(vim.fn.systemlist({ "git", "ls-files" })) do
  if path:match("%.lua$") or path:match("%.md$") or path:match("%.mdc$") or path == ".cursorrules" then
    local source = table.concat(vim.fn.readfile(root .. "/" .. path), "\n")
    for _, pattern in ipairs(patterns) do
      assert(not source:find(pattern, 1, true), path .. " still contains " .. pattern)
    end
  end
end

local keymaps = table.concat(vim.fn.readfile(root .. "/lua/config/keymaps.lua"), "\n")
assert(keymaps:find("F9      : Not mapped.", 1, true))
assert(keymaps:find("S-F9    : Not mapped.", 1, true))

package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path
dofile(root .. "/lua/config/keymaps.lua")
for _, key in ipairs({ "<F9>", "<S-F9>", "<F21>" }) do
  for _, mode in ipairs({ "n", "v", "x", "t" }) do
    assert(vim.fn.maparg(key, mode) == "", key .. " is still mapped in " .. mode .. " mode")
  end
end

print("removed_ai_plugins_spec: all tests passed")
