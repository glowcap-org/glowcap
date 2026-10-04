# glowcap — Agentic Infrastructure

Canonical home for agent-facing guidance in this Zig repository.

## Layout

```text
.agents/
├── README.md   # this file; the Rules, Skills, Personas, and Hooks tables below are canonical
├── rules/      # one .md per rule — see the Rules table
├── skills/     # one directory per skill, each with a SKILL.md — see the Skills table
├── personas/   # anonymous taste lenses (slug.md) — see the Personas table
└── hooks/      # shared hook scripts, see the Hooks table
```

The tables below enumerate the contents and `zig build source-check` holds them to
the directories in both directions, so the tree shows shape only and cannot
drift behind a file the tables already gate. A named person and a person-named
slug live in an unpublished persona source, never here; the order is in
[`personas/README.md`](personas/README.md).

Tool overlays must point back to canonical rules here rather than duplicating
guidance:

- `.claude/rules` is one directory symlink to `.agents/rules`.
- `.cursor/rules/<name>.mdc` is one symlink per rule because Cursor discovers
  rules by `.mdc` file.
- A rule is resident (`alwaysApply: true`) or scoped. A scoped rule names its
  files twice, as Cursor's `globs:` and as Claude's quoted `paths:` list,
  because Claude ignores `globs:` and would otherwise load the rule into every
  session. `source-check` holds the two lists equal.
- `.claude/skills` and `.cursor/skills` are directory symlinks to
  `.agents/skills`.
- Codex reads `AGENTS.md` and `.agents/skills` directly; `.codex/README.md`
  records that no `.codex/skills` mirror is needed.

`zig build source-check` verifies this topology and every scaffolding claim it can
reach mechanically, symlink shape, the rule and skill indexes, Markdown links,
documented build steps, the living-state registry, and more.
[`tools/check/source_check.zig`](../tools/check/source_check.zig) is the authoritative
inventory; update it in the same change as any intentional scaffolding move.

## Rules

| Rule                                                | Purpose                                                                                                |
| --------------------------------------------------- | ------------------------------------------------------------------------------------------------------ |
| [agent-scaffolding](rules/agent-scaffolding.md)     | The scaffolding is a public API for agents: living-state discipline, the gate, the ratchet, the budget |
| [architecture](rules/architecture.md)               | Layer ownership, sync no-I/O core, codec/session/engine boundaries                                     |
| [captp-waits](rules/captp-waits.md) | Every product CapTP dial and settle in `cli/`, examples, and CLI tests names a finite budget |
| [cli](rules/cli.md) | Gates, the devcontainer front, generated state, and git posture |
| [doc-drift](rules/doc-drift.md)                     | Living-state docs must match current code or drop the state claim                                      |
| [doc-voice](rules/doc-voice.md)                     | Human-readable prose for first-read docs and public examples                                           |
| [memory](rules/memory.md)                           | Frame ownership, bounded borrows, copy budget, allocator discipline, footprint budgets                 |
| [prerelease](rules/prerelease.md)                   | No compatibility debt yet, so the default verdict is fix the root now, not defer it                    |
| [project-values](rules/project-values.md)           | Explicit systems design, polished library surface, and no hidden costs                                 |
| [resilience](rules/resilience.md)                   | Untrusted inbound bytes, parse limits, and layer-owned refusal policy                                    |
| [scripts](rules/scripts.md)                         | Placement, interface, verification, and lifecycle for committed helper scripts                         |
| [tests](rules/tests.md)                             | Test taxonomy and vocabulary: which layer, what authority, what a failure means                        |

## Skills

| Skill                            | Purpose                                                                              |
| -------------------------------- | ------------------------------------------------------------------------------------ |
| [community-review](skills/community-review/SKILL.md) | OCapN / Goblins community-review preflight |
| [debugging](skills/debugging/SKILL.md) | A failure is data: evidence before theory, ordered suspects, halved search, a fix that explains it |
| [file-budget](skills/file-budget/SKILL.md) | Canonical workflow for splitting oversize sources until the closed exception inventory is empty |
| [glowcap-cli](skills/glowcap-cli/SKILL.md) | Shell CapTP (argv / REPL / listen / `--json`) |
| [glowcap-mcp](skills/glowcap-mcp/SKILL.md) | In-host CapTP via project MCP |
| [memory-ledger](skills/memory-ledger/SKILL.md) | Every named wire-path allocation and copy, one entry each, held to its declaration by the gate |
| [ratchet](skills/ratchet/SKILL.md) | Land a session's lesson at the strongest layer: check, fixture, rule line, or deletion |
| [rooms-peer](skills/rooms-peer/SKILL.md) | One durable Rooms identity, multiple rooms and DMs, persistent inbox and continuous listening |
| [rooms-team](skills/rooms-team/SKILL.md) | Multi-persona durable team in a glowcap room |
| [serena](skills/serena/SKILL.md) | Serena first for Zig symbol work: tool choice, call shapes, cold start, fallback |
| [smell-annihilation](skills/smell-annihilation/SKILL.md) | Structural smell pass (architecture + cost) |
| [work](skills/work/SKILL.md) | Substantial work: assess, act or prove inaction |

## Personas

Anonymous project lenses only (`slug` = filename stem). Lookup order and file
shape: [`personas/README.md`](personas/README.md).

| Persona | Purpose |
| ------- | ------- |
| [agentic-lead](personas/agentic-lead.md) | Multi-agent orchestration lead (default rooms-team lead) |
| [engineering-steward](personas/engineering-steward.md) | Domain-neutral engineering judgment: root fixes, evidence, automation, and economy without lower standards |
| [first-impression](personas/first-impression.md) | The first code, tab, and recipe are the product — testing scaffolds do not occupy the lead |
| [fresh-eyes](personas/fresh-eyes.md) | Seasoned engineer, zero OCapN exposure — does the doc teach a newcomer, or is it rehearsed? |
| [scaffold-rigor](personas/scaffold-rigor.md) | Agent scaffolding sharpness — short skills, gates over folklore |
| [stability-steward](personas/stability-steward.md) | Support tiers a consumer can plan against — a claim is the evidence that runs for it |
| [wire-clarity](personas/wire-clarity.md) | Protocol evidence over folklore — CapTP/OCapN seams |

## Hooks

| Hook                                              | Purpose                                                |
| ------------------------------------------------- | ------------------------------------------------------ |
| [format-edited-file](hooks/format-edited-file.sh) | Per-edit formatter dispatch (`zig fmt`, `rustfmt`, `deno fmt`) for agent-edited files |
