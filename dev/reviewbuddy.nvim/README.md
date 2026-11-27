# reviewbuddy.nvim

`reviewbuddy.nvim` captures project-scoped editor comments and Git-anchored
Diffview comments in Neovim, then sends each queued batch to a session selected
at submit time. When Neovim runs inside Herdr, Herdr app, or cmux, only agents
in that host's current workspace or space and active review scope are shown. It
does not host an MCP server or own an agent terminal.

## Requirements

- Neovim 0.10 or newer
- Neovim running inside Herdr, Herdr app, or cmux:
  - Herdr requires `herdr` on `$PATH` and an agent in the same workspace whose
    `cwd` or `foreground_cwd` is inside the active project or Git scope.
  - Herdr app requires `hc` on `$PATH`; Neovim and the target agent must be
    terminals in the same app space, and the agent's foreground `cwd` must be
    inside the active review scope. Agents with lifecycle reporting are
    supported directly; an unreported foreground Cursor, Claude Code, Codex,
    or Kiro process is supported through guarded paste and submit.
  - cmux can use an active, hook-registered Claude Code, Codex, or Kiro session,
    or paste and submit the prompt in another terminal in the same workspace.
    The session or foreground agent process must also be inside the active
    review scope.
- `folke/snacks.nvim` for the multi-line comment float; Neovim's `vim.ui.input`
  is used when Snacks is unavailable

## Use

Actions work in any regular file buffer and in standard two-way Diffview file
panes. Ordinary buffers use the directory Neovim was launched from as an
immutable project root, even when that directory contains multiple Git
repositories or no repository at all. Diffview keeps its Git-root behavior.

| Command | Key | Behavior |
| --- | --- | --- |
| `:ReviewComment` | `F8` or `,hc` in Normal mode | Use the current file as context; in Diffview, comment on the cursor line. |
| `:ReviewCommentVisual` | `F8` or `,hc` in Visual mode | Comment on the exact selected text. |
| `:ReviewSubmitQueue` | `,hS` | Pick a session and submit all queued comments for the current review scope. |
| `:ReviewPick` | `,hp` | Explain when target selection occurs. |
| `:ReviewRefresh` | `,hr` | Refresh review sessions for the current review scope. |
| `:ReviewStatus` | `,hs` | Display queued comments and available sessions. |

The original `:HerdrComment`, `:HerdrCommentVisual`, `:HerdrSubmitQueue`, and
`:HerdrPick`, `:HerdrRefresh`, and `:HerdrStatus` commands remain as
compatibility aliases.

F9 is provided by `adbhelper.nvim`: it discovers connected Android and physical
USB iOS devices, captures a PNG under `~/Desktop/screen-shot`, resizes and
copies it like the shell `shot` / `iosshot` helpers, then opens the same
ReviewBuddy comment popup. The queued prompt tells the selected agent to open
the absolute PNG path with its image tool. A failed or canceled delivery keeps
the image context queued. Screenshot targets are workspace/space-wide rather
than source-project-scoped, since device images are not tied to a repository.
Android requires `adb`; iOS requires `idevice_id`, Developer Mode/developer
image support, and `pymobiledevice3` from `IOS_RECORD_PYTHON`,
`~/work/tools/iosrecord-venv/bin/python`, or `python3`.

The comment float shows the current queue count and lists existing queued
comments below the input. Press Enter to add its text and discover sessions
from Neovim's current host and workspace, then choose a destination from the
picker when more than one is available; a single target is used immediately.
Ctrl+S adds the text without submitting. Ctrl+D focuses the queued-comment
list; move to a comment and press Enter to delete only that item and return to
the composer without closing it or changing the current draft. Esc returns
without deleting. Canceling the destination picker or a delivery failure keeps
the queue intact; successful delivery removes only the submitted snapshot,
leaving comments added during delivery queued. Only one submission per review
scope runs at a time.

`HERDR_ENV=1` selects Herdr exclusively; agents are discovered with
`herdr api snapshot` and matched to both the current Herdr workspace and active
review scope. A fresh agent without a reported session identity is pinned to its
foreground process set, which is revalidated before delivery. `HC_TERMINAL_ID`
selects Herdr app next: the current terminal's
`herdr.space` label scopes discovery, `hc get` verifies each agent's foreground
scope and process identity, and `hc send` delivers the prompt. Unreported
agents are accepted only when their foreground process is unambiguously Cursor,
Claude Code, Codex, or Kiro. Otherwise, `CMUX_SURFACE_ID` selects cmux
exclusively. Active Claude Code, Codex, and Kiro receivers in the caller's
workspace and review scope use `cmux agent message`. When no registered
receiver exists, sibling terminal surfaces with an unambiguous foreground
Cursor, Claude Code, Codex, or Kiro process in the same scope appear as
`[cmux terminal]` targets; plain shells, background agents, and agents in other
repositories are excluded. Choosing one uses `cmux paste --submit`. This fallback
supports Cursor without pretending cmux can safely wake or message its
interactive TUI.
The initial paste fails when the target already has a draft or open dialog.
Large prompts are split into small sequential requests to avoid cmux 0.65.2
closing requests over 4 KiB; continuation chunks use `--force` only after the
plugin created the draft, and only the final chunk submits. Host, workspace,
review scope, session, and foreground process identity are revalidated before
delivery and again before every continuation chunk. Terminal paste commands
remain workspace-scoped. No cross-workspace targets are shown. Hook-backed
cmux targets use direct messages for small prompts and the same guarded
chunked-paste fallback for larger ones.

An ordinary-editor Normal-mode prompt uses one `File:` location—project-relative
under the launch root, otherwise absolute—and sends no code snippet. Visual mode
adds the selected line range and exact code in a filetype-tagged Markdown fence.
A device-screenshot prompt includes platform, device ID, absolute PNG path, and
an explicit instruction for the agent to inspect the image.
A Diffview prompt retains its Git-root-relative path, branch, HEAD revision,
selected code, and relevant before/current patch. Herdr receives the batch
through `herdr agent prompt`; cmux either uses the selected agent's hook-backed
message channel or pastes and submits it in the selected terminal. Herdr app
receives it through `hc send`.

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

- `repo.lua` resolves Git metadata used only by Diffview comments.
- `context.lua` normalizes Git and project-editor selections into stable review context.
- `diffview.lua` validates the current right pane and captures relevant before/current patch hunks.
- `queue.lua` stores session-only comments by project root or Diffview Git root.
- `backends/` contains the ordered host registry and one adapter per supported
  client. See [`docs/backends.md`](docs/backends.md) before adding a client.
- `discovery.lua` reads Herdr's JSON snapshot and filters agents by review scope.
- `app.lua` discovers same-space Herdr app agents through herdr-core and sends
  guarded prompts with `hc`.
- `cmux.lua` discovers active sessions in the caller's workspace and sends
  hook-backed cmux messages.
- `targets.lua` is the registry facade for discovery, validation, and labels.
- `client.lua` formats prompts and delivers directly to Herdr.
- `submit.lua` dispatches through the registry and clears only
  successfully delivered queues.
- `input.lua` provides the local comment UI.

The registry rejects a selected target when Neovim's active host no longer owns
it. Each adapter then revalidates workspace/space, review scope, session, and
process identity before transport. Adding a client does not change editor
interaction, queue semantics, or payload construction.
