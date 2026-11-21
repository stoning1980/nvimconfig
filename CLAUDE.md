# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a Neovim configuration built on **LazyVim** (the distribution framework on top of lazy.nvim). It includes custom
plugins in `dev/` that provide AI coding assistant integration.

## Architecture

### Loading Sequence

`init.lua` → `lua/config/lazy.lua` (bootstraps lazy.nvim + LazyVim) → auto-imports all `lua/plugins/*.lua` specs

### Key Directories

- `lua/config/` — Core config: options, keymaps, autocmds (loaded by LazyVim conventions)
- `lua/plugins/` — Plugin specs (each file returns a lazy.nvim spec table)
- `dev/claudeide.nvim/` — Custom plugin: WebSocket-based MCP server making Neovim an IDE endpoint for Claude CLI
- `dev/codechat.nvim/` — Custom plugin: Terminal driver for AI coding agents (Claude, Cursor, ttadk wrappers)
- `dev/herdr.nvim/` — Custom plugin: Git-anchored review comments routed to Herdr or same-workspace cmux agents

### Custom Plugin: claudeide.nvim

A pure-Lua WebSocket server implementing the MCP protocol (JSON-RPC 2.0, version `2025-03-26`) using `vim.uv` for async I/O. It allows Claude CLI to connect via `/ide` and interact with the editor.

Key subsystems:
- `server/` — TCP listener, HTTP upgrade handshake, WebSocket frame codec
- `mcp.lua` + `tools.lua` — MCP tool dispatch (`openFile`, `openDiff`)
- `diff.lua` — Blocking side-by-side diff with accept/deny workflow
- `lockfile.lua` — Writes discovery files to `~/.claude/ide/<port>.lock`
- `selection.lua` — Broadcasts `selection_changed` notifications

### Custom Plugin: codechat.nvim

Drives CLI agents in Snacks terminals. Injects file/selection context via bracketed paste. Depends on `folke/snacks.nvim`.

Key subsystems:
- `terminal.lua` — Terminal lifecycle and input injection
- `ui.lua` — Comment popup (Snacks float) before sending context
- `config.lua` — Agent registry (command, setup steps, login shell, fallbacks)

### Custom Plugin: herdr.nvim

Queues typed review comments plus exact visual selection context for the current
Git repository, detects whether Neovim is hosted by Herdr, Herdr app, or cmux, then shows
only matching agents from that host's current workspace. Herdr app terminals
use their herdr-core space label as the workspace boundary.

Key subsystems:
- `repo.lua` + `context.lua` + `queue.lua` — Git-root metadata, selected-text anchors, and session-only queues
- `discovery.lua` — Herdr CLI snapshot discovery and repository matching
- `app.lua` — Herdr app space discovery and `hc send` delivery
- `cmux.lua` + `targets.lua` — Host detection, same-workspace cmux discovery, agent-process validation, and terminal paste/submit fallback
- `submit.lua` — Backend dispatch and clear-on-success queue handling
- `client.lua` — Direct `herdr agent prompt` delivery
- `input.lua` — Snacks comment float with a `vim.ui.input` fallback

## Conventions

- **Leader key**: `,`
- **Lua style**: 2-space indent, 120 column width (enforced by `stylua.toml`)
- **Plugin loading**: Custom plugins use `event = "VeryLazy"` + explicit `cmd`/`keys` tables
- **No linting**: `nvim-lint` is explicitly disabled
- **LSP**: `kotlin_language_server` is disabled (too heavy for large monorepos); Kotlin symbols use a Treesitter fallback (`lua/config/ts_symbols.lua`)

## Formatting

```bash
stylua lua/
```

## LazyVim Extras Enabled

`editor.outline`, `lang.java`, `lang.json`, `lang.kotlin`, `lang.markdown`

## Environment Dependencies

- Node.js 22 via nvm (required for `ttadk` and `cl` agent commands)
- `ttadk` CLI (internal TikTok tool) for wrapped agent access
- `claude` or `cl` CLI for direct Claude Code access
