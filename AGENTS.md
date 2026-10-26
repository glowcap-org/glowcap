# glowcap — Agent Guide

`glowcap` is a Zig implementation of the OCapN / CapTP substrate, with no
released predecessor. OCapN behavior, Spritely Goblins fixtures, and Zig
protocol scenarios are the authority for every semantic claim. The Rust, Deno,
Python, and Racket bindings consume the C ABI and are never the oracle.

[`docs/vision.md`](docs/vision.md) is the goal every change serves. Read it
before scoping new work, and keep `docs/shipped.md` matching how far the code
has reached.

## Start Here

For contribution work, read [CONTRIBUTING.md](CONTRIBUTING.md) for scope,
review, and responsibility. Work within the contributor's authorization.

Load rules for the files you touch and skills for the task. If your harness
does not load scoped rules, read them from the [index](.agents/README.md).
Run every gate through
[`.agents/skills/work/bin/glowcap-dev`](.agents/skills/work/bin/glowcap-dev)
([cli rule](.agents/rules/cli.md)).

| Task | Load first | Gate |
| --- | --- | --- |
| Quick fix in one layer | the rule that loads with the file | `zig build test` or narrower |
| Substantial feature, refactor, sweep, or release check | [work skill](.agents/skills/work/SKILL.md) | `zig build check`, plus `runtime-check` when process behavior changed |
| Red gate, flake, or bug hunt | [debugging skill](.agents/skills/debugging/SKILL.md) | reproduce alone, then the narrowest failing step |
| Protocol semantics or layer boundary | [architecture](.agents/rules/architecture.md) + [tests](.agents/rules/tests.md) | `zig build oracle-check`, then `check-external` |
| Performance claim or slow path | [profiling skill](.agents/skills/profiling/SKILL.md) | the bench's `profile-*` step, then its ReleaseFast run |
| Wire-path allocation or copy | [memory](.agents/rules/memory.md) + [memory-ledger skill](.agents/skills/memory-ledger/SKILL.md) | `zig build test` |
| C ABI surface or a binding | [architecture](.agents/rules/architecture.md) + [`bindings/README.md`](bindings/README.md) | the `gen-*-check` steps ([cli rule](.agents/rules/cli.md)) + `zig build rust-dogfood` |
| Example or example app | [`examples/README.md`](examples/README.md) | `zig build examples` |
| Live CapTP (shell, MCP, rooms) | [glowcap-cli](.agents/skills/glowcap-cli/SKILL.md), [glowcap-mcp](.agents/skills/glowcap-mcp/SKILL.md), [rooms-peer](.agents/skills/rooms-peer/SKILL.md) | `zig build cli-test` |
| Runtime process or language workspace | [tests](.agents/rules/tests.md) | `zig build runtime-check` |
| Committed script or operations front | [`.agents/rules/scripts.md`](.agents/rules/scripts.md) | owning check + `zig build source-check` |
| Docs, plans, or agent scaffolding | [doc-writing skill](.agents/skills/doc-writing/SKILL.md) + [doc-drift](.agents/rules/doc-drift.md), plus [agent-scaffolding](.agents/rules/agent-scaffolding.md) for `.agents/` | `zig build source-check`, plus `infrastructure-check` for executable workflow |

**Context map:** route to 1.0 in [`docs/ladder.md`](docs/ladder.md), ordered
work in [`docs/roadmap.md`](docs/roadmap.md) (idea to plan to execution runs
through [plan to plan](docs/planning/plan-to-plan.md)), layer tour in
[`docs/architecture.md`](docs/architecture.md), what the project builds on in
[`docs/dependencies.md`](docs/dependencies.md), settled decisions in
[`docs/decisions/adr/`](docs/decisions/adr/), the Syrup reference corpus in
`test/oracle/`, live Goblins wire authority in `conformance/goblins-peer/`, and
the OCapN spec in `conformance/ocapn-spec/`. The
[`.agents/` index](.agents/README.md) lists every rule, skill, and persona.

## First Principles

[Project values](.agents/rules/project-values.md) and the
[prerelease posture](.agents/rules/prerelease.md) load in every session and
hold the principles. Two more apply to every task:

- Serena is first for Zig symbol work ([serena skill](.agents/skills/serena/SKILL.md)).
- glowcap is AI-assisted and maintainer-directed. Disclose assistance on
  landings ([`PROVENANCE.md`](PROVENANCE.md)).

Codex loads [`.agents/skills/`](.agents/skills/) directly, and
[`.codex/README.md`](.codex/README.md) records its overlay.
