# pancake — Cursor Overlay

This directory is a Cursor-shaped overlay over [`.agents/`](../.agents/), where
the canonical agent guidance lives.

- `rules/*.mdc` exposes canonical rules from `.agents/rules/` in Cursor's rule
  format.
- `skills` is a symlink to [`.agents/skills`](../.agents/skills).
- `mcp.json` launches Serena for Zig symbols and pancake for live CapTP.
- `hooks.json` wires Cursor edit hooks to scripts under
  [`.agents/hooks`](../.agents/hooks).

Edit canonical guidance in `.agents/`; keep this overlay thin.
`zig build source-check` verifies the symlink shape and hook/MCP wiring.
