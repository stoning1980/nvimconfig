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

Actions work in regular file buffers and in standard two-way Diffview file
panes inside a Git repository. Herdr agents are discovered with
`herdr api snapshot` and matched to that repository.

| Command | Key | Behavior |
| --- | --- | --- |
| `:HerdrComment` | `F8` or `,hc` in Normal mode | Queue a comment about the cursor line. |
| `:HerdrCommentVisual` | `F8` or `,hc` in Visual mode | Queue a comment about the exact selected text. |
| `:HerdrSubmitQueue` | `,hS` | Submit all queued comments for this repository to one Herdr agent. |
| `:HerdrPick` | `,hp` | Choose the active Herdr agent for this repository. |
| `:HerdrRefresh` | `,hr` | Forget the selected agent and refresh discovery. |
| `:HerdrStatus` | `,hs` | Display matching Herdr agents and their states. |

The comment float shows the current queue count and lists existing queued
comments below the input. Press Enter to add its text (when present) and submit
all queued comments, or Ctrl+S to add its text to the queue without submitting.
The queue is held only for the current Neovim session and is scoped to the Git
repository. It remains intact when a Herdr submission fails.

At submission, Herdr agents are discovered and one is selected or reused for
the repository. A combined prompt includes every queued item's Git-root-relative
path, selected line range, branch, HEAD revision, exact selected code, and
typed comment. It is sent only to that agent through `herdr agent prompt`; it
is not posted to a shared session timeline.

In a two-way Diffview, F8 works only from the right pane when that pane is the
checked-out HEAD or working-tree file and its displayed content still matches
the file on disk. The queued comment uses the current repository path and
selected code. When the left side differs, the prompt also includes only the
before/current patch hunks overlapping the selection, with three context
lines, so the agent can inspect the current repository without managing a
second revision identity.

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
- `client.lua` formats and delivers direct agent prompts.
- `input.lua` provides the local comment UI.

The CLI transport is intentionally isolated in `client.lua` and
`discovery.lua`, so a later implementation can use Herdr's Unix socket API
without changing editor interaction or payload construction.
