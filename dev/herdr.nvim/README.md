# herdr.nvim

`herdr.nvim` sends a review comment from the current Neovim file directly to
an agent running in Herdr. It is deliberately separate from `claudeide.nvim`
and `codechat.nvim`: it does not host an MCP server or own an agent terminal.

## Requirements

- Neovim 0.10 or newer
- `herdr` available on `$PATH`
- A running Herdr session with an agent whose `cwd` or `foreground_cwd` is
  inside the current Git repository
- `folke/snacks.nvim` for the multi-line comment float; Neovim's `vim.ui.input`
  is used when Snacks is unavailable

## Use

All actions require a file buffer inside a Git repository. Herdr agents are
discovered with `herdr api snapshot` and matched to that repository.

| Command | Key | Behavior |
| --- | --- | --- |
| `:HerdrComment` | `,hc` in Normal mode | Enter a comment about the cursor line. |
| `:HerdrCommentVisual` | `,hc` in Visual mode | Enter a comment about the exact selected text. |
| `:HerdrPick` | `,hp` | Choose the active Herdr agent for this repository. |
| `:HerdrRefresh` | `,hr` | Forget the selected agent and refresh discovery. |
| `:HerdrStatus` | `,hs` | Display matching Herdr agents and their states. |

When several agents match, the first comment opens a picker. The selection is
remembered for that repository until Neovim exits or `:HerdrRefresh` runs.

Each prompt includes the Git-root-relative path, selected line range, branch,
HEAD revision, exact selected code, and typed comment. It is sent only to the
selected agent through `herdr agent prompt`; it is not posted to a shared
session timeline.

## Architecture

- `repo.lua` resolves Git repository metadata for the current file.
- `context.lua` normalizes exact editor selections into stable review context.
- `discovery.lua` reads Herdr's JSON snapshot and filters agents by repository.
- `client.lua` formats and delivers direct agent prompts.
- `input.lua` provides the local comment UI.

The CLI transport is intentionally isolated in `client.lua` and
`discovery.lua`, so a later implementation can use Herdr's Unix socket API
without changing editor interaction or payload construction.
