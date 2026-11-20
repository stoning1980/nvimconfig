# herdr.nvim

`herdr.nvim` captures Git-anchored review comments in Neovim and sends each
queued batch to a session selected at submit time. When Neovim runs inside
Herdr, only agents in that Herdr workspace are shown. When it runs inside cmux,
only supported agents in that cmux workspace are shown. It is deliberately
separate from `claudeide.nvim` and `codechat.nvim`: it does not host an MCP
server or own an agent terminal.

## Requirements

- Neovim 0.10 or newer
- Neovim running inside Herdr or cmux:
  - Herdr requires `herdr` on `$PATH` and an agent in the same workspace whose
    `cwd` or `foreground_cwd` is inside the current Git repository.
  - cmux can use an active, hook-registered Claude Code, Codex, or Kiro session,
    or paste and submit the prompt in another terminal in the same workspace.
- `folke/snacks.nvim` for the multi-line comment float; Neovim's `vim.ui.input`
  is used when Snacks is unavailable

## Use

Actions work in regular file buffers and in standard two-way Diffview file
panes inside a Git repository.

| Command | Key | Behavior |
| --- | --- | --- |
| `:ReviewComment` | `F8` or `,hc` in Normal mode | Comment on the cursor line. |
| `:ReviewCommentVisual` | `F8` or `,hc` in Visual mode | Comment on the exact selected text. |
| `:ReviewSubmitQueue` | `,hS` | Pick a session and submit all queued comments for this repository. |
| `:ReviewStatus` | `,hs` | Display queued comments and available sessions. |

The original `:HerdrComment`, `:HerdrCommentVisual`, `:HerdrSubmitQueue`, and
`:HerdrStatus` commands remain as compatibility aliases.

The comment float shows the current queue count and lists existing queued
comments below the input. Press Enter to add its text and discover sessions
from Neovim's current host and workspace, then choose a destination from the
picker when more than one is available; a single target is used immediately.
Ctrl+S adds the text without submitting. Canceling the picker or a delivery
failure keeps the queue intact; successful delivery removes only the submitted
snapshot, leaving comments added during delivery queued. Only one submission
per repository runs at a time.

`HERDR_ENV=1` selects Herdr exclusively; agents are discovered with
`herdr api snapshot` and matched to both the current Herdr workspace and Git
repository. Otherwise, `CMUX_SURFACE_ID` selects cmux exclusively. Active
Claude Code, Codex, and Kiro receivers in the caller's workspace use
`cmux agent message`. When no registered receiver exists, sibling terminal
surfaces with an unambiguous foreground Cursor, Claude Code, Codex, or Kiro
process appear as `[cmux terminal]` targets; plain shells and background agents
are excluded. Choosing one uses `cmux paste --submit`. This fallback supports
Cursor without pretending cmux can safely wake or message its interactive TUI.
The initial paste fails when the target already has a draft or open dialog.
Large prompts are split into small sequential requests to avoid cmux 0.65.2
closing requests over 4 KiB; continuation chunks use `--force` only after the
plugin created the draft, and only the final chunk submits. Host, workspace,
repository, session, and foreground process identity are revalidated before
delivery and again before every continuation chunk. Terminal paste commands
remain workspace-scoped. No cross-workspace targets are shown. Hook-backed
cmux targets use direct messages for small prompts and the same guarded
chunked-paste fallback for larger ones.

A combined prompt includes every queued item's Git-root-relative path,
selected line range, branch, HEAD revision, exact selected code, and typed
comment. Herdr receives it through `herdr agent prompt`; cmux either uses the
selected agent's hook-backed message channel or pastes and submits it in the
selected terminal.

In a two-way Diffview, F8 works only from the right pane when that pane is the
checked-out HEAD commit or working-tree file. A working-tree pane must still
match the file on disk; a committed HEAD pane remains reviewable when newer
local edits make the worktree differ. The queued comment uses the current
repository path and selected code. When the left side differs, the prompt also
includes only the before/current patch hunks overlapping the selection, with
three context lines.

The left pane, historical right panes, index panes, the file panel, binary
files, a null right side, and conflict layouts are rejected with a warning.
An added file is supported when its current content is on the right and the
left null side is represented as an empty file in the patch.

## Architecture

- `repo.lua` resolves Git repository metadata for the current file.
- `context.lua` normalizes exact editor selections into stable review context.
- `diffview.lua` validates the current right pane and captures relevant before/current patch hunks.
- `queue.lua` stores session-only review comments by Git repository.
- `discovery.lua` reads Herdr's JSON snapshot and filters agents by repository.
- `cmux.lua` discovers active sessions in the caller's workspace and sends
  hook-backed cmux messages.
- `targets.lua` detects the current host and labels that host's picker entries.
- `client.lua` formats prompts and delivers directly to Herdr.
- `submit.lua` dispatches through the selected backend and clears only
  successfully delivered queues.
- `input.lua` provides the local comment UI.

CLI transports are isolated in `client.lua`, `discovery.lua`, and `cmux.lua`,
so either backend can evolve without changing editor interaction or payload
construction.
