local root = vim.fn.getcwd()
package.path = root
  .. "/dev/reviewbuddy.nvim/lua/?.lua;"
  .. root
  .. "/dev/reviewbuddy.nvim/lua/?/init.lua;"
  .. package.path

local backends = require("reviewbuddy.backends")
local cmux = require("reviewbuddy.cmux")
local queue = require("reviewbuddy.queue")
local submit = require("reviewbuddy.submit")
local targets = require("reviewbuddy.targets")

local function assert_equal(actual, expected, message)
  if actual ~= expected then
    error((message or "values differ") .. ": expected " .. vim.inspect(expected) .. ", got " .. vim.inspect(actual))
  end
end

local function adapters_by_id()
  local result = {}
  for _, adapter in ipairs(backends.list()) do
    result[adapter.id] = adapter
  end
  return result
end

local function with_adapter_stubs(stubs, callback)
  local originals = {}
  local adapters = adapters_by_id()
  for id, methods in pairs(stubs) do
    originals[id] = {}
    for name, replacement in pairs(methods) do
      originals[id][name] = adapters[id][name]
      adapters[id][name] = replacement
    end
  end
  local ok, err = pcall(callback, adapters)
  for id, methods in pairs(originals) do
    for name, original in pairs(methods) do
      adapters[id][name] = original
    end
  end
  if not ok then
    error(err)
  end
end

local function test_builtin_adapters_implement_unique_contract()
  local required = {
    "id",
    "target_ids",
    "detect",
    "discover",
    "revalidate",
    "send_queue",
    "label",
    "host_error",
  }
  local seen_targets = {}
  for _, adapter in ipairs(backends.list()) do
    for _, field in ipairs(required) do
      assert(adapter[field] ~= nil, adapter.id .. " is missing " .. field)
    end
    for _, target_id in ipairs(adapter.target_ids) do
      assert(not seen_targets[target_id], "duplicate target backend: " .. target_id)
      seen_targets[target_id] = adapter.id
    end
  end
  assert_equal(seen_targets.herdr, "herdr")
  assert_equal(seen_targets.herdr_app, "herdr_app")
  assert_equal(seen_targets.cmux, "cmux")
  assert_equal(seen_targets.cmux_terminal, "cmux")
end

test_builtin_adapters_implement_unique_contract()

local function test_detects_hosts_in_existing_precedence_order()
  with_adapter_stubs({
    herdr = {
      detect = function()
        return true
      end,
    },
    herdr_app = {
      detect = function()
        return true
      end,
    },
    cmux = {
      detect = function()
        return true
      end,
    },
  }, function()
    assert_equal(backends.active().id, "herdr")
  end)
end

test_detects_hosts_in_existing_precedence_order()

local function test_discover_reports_no_supported_host()
  with_adapter_stubs({
    herdr = {
      detect = function()
        return false
      end,
    },
    herdr_app = {
      detect = function()
        return false
      end,
    },
    cmux = {
      detect = function()
        return false
      end,
    },
  }, function()
    local result, discovery_error
    backends.discover("/work/app", function(targets, err)
      result, discovery_error = targets, err
    end)
    assert_equal(result, nil)
    assert_equal(discovery_error, "Neovim is not running inside Herdr, Herdr app, or cmux")
  end)
end

test_discover_reports_no_supported_host()

local function test_revalidate_rejects_target_owned_by_another_host()
  local delegated
  with_adapter_stubs({
    herdr = {
      detect = function()
        return false
      end,
      revalidate = function()
        delegated = true
      end,
    },
    herdr_app = {
      detect = function()
        return true
      end,
    },
    cmux = {
      detect = function()
        return false
      end,
    },
  }, function()
    local current, revalidation_error
    backends.revalidate("/work/app", { backend = "herdr" }, function(target, err)
      current, revalidation_error = target, err
    end)
    assert_equal(delegated, nil)
    assert_equal(current, nil)
    assert_equal(revalidation_error, "Neovim is no longer running inside Herdr")
  end)
end

test_revalidate_rejects_target_owned_by_another_host()

local function test_dispatches_every_target_kind_to_its_owner()
  local cases = {
    { backend = "herdr", owner = "herdr" },
    { backend = "herdr_app", owner = "herdr_app" },
    { backend = "cmux", owner = "cmux" },
    { backend = "cmux_terminal", owner = "cmux" },
  }
  local stubs = {}
  for _, id in ipairs({ "herdr", "herdr_app", "cmux" }) do
    stubs[id] = {
      label = function(target)
        return id .. ":" .. target.backend
      end,
      send_queue = function(target, _, callback)
        callback(true, id .. ":" .. target.backend)
      end,
    }
  end
  with_adapter_stubs(stubs, function()
    for _, case in ipairs(cases) do
      local target = { backend = case.backend }
      assert_equal(backends.label(target), case.owner .. ":" .. case.backend)
      local ok_result, owner_result
      backends.send_queue(target, {}, function(ok, owner)
        ok_result, owner_result = ok, owner
      end)
      assert_equal(ok_result, true)
      assert_equal(owner_result, case.owner .. ":" .. case.backend)
    end
  end)
end

test_dispatches_every_target_kind_to_its_owner()

local function test_unknown_target_backend_fails_closed()
  local ok_result, error_result
  backends.send_queue({ backend = "unknown" }, {}, function(ok, err)
    ok_result, error_result = ok, err
  end)
  assert_equal(ok_result, false)
  assert_equal(error_result, "unknown review target backend: unknown")
end

test_unknown_target_backend_fails_closed()

local function test_targets_facade_delegates_to_backend_registry()
  local original_discover = backends.discover
  local original_revalidate = backends.revalidate
  local original_label = backends.label
  local calls = {}
  backends.discover = function(repo_root, callback)
    calls.discover = repo_root
    callback({ { backend = "test" } }, nil)
  end
  backends.revalidate = function(repo_root, target, callback)
    calls.revalidate = { repo_root = repo_root, target = target }
    callback(target, nil)
  end
  backends.label = function(target)
    calls.label = target
    return "[test]"
  end

  local discovered
  targets.discover("/work/app", function(result)
    discovered = result
  end)
  local revalidated
  targets.revalidate("/work/app", discovered[1], function(result)
    revalidated = result
  end)
  local label = targets.label(revalidated)

  backends.discover = original_discover
  backends.revalidate = original_revalidate
  backends.label = original_label
  assert_equal(calls.discover, "/work/app")
  assert_equal(calls.revalidate.repo_root, "/work/app")
  assert_equal(calls.label.backend, "test")
  assert_equal(label, "[test]")
end

test_targets_facade_delegates_to_backend_registry()

local function test_submit_dispatches_through_backend_registry()
  local root_path = "/work/registry-submit"
  local original_send = backends.send_queue
  local original_revalidate = targets.revalidate
  local dispatched
  queue.clear(root_path)
  queue.add({
    repo_root = root_path,
    path = "lua/example.lua",
    start_line = 1,
    text = "run()",
  }, "Review this.")
  targets.revalidate = function(_, target, callback)
    callback(target, nil)
  end
  backends.send_queue = function(target, _, callback)
    dispatched = target
    callback(true, nil)
  end

  local result
  submit.send(root_path, { backend = "test" }, function(ok, err)
    result = { ok = ok, err = err }
  end)

  backends.send_queue = original_send
  targets.revalidate = original_revalidate
  assert_equal(result.ok, true)
  assert_equal(result.err, nil)
  assert_equal(dispatched.backend, "test")
  assert_equal(queue.count(root_path), 0)
end

test_submit_dispatches_through_backend_registry()

local function test_cmux_adapter_revalidates_continuations_through_registry()
  local original_cmux_send = cmux.send_queue
  local original_revalidate = backends.revalidate
  local repo_seen, target_seen
  cmux.send_queue = function(target, _, callback, revalidate)
    assert_equal(type(revalidate), "function")
    revalidate(target, function(current, err)
      callback(current ~= nil, err)
    end)
  end
  backends.revalidate = function(repo_root, target, callback)
    repo_seen, target_seen = repo_root, target
    callback(target, nil)
  end

  local ok_result, error_result
  adapters_by_id().cmux.send_queue({
    backend = "cmux",
    id = "surface-agent",
    repo_root = "/work/app",
  }, {}, function(ok, err)
    ok_result, error_result = ok, err
  end)

  cmux.send_queue = original_cmux_send
  backends.revalidate = original_revalidate
  assert_equal(ok_result, true)
  assert_equal(error_result, nil)
  assert_equal(repo_seen, "/work/app")
  assert_equal(target_seen.id, "surface-agent")
end

test_cmux_adapter_revalidates_continuations_through_registry()

print("reviewbuddy_backends_spec: all tests passed")
