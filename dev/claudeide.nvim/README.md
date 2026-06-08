# claudeide.nvim

A from-scratch Neovim integration for [Claude Code](https://docs.anthropic.com/en/docs/claude-code),
written in pure Lua with zero external dependencies. Neovim acts as the **IDE
server**: it implements the same WebSocket-based MCP protocol used by Anthropic's
official VS Code and JetBrains extensions, so a `claude` CLI session you start
yourself (in any terminal) can connect to Neovim with `/ide`.

## How it works

1. Neovim starts a localhost WebSocket server on a random port (automatically, on
   startup) and writes a discovery lock file to `~/.claude/ide/<port>.lock`
   containing the port, workspace folder, and a random auth token.
2. You run `claude` yourself in a separate terminal, then type `/ide` and pick
   "Neovim". The CLI reads the lock file and connects back over WebSocket.
3. Messages are exchanged as JSON-RPC 2.0 (MCP): Neovim sends selection updates
   and at-mentions; Claude calls tools like `openFile` and `openDiff`.

```
claude CLI (you launch it)  --/ide-->  reads ~/.claude/ide/*.lock
        |
        +--WebSocket/JSON-RPC-->  Neovim (IDE server)
```

## Requirements

- Neovim >= 0.8 (LuaJIT)
- The `claude` CLI installed (run in its own terminal)

## Usage

1. Open Neovim in your project. The IDE server auto-starts (see `:ClaudeIdeStatus`).
2. In another terminal, `cd` to the same project and run `claude`.
3. In the Claude session, type `/ide` and choose "Neovim".

## Commands

| Command | Description |
| --- | --- |
| `:ClaudeIde` | Ensure the server is running and show connection instructions |
| `:ClaudeIdeStart` / `:ClaudeIdeStop` | Start / stop the server manually |
| `:ClaudeIdeStatus` | Show server/connection status |
| `:ClaudeIdeSend` | (visual) Send the current selection to Claude as context |
| `:ClaudeIdeAdd {file}` | Add a file (default: current buffer) to Claude context |
| `:ClaudeIdeDiffAccept` | Apply the pending proposed diff (`FILE_SAVED`) |
| `:ClaudeIdeDiffDeny` | Reject the pending proposed diff (`DIFF_REJECTED`) |

## Default keymaps

- `<leader>ai` show Claude IDE status
- `<leader>ab` add current buffer
- `<leader>as` (visual) send selection
- `<leader>aa` / `<leader>ad` accept / deny diff

## Configuration

```lua
require("claudeide").setup({
  auto_start = true,           -- start the IDE server on load
  log_level = "info",          -- error | warn | info | debug
  port_range = { 10000, 65535 },
  track_selection = true,      -- broadcast cursor/selection changes
})
```

## Implemented MCP surface (MVP)

- Server -> Claude notifications: `selection_changed`, `at_mentioned`
- Claude -> Neovim: `initialize`, `tools/list`, `tools/call`
- Tools: `openFile`, `openDiff` (blocking; resolved by accept/deny)

This is an MVP; additional tools from the protocol (diagnostics, open editors,
workspace folders, save, etc.) can be added in `lua/claudeide/tools.lua`.
