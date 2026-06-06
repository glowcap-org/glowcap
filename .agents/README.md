# pancake — Agentic Infrastructure

Canonical home for agent-facing guidance in this Zig repository.

## Layout

```text
.agents/
├── README.md
├── rules/
│   ├── agent-scaffolding.md
│   ├── architecture.md
│   ├── cli.md
│   ├── doc-drift.md
│   ├── memory.md
│   ├── project-values.md
│   ├── prerelease-language.md
│   ├── resilience.md
│   ├── serena-mcp.md
│   └── tests.md
├── skills/
│   ├── README.md
│   └── serena/
└── hooks/
    ├── README.md
    └── format-edited-file.sh
```

Tool overlays must point back to canonical rules here rather than duplicating
guidance:

- `.claude/rules` is one directory symlink to `.agents/rules`.
- `.cursor/rules/<name>.mdc` is one symlink per rule because Cursor discovers
  rules by `.mdc` file.
- `.claude/skills` and `.cursor/skills` are directory symlinks to
  `.agents/skills`.

`zig build meta-check` verifies this topology, the shared hook command, Serena
MCP pointers, ignored Serena runtime state, and documented build-step names.
Update `tools/meta_check.zig` with any intentional scaffolding change.

## Rules

| Rule | Purpose |
| --- | --- |
| [agent-scaffolding](rules/agent-scaffolding.md) | Principle-first scaffolding, no-footgun APIs, Serena-first symbol work, and verification discipline |
| [architecture](rules/architecture.md) | Layer ownership, sync no-I/O core, codec/session/engine boundaries |
| [cli](rules/cli.md) | Zig gates, generated state, and git posture |
| [doc-drift](rules/doc-drift.md) | Living-state docs must match current code or drop the state claim |
| [memory](rules/memory.md) | Frame ownership, bounded borrows, copy budget, allocator discipline |
| [project-values](rules/project-values.md) | Explicit systems design, polished library surface, and no hidden costs |
| [prerelease-language](rules/prerelease-language.md) | Current-state prose; no transition narrative in first-read surfaces |
| [resilience](rules/resilience.md) | Attacker-controlled bytes, parse limits, and layer-owned refusal policy |
| [serena-mcp](rules/serena-mcp.md) | When to use Serena symbol tools vs. host file tools for Zig code |
| [tests](rules/tests.md) | Unit, oracle, conformance, and benchmark discipline |

## Skills

| Skill | Purpose |
| --- | --- |
| [serena](skills/serena/SKILL.md) | Operating notes for Serena MCP tools in the Zig repo |

## Hooks

| Hook | Purpose |
| --- | --- |
| [format-edited-file](hooks/format-edited-file.sh) | Per-edit `zig fmt` dispatch for agent-edited Zig files |
