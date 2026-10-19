-- Diffview's Git bootstrap uses Job:sync(), which can time out during an F1
-- picker callback. It also sets done=true before the job completes, so a
-- transient timeout leaves Git disabled for the rest of the session.
-- Use Neovim's native process API for this one probe and cache only success.
local M = {}

function M.setup()
  local GitAdapter = require("diffview.vcs.adapters.git").GitAdapter

  GitAdapter.run_bootstrap = function()
    local bs = GitAdapter.bootstrap
    bs.done, bs.ok, bs.err = false, false, nil
    bs.version, bs.version_string = {}, nil

    local function fail(message)
      bs.err = message
      DiffviewGlobal.logger:error("[GitAdapter] " .. message)
      vim.notify(message, vim.log.levels.ERROR, { title = "Diffview" })
    end

    local cmd = vim.deepcopy(require("diffview.config").get_config().git_cmd)
    cmd[#cmd + 1] = "version"
    local ok, result = pcall(function()
      return vim.system(cmd, { text = true }):wait(5000)
    end)
    if not ok then
      return fail("Could not start Git: " .. tostring(result))
    end
    if result.code ~= 0 then
      local detail = result.code == 124 and "timed out after 5 seconds"
        or vim.trim(result.stderr or "")
      if detail == "" then
        detail = "exit code " .. tostring(result.code)
      end
      return fail("Git version check failed (" .. detail .. "). Try opening Diffview again.")
    end

    bs.version_string = (result.stdout or ""):match("git version (%S+)")
    local major, minor, patch = (bs.version_string or ""):match("^(%d+)%.(%d+)%.(%d+)")
    if not major then
      return fail("Could not parse Git version: " .. vim.trim(result.stdout or ""))
    end
    bs.version = { major = tonumber(major), minor = tonumber(minor), patch = tonumber(patch) }
    local target = bs.target_version
    bs.target_version_string = ("%d.%d.%d"):format(target.major, target.minor, target.patch)
    if not require("diffview.vcs.utils").check_semver(bs.version, target) then
      return fail(("Git %s is too old; Diffview requires %s."):format(bs.version_string, bs.target_version_string))
    end
    bs.done, bs.ok = true, true
  end

  -- Also recover when this module is loaded into a session that already failed.
  if not GitAdapter.bootstrap.ok then
    GitAdapter.bootstrap.done = false
  end
end

return M
