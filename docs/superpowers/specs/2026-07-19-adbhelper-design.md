# AdbHelper.nvim — Design Spec

## Summary

A Neovim plugin that sends visually selected text to a connected Android device
via `adb shell input text` / `input keyevent`. Lives in `dev/adbhelper.nvim/`
following the project's custom-plugin conventions.

## Structure

```
dev/adbhelper.nvim/
  lua/adbhelper/
    init.lua       -- setup(), public API (send_text command)
    device.lua     -- list devices (async), pick device (vim.ui.select)
    input.lua      -- send text with escape + keyevent fallback
lua/plugins/adb.lua  -- lazy.nvim plugin spec (keys, cmd, opts)
```

## User-Facing Interface

- **Keybinding:** `<F13>` in visual mode — sends the current selection to an
  Android device.
- **Command:** `:AdbSendText` — visual-range command, equivalent to the keymap.

## Flow: Send Selected Text

1. User visually selects text, presses `<F13>`.
2. Plugin extracts the visual selection.
3. `device.get_devices()` runs async (`vim.system({"adb", "devices"})`).
4. Decision based on device count:
   - **0 devices** → `vim.notify("No adb device connected", ERROR)`
   - **1 device** → auto-select, proceed to step 5.
   - **2+ devices** → show `vim.ui.select` picker (device serial as label);
     user picks one, then proceed to step 5.
5. `input.send_text(device_serial, text)` — processes and sends the text.

## Text Input Strategy

Characters in the selection are classified and sent in order:

### Safe characters (sent via `input text`)

Alphanumerics and: `-` `_` `.` `,` `/`

Consecutive safe characters are batched into a single `adb -s <dev> shell input
text <chunk>` call for efficiency.

### Symbols with known keyevent codes (sent via `input keyevent`)

A lookup table maps problematic characters to Android keycodes:

| Char | Keyevent | Char | Keyevent |
|------|----------|------|----------|
| space | 62 | `@` | 77 |
| `#` | 18 | `*` | 17 |
| `+` | 81 | `=` | 70 |
| `(` | 162 | `)` | 163 |
| `'` | 75 | `;` | 74 |
| `\` | 73 | tab | 61 |
| enter | 66 | | |

Characters requiring Shift (e.g., `!`, `:`, `^`, `~`) are sent via escaped
`adb shell input text '<char>'` — wrapping in single quotes protects most shell
metacharacters. Characters that cannot be sent by either method are skipped.

### Unknown / Unicode characters

Attempt to send via `adb shell input text '<escaped>'`. If the character cannot
be represented, skip it and notify the user once at the end (e.g., "3 characters
could not be sent").

### Sequencing

Multiple adb commands are dispatched sequentially (each waits for the prior
`vim.system` callback) to preserve text order.

## Device Discovery

Parses `adb devices` output:
```
List of devices attached
SERIAL1\tdevice
SERIAL2\tdevice
emulator-5554\tdevice
```

Lines matching `\t(device|emulator)` are extracted. The serial (first column) is
used as the `-s` argument to all subsequent adb calls.

## Error Handling

- `adb` not found on PATH → error notification.
- `adb devices` returns empty → error notification.
- User cancels picker → abort silently.
- Individual `adb shell input` failure → notify with stderr output.

## Dependencies

- Neovim ≥ 0.10 (for `vim.system`)
- `adb` on PATH
- No Lua or Neovim plugin dependencies (vim.ui.select is built-in)

## Plugin Loading (lazy.nvim spec)

```lua
-- lua/plugins/adb.lua
return {
  dir = vim.fn.stdpath("config") .. "/dev/adbhelper.nvim",
  name = "adbhelper.nvim",
  event = "VeryLazy",
  cmd = { "AdbSendText" },
  keys = {
    { "<F13>", ":<C-u>AdbSendText<cr>", mode = "v", desc = "Send selection to Android device" },
  },
  opts = {},
}
```

## Future Extensibility

The plugin structure supports adding more adb commands later (e.g., install APK,
logcat viewer, screenshot pull, launch app) as separate modules under
`lua/adbhelper/`.
