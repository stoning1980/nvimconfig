-- Run: nvim --headless -u NONE -l tests/f1_commit_range.lua
-- A recent commit selected from F1 is the base for a comparison with HEAD.

local mappings = {}
vim.keymap.set = function(_, lhs, rhs)
  mappings[lhs] = rhs
end

local picker_opts
Snacks = {
  picker = {
    format = {
      ui_select = function()
        return function() end
      end,
    },
    pick = function(opts)
      picker_opts = opts
    end,
  },
}

package.preload["diffview.lib"] = function()
  return {
    get_current_view = function()
      return nil
    end,
  }
end

package.preload["config.git_diff"] = function()
  return {
    arm_hidden_filter = function() end,
    disarm_hidden_filter = function() end,
    get_picker_bases_async = function(cb)
      cb({}, { "1c13c2d older commit" })
    end,
    setup = function() end,
  }
end

for _, name in ipairs({
  "config.ui_select",
  "config.diffview_follow",
  "config.goto",
  "config.git_branch",
  "config.git_grep",
  "config.beyond_compare",
}) do
  package.preload[name] = function()
    return { setup = function() end }
  end
end

local opened_range
vim.api.nvim_create_user_command("DiffviewOpen", function(opts)
  opened_range = opts.args
end, { nargs = "*" })

dofile(vim.fn.getcwd() .. "/lua/config/keymaps.lua")

assert(type(mappings["<F1>"]) == "function", "F1 mapping was not registered")
mappings["<F1>"]()
assert(picker_opts, "F1 did not open its base picker")

local items = {}
local iterator = picker_opts.finder(nil, {
  async = {
    resume = function() end,
    suspend = function() end,
  },
})
iterator(function(item)
  items[#items + 1] = item
end)

local commit
for _, item in ipairs(items) do
  if item.item == "1c13c2d older commit" then
    commit = item
    break
  end
end
assert(commit, "recent commit was not listed")

picker_opts.confirm({ close = function() end }, commit)
vim.wait(1000, function()
  return opened_range ~= nil
end)

assert(opened_range == "1c13c2d..HEAD", "expected commit..HEAD, got " .. vim.inspect(opened_range))
print("PASS: F1 compares a selected commit to HEAD")
