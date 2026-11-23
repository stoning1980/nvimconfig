local root = vim.fn.getcwd()
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

dofile(root .. "/lua/config/keymaps.lua")

for key = 13, 17 do
  assert(vim.fn.maparg("<F" .. key .. ">", "n") == "", "config keymaps must release F" .. key .. " for AdbHelper")
end

local expected_shifted = {
  ["<S-F1>"] = "Toggle Diffview File Panel",
  ["<S-F2>"] = "Open diff in Beyond Compare",
  ["<S-F3>"] = "Next File (Diffview)",
  ["<S-F4>"] = "Toggle Git Annotate Panel",
  ["<S-F5>"] = "Switch remote git branch",
}
for key, description in pairs(expected_shifted) do
  local mapping = vim.fn.maparg(key, "n", false, true)
  assert(not vim.tbl_isempty(mapping), key .. " must retain its original mapping")
  assert(mapping.desc == description, key .. " changed behavior: " .. vim.inspect(mapping))
end
for key = 6, 7 do
  assert(vim.fn.maparg("<S-F" .. key .. ">", "n") == "", "Shift+F" .. key .. " must remain unmapped")
end

assert(vim.fn.exists(":DiffviewNextFile") == 0, "temporary command-only replacement should be removed")
assert(vim.fn.exists(":GitAnnotateToggle") == 0, "temporary command-only replacement should be removed")

print("android_function_keys_spec: ok")
