# Review backend extension guide

`herdr.nvim` sends queued review comments only to an agent that shares
Neovim's current host, host workspace or space, and Git repository. Backends
are internal plugin modules, not a public `setup()` API.

## Backend contract

Add one module under `lua/herdr/backends/` that returns:

| Field | Contract |
| --- | --- |
| `id` | Unique host adapter name. |
| `target_ids` | Target `backend` values owned by this adapter. Values must be unique across adapters. |
| `host_error` | Error returned when a queued target no longer belongs to the active host. |
| `detect()` | Return true only when Neovim has inherited this host's caller identity. |
| `discover(repo_root, callback)` | Return normalized targets from Neovim's current workspace or space and repository only. |
| `revalidate(repo_root, target, callback)` | Rediscover or query fresh state and reject stale workspace, repository, session, or process identity. |
| `send_queue(target, items, callback)` | Deliver the queue to the exact revalidated target. |
| `label(target)` | Return the picker label for a normalized target. |

Callbacks follow the existing conventions:

```lua
discover(repo_root, function(targets, err) end)
revalidate(repo_root, target, function(current_target, err) end)
send_queue(target, items, function(ok, err) end)
```

A normalized target always has:

```lua
{
  backend = "client_target_kind",
  id = "host target identity",
  agent = "display name",
  status = "display status",
}
```

It must also retain enough host-specific identity to prove at submission time
that the target has not moved or been replaced. Existing examples use:

- Herdr: `workspace_id` and `session_id`
- Herdr app: `space_id`, caller and target creation times, and foreground PID
- cmux: `workspace_id`, session ID, or foreground process identity

## Fail-closed invariants

Every backend must preserve all of these:

1. `detect()` identifies Neovim's inherited host, never another focused app or
   globally running client.
2. Discovery starts from Neovim's caller identity and returns targets only from
   that host's same workspace or space.
3. Every target also matches the current Git repository by live foreground
   working directory when the host exposes one.
4. Discovery excludes Neovim itself and ambiguous or background agent
   processes.
5. Revalidation runs after selection and before delivery. It verifies the host,
   workspace or space, repository, target, and agent/session/process identity.
6. Delivery addresses only the revalidated target. It never falls back to a
   focused or global destination.
7. Multi-request transports revalidate between continuation requests.
8. Any discovery, validation, or delivery failure keeps the queue.

The registry in `lua/herdr/backends/init.lua` enforces active-host ownership
before calling an adapter's `revalidate()`. The adapter remains responsible for
workspace, repository, and target identity checks.

## Adding a client

1. Create `lua/herdr/backends/<client>.lua` with the full contract.
2. Add it to the ordered list in `lua/herdr/backends/init.lua`. Ordering is host
   precedence when environments expose more than one marker.
3. Add target normalization and repository/workspace filtering tests.
4. Add successful and failing revalidation tests, including workspace movement
   and agent replacement.
5. Add transport success/failure tests and prove failures retain the queue.
6. Add the target IDs to the registry dispatch matrix in
   `tests/herdr_backends_spec.lua`.
7. Update this guide and the README architecture list.

Do not add client branches to `targets.lua` or `submit.lua`; those files are
registry facades.

## Test commands

Run the registry contract and backend regressions:

```sh
nvim --headless -u NONE -l tests/herdr_backends_spec.lua
env -u HC_TERMINAL_ID -u HERDR_ENV CMUX_SURFACE_ID=surface-caller \
  nvim --headless -u NONE -l tests/herdr_spec.lua
```

Then run every `tests/*.lua` script, Stylua on changed Lua files, and
`git diff --check`. When the client is available locally, perform a read-only
live discovery/revalidation smoke test before attempting delivery.
