# pancake — Cursor Overlay

This directory is a Cursor-shaped overlay over [`.agents/`](../.agents/).

- `rules/*.mdc` exposes canonical rules from `.agents/rules/` in Cursor's rule
  format.
- `skills` is a symlink to [`.agents/skills`](../.agents/skills).
- `mcp.json` launches Serena for this Zig repository.
- `hooks.json` wires Cursor edit hooks to scripts under [`.agents/hooks`](../.agents/hooks).
- `settings.json` enables shared agent plugins.

Edit canonical guidance in `.agents/`; keep this overlay thin. `zig build
meta-check` verifies the symlink shape and hook/MCP wiring.
