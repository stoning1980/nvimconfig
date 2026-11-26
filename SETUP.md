# New Machine Setup

Migration guide for this Neovim configuration. Written to be followed top-to-bottom
by a human or an AI agent. Repo: `git@github.com:stoning1980/nvimconfig.git`,
cloned to `~/.config/nvim`.

## What this config is

- **LazyVim** distribution on top of **lazy.nvim** (`init.lua` → `lua/config/lazy.lua`).
- Plugin versions are pinned in `lazy-lock.json`; enabled LazyVim extras are listed in `lazyvim.json`.
- Two **in-repo custom plugins** under `dev/` (no separate install — they load from the repo):
  - `dev/adbhelper.nvim` — Android text input plus Android/iOS Simulator app and proxy actions. Keys: `<F12>` / `Shift+F12`.
  - `dev/reviewbuddy.nvim` — routes project-scoped editor context or Git-anchored
    Diffview comments to agents in Neovim's current Herdr, Herdr app, or cmux
    workspace. Key: `<F8>`.
- **Leader key** is `,` (comma). Lua style: 2-space indent, 120 columns (`stylua.toml`).
- Full custom keymap cheatsheet lives at the top of `lua/config/keymaps.lua`. Repo conventions are documented in `CLAUDE.md`.

## Prerequisites

### Required (core editing, pickers, git, treesitter)

| Tool | Why | Notes |
|------|-----|-------|
| **Neovim ≥ 0.11** | Config uses `vim.system`, `vim.fs.root`, `vim.fn.getregion` (0.10+) | Verify with `nvim --version` |
| **git** | lazy.nvim bootstrap, Diffview, git pickers, `git blame` (F4) | |
| **C compiler + make** | nvim-treesitter compiles parsers on install | `gcc`/`clang` + `make` |
| **ripgrep** (`rg`) | Snacks grep / git-grep pickers (F5/F6) | |
| **fd** | Snacks file finding | package may be `fd-find` on some distros |
| **Nerd Font** | LazyVim/Snacks icons render correctly | set it as your terminal font |
| **lazygit** | LazyVim git UI (`<leader>gg`) | |

### Recommended

| Tool | Why |
|------|-----|
| **Node.js (current LTS)** | Required by many JavaScript/TypeScript LSP servers and tools |
| **stylua** | Formats Lua in this repo (`stylua lua/`) |
| **JDK** (17+) | LazyVim `lang.java` extra (jdtls) |

### Optional (mobile / ReviewBuddy workflow)

- **adb** / Android SDK platform-tools — the mobile-engineering workflow this config targets.
- A supported ReviewBuddy host: Herdr, Herdr app/herdr-core, or cmux.
- A supported coding agent running in the same host workspace and Git repository as Neovim.
- Language toolchains as needed by the enabled extras: TypeScript/Node, Kotlin, etc.

### Install prerequisites

macOS (Homebrew):

```bash
brew install neovim git ripgrep fd lazygit stylua gcc make
# A Nerd Font, e.g.:
brew install --cask font-jetbrains-mono-nerd-font
# nvm (then install the current LTS):
brew install nvm   # follow brew's post-install to add nvm to your shell rc
nvm install --lts
```

Debian/Ubuntu:

```bash
sudo apt update
sudo apt install -y git ripgrep fd-find build-essential
# Neovim: prefer a 0.11+ build (apt's may be old) — use the official appimage,
# the unstable PPA, or a release tarball. Verify: nvim --version
# lazygit, stylua: install from their GitHub releases or your package manager.
# nvm: https://github.com/nvm-sh/nvm  then: nvm install --lts
```

## Installation

1. **Back up any existing config** (skip if this is a clean machine):

   ```bash
   mv ~/.config/nvim ~/.config/nvim.bak 2>/dev/null || true
   mv ~/.local/share/nvim ~/.local/share/nvim.bak 2>/dev/null || true
   mv ~/.local/state/nvim ~/.local/state/nvim.bak 2>/dev/null || true
   mv ~/.cache/nvim ~/.cache/nvim.bak 2>/dev/null || true
   ```

   To trial it *without* touching your real config, use an isolated app name instead:
   `NVIM_APPNAME=nvim-test` and clone to `~/.config/nvim-test`.

2. **Clone the repo** to `~/.config/nvim`:

   ```bash
   git clone git@github.com:stoning1980/nvimconfig.git ~/.config/nvim
   ```

   (Use the HTTPS URL `https://github.com/stoning1980/nvimconfig.git` if SSH keys aren't set up yet.)

3. **First launch** — bootstrap and install plugins:

   ```bash
   nvim
   ```

   On first start, `lua/config/lazy.lua` clones lazy.nvim, then lazy.nvim installs every
   plugin pinned in `lazy-lock.json` and Mason installs the LSP servers/formatters for the
   enabled extras. Treesitter parsers compile in the background (needs the C compiler).
   Let it finish; if the UI looks busy, run `:Lazy sync` and wait.

4. **Verify health**:

   ```vim
   :checkhealth
   :Lazy
   :Mason
   ```

   Address anything flagged (missing `rg`/`fd`/compiler/Nerd Font shows up here).

## Post-install verification

- Open a file inside a git repo and try the function keys (cheatsheet is at the top of `lua/config/keymaps.lua`):
  - `F1` toggle Diffview, `F4` git annotate panel, `F5`/`F6` grep, `F7` find git files.
  - `F10` mark word/selection (interestingwords), `S-F10` clear marks.
  - `F11` copy repo-relative path.
- Formatting check: `stylua --check lua/` should report no diffs.

## ReviewBuddy (optional)

`<F8>` opens a Git-anchored review comment for the cursor line or exact visual
selection. ReviewBuddy discovers agents only in Neovim's current host workspace
or app space and current Git repository, then submits through Herdr, herdr-core,
or cmux. It does not start or own an agent terminal.

Setup notes:

- Launch Neovim and the target agent inside the same Herdr, Herdr app, or cmux
  workspace.
- Keep the agent's foreground working directory inside the same Git repository.
- ReviewBuddy uses `herdr`, `hc`, or `cmux` from `PATH`, depending on the host.

## Notes & gotchas

- **Kotlin LSP is disabled** on purpose (`lua/plugins/lsp.lua`) — `kotlin_language_server`
  chokes on large Android/Gradle monorepos. Current-file Kotlin symbols come from the
  Treesitter fallback in `lua/config/ts_symbols.lua`.
- **Shifted function keys**: legacy terminals emit `S-F1..S-F12` as `<F13>..<F24>`, so this
  config maps compatibility aliases where those shifted actions are used. Herdr's
  `~/.config/herdr-app/keys.json` sends shifted function keys with explicit Kitty modifiers,
  allowing physical F18/F19 to remain distinct from Shift+F6/Shift+F7. Other terminals may
  still collapse those pairs.
- **Enabled LazyVim extras** (`lazyvim.json`): `editor.outline`, `lang.java`, `lang.json`,
  `lang.kotlin`, `lang.markdown`, `lang.typescript`. Each may pull extra Mason tools.
- After changing plugins, re-pin versions by committing the updated `lazy-lock.json`.

## Updating

```vim
:Lazy sync      " update plugins to latest, then commit lazy-lock.json
:Mason          " update LSP servers / tools
```
