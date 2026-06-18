# pancake — Agentic Infrastructure

Canonical home for agent-facing guidance in this Zig repository.

## Layout

```text
.agents/
├── README.md   # this file; the Rules, Skills, and Hooks tables below are canonical
├── rules/      # one .md per rule — see the Rules table
├── skills/     # one directory per skill, each with a SKILL.md — see the Skills table
└── hooks/      # shared hook scripts — see the Hooks table
```

The tables below enumerate the contents and `zig build meta-check` holds them to
the directories in both directions, so the tree shows shape only and cannot
drift behind a file the tables already gate.

Tool overlays must point back to canonical rules here rather than duplicating
guidance:

- `.claude/rules` is one directory symlink to `.agents/rules`.
- `.cursor/rules/<name>.mdc` is one symlink per rule because Cursor discovers
  rules by `.mdc` file.
- `.claude/skills` and `.cursor/skills` are directory symlinks to
  `.agents/skills`.

`zig build meta-check` verifies this topology and every scaffolding claim it can
reach mechanically — symlink shape, the rule and skill indexes, Markdown links,
documented build steps, the living-state registry, and more.
[`tools/meta_check.zig`](../tools/meta_check.zig) is the authoritative
inventory; update it in the same change as any intentional scaffolding move.

## Rules

| Rule                                                | Purpose                                                                                                |
| --------------------------------------------------- | ------------------------------------------------------------------------------------------------------ |
| [agent-scaffolding](rules/agent-scaffolding.md)     | The scaffolding is a public API for agents: living-state discipline, the gate, the ratchet, the budget |
| [architecture](rules/architecture.md)               | Layer ownership, sync no-I/O core, codec/session/engine boundaries                                     |
| [cli](rules/cli.md)                                 | Zig gates, generated state, and git posture                                                            |
| [doc-drift](rules/doc-drift.md)                     | Living-state docs must match current code or drop the state claim                                      |
| [doc-voice](rules/doc-voice.md)                     | Human-readable prose for first-read docs and public examples                                           |
| [memory](rules/memory.md)                           | Frame ownership, bounded borrows, copy budget, allocator discipline                                    |
| [prerelease](rules/prerelease.md)                   | No compatibility debt yet, so the default verdict is fix the root now, not defer it                    |
| [prerelease-language](rules/prerelease-language.md) | Current-state prose; no transition narrative in first-read surfaces                                    |
| [project-values](rules/project-values.md)           | Explicit systems design, polished library surface, and no hidden costs                                 |
| [resilience](rules/resilience.md)                   | Attacker-controlled bytes, parse limits, and layer-owned refusal policy                                |
| [serena-mcp](rules/serena-mcp.md)                   | When to use Serena symbol tools vs. host file tools for Zig code                                       |
| [tests](rules/tests.md)                             | Unit, oracle, conformance, and benchmark discipline                                                    |

## Skills

| Skill                            | Purpose                                                                              |
| -------------------------------- | ------------------------------------------------------------------------------------ |
| [serena](skills/serena/SKILL.md) | Operating notes for Serena MCP tools in the Zig repo                                 |
| [work](skills/work/SKILL.md)     | Substantial work: assess, act or prove inaction, verify, compound for the next agent |

## Hooks

| Hook                                              | Purpose                                                |
| ------------------------------------------------- | ------------------------------------------------------ |
| [format-edited-file](hooks/format-edited-file.sh) | Per-edit `zig fmt` dispatch for agent-edited Zig files |
