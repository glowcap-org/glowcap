# glowcap — Codex Overlay

Codex reads [AGENTS.md](../AGENTS.md) for repository instructions and loads
project skills directly from [`.agents/skills`](../.agents/skills). There is no
`.codex/skills` mirror.

Keep canonical guidance and skill support files under `.agents/`. A skill may
carry helper directories such as `bin/`, `scripts/`, or `references/` beside its
`SKILL.md`; the skill body decides when to use them.

[`config.toml`](config.toml) starts the Serena MCP server through
`glowcap-dev`, as [`.mcp.json`](../.mcp.json) does for Claude. Codex reads it
for a trusted project started at the repository root.
