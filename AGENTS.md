# glowcap — Agent Guide

`glowcap` is a Zig implementation of the OCapN / CapTP substrate, with no
released predecessor. OCapN behavior, Spritely Goblins fixtures, and Zig
protocol scenarios are the authority for every semantic claim. The Rust, Deno,
Python, and Racket bindings consume the C ABI and are never the oracle.

[`docs/vision.md`](docs/vision.md) is the goal every change serves; read it
before scoping new work, and keep `docs/shipped.md` matching how far the code
has reached.

## Start Here

Rules load automatically by file path; skills load by task. Match depth to the
task. Run every gate through
[`.agents/skills/work/bin/glowcap-dev`](.agents/skills/work/bin/glowcap-dev)
([cli rule](.agents/rules/cli.md)).

| Task | Load first | Gate |
| --- | --- | --- |
| Quick fix in one layer | the rule that loads with the file | `zig build test` or narrower |
| Substantial feature, refactor, sweep, or release check | [work skill](.agents/skills/work/SKILL.md) | `zig build check`, plus `runtime-check` when process behavior changed |
| Red gate, flake, or bug hunt | [debugging skill](.agents/skills/debugging/SKILL.md) | reproduce alone, then the narrowest failing step |
| Protocol semantics or layer boundary | [architecture](.agents/rules/architecture.md) + [tests](.agents/rules/tests.md) | `zig build oracle-check`, then `check-external` |
| Wire-path allocation or copy | [memory](.agents/rules/memory.md) + [memory-ledger skill](.agents/skills/memory-ledger/SKILL.md) | `zig build test` |
| C ABI surface or a binding | [architecture](.agents/rules/architecture.md) + [`bindings/README.md`](bindings/README.md) | `zig build gen-header-ocapn` + `zig build gen-ts-abi` + `zig build rust-dogfood` |
| Example or example app | [`examples/README.md`](examples/README.md) | `zig build examples` |
| Live CapTP (shell, MCP, rooms) | [glowcap-cli](.agents/skills/glowcap-cli/SKILL.md), [glowcap-mcp](.agents/skills/glowcap-mcp/SKILL.md), [rooms-peer](.agents/skills/rooms-peer/SKILL.md) | `zig build cli-test` |
| Runtime process or language workspace | [tests](.agents/rules/tests.md) | `zig build runtime-check` |
| Committed script or operations front | [`.agents/rules/scripts.md`](.agents/rules/scripts.md) | owning check + `zig build source-check` |
| Docs, plans, or agent scaffolding | [doc-drift](.agents/rules/doc-drift.md) + [agent-scaffolding](.agents/rules/agent-scaffolding.md) | `zig build source-check`, plus `infrastructure-check` for executable workflow |

**Context map:** route to 1.0 in [`docs/ladder.md`](docs/ladder.md), ordered
work in [`docs/roadmap.md`](docs/roadmap.md), layer tour in
[`docs/architecture.md`](docs/architecture.md), settled decisions in
[`docs/decisions/adr/`](docs/decisions/adr/), the Syrup reference corpus in
`test/oracle/`, live Goblins wire authority in `conformance/goblins-peer/`, and
the OCapN spec in `conformance/ocapn-spec/`. The
[`.agents/` index](.agents/README.md) lists every rule, skill, and persona.

## First Principles

- Every change moves toward the vision or protects it. Convenience never
  buys performance, architecture, or that destination.
- Protocol correctness and capability semantics come before implementation
  convenience. A semantic claim needs a scenario or fixture.
- Fix the root. No workarounds or quick fixes; when the right fix looks too
  big, understand the design, then make it
  ([prerelease](.agents/rules/prerelease.md)).
- Every wire-path allocation and copy is forbidden, named, or measured.
- The portable core is sync and no-I/O; adapters own `std.Io`, transports,
  scheduling, and host integration. Session state is authoritative; codecs
  only parse and render.
- Live CapTP runs through the product fronts, never a throwaway Zig harness.
- Serena is first for Zig symbol work ([serena skill](.agents/skills/serena/SKILL.md)).
- glowcap is AI-assisted and maintainer-directed. Disclose assistance on
  landings ([`PROVENANCE.md`](PROVENANCE.md)). Keep the maintainer's
  biography, line-audit claims, and destination slogans out of human docs.

Codex loads [`.agents/skills/`](.agents/skills/) directly;
[`.codex/README.md`](.codex/README.md) records its overlay.
