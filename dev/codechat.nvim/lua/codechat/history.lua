-- Global, on-disk record of messages sent to agents. A message is appended
-- every time the user submits or sends from the comment box, so a draft is
-- never lost when a send fails to land (TUI not ready, wrong window, etc.) --
-- it can be read back from the history panel and reused.

local util = require("codechat.util")

local M = {}

-- One shared file across all projects, under Neovim's data dir.
local DIR = vim.fn.stdpath("data") .. "/codechat"
local FILE = DIR .. "/history.json"

-- Keep the file bounded; older entries past this count are dropped on write.
local MAX_ENTRIES = 200

--- Read the whole history (oldest-first, as stored). Missing/corrupt file -> {}.
---@return table[] list of { time, agent, text }
local function read_all()
  local f = io.open(FILE, "r")
  if not f then
    return {}
  end
  local raw = f:read("*a")
  f:close()
  if not raw or raw == "" then
    return {}
  end
  local ok, decoded = pcall(vim.json.decode, raw)
  if not ok or type(decoded) ~= "table" then
    util.warn("history file is corrupt; starting fresh")
    return {}
  end
  return decoded
end

local function write_all(entries)
  vim.fn.mkdir(DIR, "p")
  local f = io.open(FILE, "w")
  if not f then
    util.error("could not write history file: " .. FILE)
    return
  end
  f:write(vim.json.encode(entries))
  f:close()
end

--- Append a message to history. Blank text is ignored (nothing worth saving).
---@param agent string agent name the message was addressed to
---@param text string the message body as it would be sent
function M.append(agent, text)
  if type(text) ~= "string" or vim.trim(text) == "" then
    return
  end
  local entries = read_all()
  entries[#entries + 1] = { time = os.time(), agent = agent, text = text }
  -- Trim from the front so only the newest MAX_ENTRIES survive.
  while #entries > MAX_ENTRIES do
    table.remove(entries, 1)
  end
  write_all(entries)
end

--- Most recent entries, newest-first.
---@param n integer|nil how many to return (default 10)
---@return table[] list of { time, agent, text }
function M.recent(n)
  n = n or 10
  local entries = read_all()
  local out = {}
  for i = #entries, math.max(1, #entries - n + 1), -1 do
    out[#out + 1] = entries[i]
  end
  return out
end

--- Absolute path of the history file (for user reference / commands).
---@return string
function M.path()
  return FILE
end

return M
