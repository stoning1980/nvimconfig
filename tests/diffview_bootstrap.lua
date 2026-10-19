-- Run: nvim --headless -u NONE -l tests/diffview_bootstrap.lua
vim.opt.rtp:prepend(vim.fn.getcwd())
vim.opt.rtp:append(vim.fn.stdpath("data") .. "/lazy/diffview.nvim")
require("diffview").setup({ git_cmd = { "git", "--no-pager" } })

local adapter = require("diffview.vcs.adapters.git").GitAdapter
local native_system = vim.system
local notifications = {}
vim.notify = function(message)
  notifications[#notifications + 1] = message
end

-- Loading the workaround must recover an already-poisoned session.
adapter.bootstrap.done, adapter.bootstrap.ok = true, false
require("config.diffview_bootstrap").setup()
assert(not adapter.bootstrap.done)

local function probe(result)
  vim.system = function(cmd, opts)
    assert(vim.deep_equal(cmd, { "git", "--no-pager", "version" }))
    assert(opts.text)
    return {
      wait = function(_, timeout)
        assert(timeout == 5000)
        return result
      end,
    }
  end
  adapter.run_bootstrap()
end

-- Timeouts and other failures must allow a subsequent attempt.
for _, result in ipairs({
  { code = 124, stdout = "", stderr = "" },
  { code = 1, stdout = "", stderr = "Git failed" },
  { code = 0, stdout = "unexpected output", stderr = "" },
  { code = 0, stdout = "git version 2.20.0\n", stderr = "" },
}) do
  probe(result)
  assert(not adapter.bootstrap.done and not adapter.bootstrap.ok)
  assert(adapter.bootstrap.err and #notifications > 0)
  probe({ code = 0, stdout = "git version 2.54.0 (Apple Git-157)\n", stderr = "" })
  assert(adapter.bootstrap.done and adapter.bootstrap.ok and not adapter.bootstrap.err)
end

vim.system = function()
  error("ENOENT")
end
adapter.run_bootstrap()
assert(not adapter.bootstrap.done and not adapter.bootstrap.ok)
assert(adapter.bootstrap.err:find("ENOENT"))

-- A real native Git probe recovers from the last failure, and retains flags.
vim.system = native_system
adapter.run_bootstrap()
assert(adapter.bootstrap.done and adapter.bootstrap.ok, adapter.bootstrap.err)
assert(vim.deep_equal(require("diffview.config").get_config().git_cmd, { "git", "--no-pager" }))
print("PASS: Diffview Git bootstrap failures, retries, version checks, and native Git")
