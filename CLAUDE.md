# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a Neovim configuration built on **LazyVim** (the distribution framework on top of lazy.nvim). It includes custom
plugins in `dev/` for mobile-device actions and routing review comments to coding agents.

## Architecture

### Loading Sequence

`init.lua` → `lua/config/lazy.lua` (bootstraps lazy.nvim + LazyVim) → auto-imports all `lua/plugins/*.lua` specs

### Key Directories

- `lua/config/` — Core config: options, keymaps, autocmds (loaded by LazyVim conventions)
- `lua/plugins/` — Plugin specs (each file returns a lazy.nvim spec table)
- `dev/adbhelper.nvim/` — Custom plugin: Android device text input plus Android/iOS Simulator app actions
- `dev/reviewbuddy.nvim/` — Custom plugin: Git-anchored review comments routed to Herdr or same-workspace cmux agents

### Custom Plugin: adbhelper.nvim

Provides Android device discovery and text input, Android proxy/app actions,
and iOS Simulator app actions. It is loaded by `lua/plugins/adb.lua`.

### Custom Plugin: reviewbuddy.nvim

Queues typed review comments plus exact visual selection context for the current
Git repository, detects whether Neovim is hosted by Herdr, Herdr app, or cmux, then shows
only matching agents from that host's current workspace. Herdr app terminals
use their herdr-core space label as the workspace boundary.

Key subsystems:
- `repo.lua` + `context.lua` + `queue.lua` — Git-root metadata, selected-text anchors, and session-only queues
- `backends/` — Ordered host registry and built-in adapters; see `dev/reviewbuddy.nvim/docs/backends.md` before adding a client
- `discovery.lua` — Herdr CLI snapshot discovery and repository matching
- `app.lua` — Herdr app space discovery and `hc send` delivery
- `cmux.lua` — Same-workspace cmux discovery, agent-process validation, and terminal paste/submit fallback
- `targets.lua` + `submit.lua` — Registry facades, queue dispatch, and clear-on-success handling
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

- `adb` for Android actions; `xcrun simctl` for iOS Simulator actions
- One supported host when using ReviewBuddy: Herdr, Herdr app/herdr-core, or cmux
- A supported coding agent running in Neovim's current host workspace and Git repository
