# pancake — Agent Hooks

Canonical home for hook scripts that fire around agent file edits.

| Surface | Canonical | Tool wiring |
| --- | --- | --- |
| Per-edit Zig format dispatch | [`format-edited-file.sh`](format-edited-file.sh) | Cursor: [`.cursor/hooks.json`](../../.cursor/hooks.json) `afterFileEdit`. Claude Code: [`.claude/settings.json`](../../.claude/settings.json) `hooks.PostToolUse` matcher `Edit\|Write\|MultiEdit`. |

The script formats `*.zig` with `zig fmt`. Anything else is ignored. The script
exits 0 even when formatting fails; `zig build check` stays the load-bearing
gate.
