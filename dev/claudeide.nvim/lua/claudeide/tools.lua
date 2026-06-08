-- MCP tool registry and MVP tool implementations.

local diff = require("claudeide.diff")

local M = {}

local registry = {}

--- Register a tool.
---@param name string
---@param def { description: string, inputSchema: table, handler: fun(args: table, respond: fun(result: table)): table|nil }
function M.register(name, def)
  registry[name] = def
end

function M.exists(name)
  return registry[name] ~= nil
end

--- List tools for the MCP `tools/list` response.
---@return table[]
function M.list()
  local list = {}
  for name, def in pairs(registry) do
    list[#list + 1] = {
      name = name,
      description = def.description,
      inputSchema = def.inputSchema,
    }
  end
  return list
end

--- Call a tool. Returns a result for synchronous tools, or nil if the tool
--- will respond asynchronously via `respond`.
---@param name string
---@param args table
---@param respond fun(result: table)
---@return table|nil
function M.call(name, args, respond)
  return registry[name].handler(args, respond)
end

local function text_result(text)
  return { content = { { type = "text", text = text } } }
end

-- openFile: open a file, optionally selecting a text range.
M.register("openFile", {
  description = "Open a file in the editor and optionally select a range of text",
  inputSchema = {
    type = "object",
    properties = {
      filePath = { type = "string", description = "Path to the file to open" },
      preview = { type = "boolean", description = "Open in preview mode" },
      startText = { type = "string", description = "Text pattern marking selection start" },
      endText = { type = "string", description = "Text pattern marking selection end" },
      makeFrontmost = { type = "boolean", description = "Make the file the active editor" },
    },
    required = { "filePath" },
  },
  handler = function(args)
    local path = args.filePath
    if not path or path == "" then
      return text_result("Error: filePath is required")
    end
    vim.cmd("edit " .. vim.fn.fnameescape(path))

    if args.startText and args.startText ~= "" then
      local start_line = vim.fn.search(vim.fn.escape(args.startText, "\\/.*$^~[]"), "w")
      if start_line > 0 then
        vim.api.nvim_win_set_cursor(0, { start_line, 0 })
        vim.cmd("normal! zz")
        if args.endText and args.endText ~= "" then
          local end_line = vim.fn.search(vim.fn.escape(args.endText, "\\/.*$^~[]"), "W")
          if end_line > 0 then
            vim.cmd("normal! V")
            vim.api.nvim_win_set_cursor(0, { end_line, 0 })
          end
        end
      end
    end

    return text_result("Opened file: " .. path)
  end,
})

-- openDiff: blocking diff that resolves on accept/deny.
M.register("openDiff", {
  description = "Open a diff view for proposed file changes (blocking until accepted or rejected)",
  inputSchema = {
    type = "object",
    properties = {
      old_file_path = { type = "string", description = "Path to the original file" },
      new_file_path = { type = "string", description = "Path to the new file" },
      new_file_contents = { type = "string", description = "Proposed file contents" },
      tab_name = { type = "string", description = "Name for the diff tab" },
    },
    required = { "old_file_path", "new_file_contents" },
  },
  handler = function(args, respond)
    diff.open(args, respond)
    return nil -- responds asynchronously
  end,
})

return M
