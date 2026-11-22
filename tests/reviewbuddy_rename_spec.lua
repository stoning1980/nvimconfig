local root = vim.fn.getcwd()
package.path = root
  .. "/dev/reviewbuddy.nvim/lua/?.lua;"
  .. root
  .. "/dev/reviewbuddy.nvim/lua/?/init.lua;"
  .. package.path

local function assert_file(path)
  assert(vim.uv.fs_stat(root .. "/" .. path), "expected file: " .. path)
end

local function assert_missing(path)
  assert(not vim.uv.fs_stat(root .. "/" .. path), "unexpected legacy path: " .. path)
end

assert_file("dev/reviewbuddy.nvim/lua/reviewbuddy/init.lua")
assert_file("dev/reviewbuddy.nvim/plugin/reviewbuddy.lua")
assert_file("lua/plugins/reviewbuddy.lua")
assert_file("tests/reviewbuddy_spec.lua")
assert_file("tests/reviewbuddy_backends_spec.lua")

assert_missing("dev/herdr.nvim")
assert_missing("lua/plugins/herdr.lua")
assert_missing("tests/herdr_spec.lua")
assert_missing("tests/herdr_backends_spec.lua")

local reviewbuddy = require("reviewbuddy")
assert(type(reviewbuddy.setup) == "function")

local plugin_spec = table.concat(vim.fn.readfile(root .. "/lua/plugins/reviewbuddy.lua"), "\n")
assert(plugin_spec:find('"/dev/reviewbuddy.nvim"', 1, true))
assert(plugin_spec:find('"reviewbuddy.nvim"', 1, true))
assert(plugin_spec:find('require("reviewbuddy").setup(opts)', 1, true))

local init_source = table.concat(vim.fn.readfile(root .. "/dev/reviewbuddy.nvim/lua/reviewbuddy/init.lua"), "\n")
assert(init_source:find('"HerdrComment"', 1, true), "legacy Herdr command aliases must remain")

print("reviewbuddy_rename_spec: all tests passed")
