# pancake — Agent Hooks

Canonical home for hook scripts that fire around agent file edits.

| Surface                      | Canonical                                        |
| ---------------------------- | ------------------------------------------------ |
| Per-edit Zig format dispatch | [`format-edited-file.sh`](format-edited-file.sh) |

The script formats `*.zig` with `zig fmt`. Anything else is ignored. The script
exits 0 even when formatting fails; `zig build check` stays the load-bearing
gate. Cursor and Claude point at this canonical command; `zig build meta-check`
verifies the tool wiring.
