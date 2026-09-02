# glowcap — Claude Code Overlay

This directory is a Claude-shaped overlay over [`.agents/`](../.agents/), where
the canonical agent guidance lives.

- `rules` is one directory symlink to [`.agents/rules`](../.agents/rules), not
  per-rule files. Cursor uses per-rule `.mdc` symlinks because its loader needs
  that shape; Claude gets the whole rules directory.
- `skills` is a symlink to [`.agents/skills`](../.agents/skills).
- `settings.json` wires edit hooks to scripts under
  [`.agents/hooks`](../.agents/hooks).

Edit canonical guidance under `.agents/`; keep this overlay thin.
`zig build source-check` verifies the symlink shape and hook/MCP wiring.
