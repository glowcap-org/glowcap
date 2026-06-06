# pancake — Claude Code Overlay

This directory is a Claude-shaped overlay over [`.agents/`](../.agents/).

- `rules` is one directory symlink to [`.agents/rules`](../.agents/rules), not
  per-rule files. Cursor uses per-rule `.mdc` symlinks because its loader needs
  that shape; Claude gets the whole rules directory.
- `skills` is a symlink to [`.agents/skills`](../.agents/skills).
- `settings.json` enables shared agent plugins and wires edit hooks to scripts
  under [`.agents/hooks`](../.agents/hooks).

Claude reads repository rules through the root [`CLAUDE.md`](../CLAUDE.md)
symlink to [`AGENTS.md`](../AGENTS.md), and this overlay exposes canonical rules
through `.claude/rules`. Canonical guidance lives in `AGENTS.md` and `.agents/`.

Edit canonical guidance under `.agents/`; keep this overlay thin. `zig build
meta-check` verifies the symlink shape and hook/MCP wiring.
