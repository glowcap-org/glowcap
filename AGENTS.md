# glowcap — Agent Guide

`glowcap` is a Zig implementation of OCapN / CapTP. OCapN behavior,
Spritely Goblins fixtures, and Zig protocol scenarios are the authority for
semantic claims. The Rust, Deno, Python, and Racket bindings consume the C
ABI and are never the oracle.

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
| Protocol semantics or layer boundary | [architecture](.agents/rules/architecture.md) + [tests](.agents/rules/tests.md) | `zig build oracle-check`, then `ocapn-conformance` and `goblins-interop`; `check-external` adds every Rooms browser proof |
| Performance claim or slow path | [profiling skill](.agents/skills/profiling/SKILL.md) | the bench's `profile-*` step, then its ReleaseFast run |
| Wire-path allocation or copy | [memory](.agents/rules/memory.md) + [memory-ledger skill](.agents/skills/memory-ledger/SKILL.md) | `zig build test` + `source-check` |
| Bend laws or coverage of a deterministic property | [bend-laws](.agents/skills/bend-laws/SKILL.md) | `bend-proofs` plus focused implementation checks |
| C ABI surface or a binding | [architecture](.agents/rules/architecture.md) + [`bindings/README.md`](bindings/README.md) | the `gen-*-check` steps ([cli rule](.agents/rules/cli.md)) + `zig build rust-test` |
| Example or example app | [`examples/README.md`](examples/README.md) | `zig build examples` |
| Live CapTP (shell, MCP, rooms) | [glowcap-cli](.agents/skills/glowcap-cli/SKILL.md), [glowcap-mcp](.agents/skills/glowcap-mcp/SKILL.md), [rooms-peer](.agents/skills/rooms-peer/SKILL.md) | `zig build cli-test` when `cli/` changed |
| Runtime process or language workspace | [tests](.agents/rules/tests.md) | `zig build runtime-check` |
| CI, release, or publication | [`docs/maintaining.md`](docs/maintaining.md) + [`ci/README.md`](ci/README.md) | `zig build infrastructure-check` |
| Site page | [doc-writing skill](.agents/skills/doc-writing/SKILL.md) | `zig build site-render-check` |
| Rooms app | [`apps/rooms/developing.md`](apps/rooms/developing.md) | the narrow `rooms-*` step for the boundary ([build steps](docs/build-steps.md)) |
| Committed script or operations front | [`.agents/rules/scripts.md`](.agents/rules/scripts.md) | owning check + `zig build source-check` |
| Docs, plans, or agent scaffolding | [doc-writing skill](.agents/skills/doc-writing/SKILL.md) + [doc-drift](.agents/rules/doc-drift.md), plus [agent-scaffolding](.agents/rules/agent-scaffolding.md) for `.agents/` | `zig build source-check`, plus `infrastructure-check` for executable workflow |

**Context map:** [milestones](docs/milestones.md), [roadmap](docs/roadmap.md),
[planning](docs/planning/plan-to-plan.md), [architecture](docs/architecture.md),
[dependencies](docs/dependencies.md), and [decisions](docs/decisions/adr/).
Protocol evidence lives in `test/oracle/` (Syrup), `conformance/goblins-peer/`
(live Goblins), and `conformance/ocapn-spec/` (the OCapN spec). The
[agent index](.agents/README.md) lists the rules and skills.

## First Principles

Read [project values](.agents/rules/project-values.md) and the
[prerelease posture](.agents/rules/prerelease.md) first. Three more rules
apply to every task.

- When the session has Serena, it is first for Zig symbol work ([serena skill](.agents/skills/serena/SKILL.md)).
- Send no generated issue, patch, or comment to Zig, OCapN, or any project
  whose policy forbids it ([`PROVENANCE.md`](PROVENANCE.md)).
- glowcap is AI-assisted and maintainer-directed. Disclose assistance on
  landings ([`PROVENANCE.md`](PROVENANCE.md)).
