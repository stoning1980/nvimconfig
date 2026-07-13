-- Multi-select picker: choose several open buffers and share their paths with
-- Claude as `at_mentioned` context (one notification per file). The picker UI
-- lives here in the spec (config layer) so claudeide.nvim itself stays
-- dependency-free; it only calls the plugin's pure helpers.
local function send_buffers_to_claude()
  local sel = require("claudeide.selection")
  local bufs = sel.list_file_buffers()
  if #bufs == 0 then
    vim.notify("No file buffers to send", vim.log.levels.WARN, { title = "Claude IDE" })
    return
  end

  local items = {}
  for i, b in ipairs(bufs) do
    items[i] = { idx = i, text = b.relpath, path = b.path }
  end

  Snacks.picker.pick({
    title = "Send buffers to Claude  (Tab: toggle, Enter: send)",
    items = items,
    format = "text",
    sort = { fields = { "idx" } },
    layout = { preview = false },
    confirm = function(picker, item)
      local chosen = picker:selected({ fallback = true })
      picker:close()
      local paths = {}
      for _, it in ipairs(chosen) do
        paths[#paths + 1] = it.path
      end
      if #paths == 0 and item then
        paths[1] = item.path
      end
      sel.add_files(paths)
    end,
  })
end

return {
  dir = vim.fn.stdpath("config") .. "/dev/claudeide.nvim",
  name = "claudeide.nvim",
  event = "VeryLazy",
  cmd = {
    "ClaudeIde",
    "ClaudeIdeStart",
    "ClaudeIdeStop",
    "ClaudeIdeStatus",
    "ClaudeIdeSend",
    "ClaudeIdeAdd",
    "ClaudeIdeDiffAccept",
    "ClaudeIdeDiffDeny",
  },
  keys = {
    { "<leader>a", nil, desc = "AI/Claude IDE" },
    { "<leader>ai", "<cmd>ClaudeIdeStatus<cr>", desc = "Claude IDE status" },
    { "<leader>ab", "<cmd>ClaudeIdeAdd %<cr>", desc = "Add current buffer" },
    { "<leader>as", ":<C-u>ClaudeIdeSend<cr>", mode = "v", desc = "Send selection to Claude" },
    { "<F6>", ":<C-u>ClaudeIdeSend<cr>", mode = "v", desc = "Send selection to Claude" },
    { "<F6>", send_buffers_to_claude, mode = "n", desc = "Send buffered files to Claude" },
    { "<leader>aB", send_buffers_to_claude, desc = "Send buffered files to Claude" },
    { "<leader>aa", "<cmd>ClaudeIdeDiffAccept<cr>", desc = "Accept diff" },
    { "<leader>ad", "<cmd>ClaudeIdeDiffDeny<cr>", desc = "Deny diff" },
  },
  opts = {},
}
