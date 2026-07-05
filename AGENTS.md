# pancake — Agent Guide

This repository is `pancake`: a Zig implementation of the OCapN / CapTP
substrate. pancake is the implementation. There is no released predecessor to
defer to.

OCapN behavior, Spritely Goblins fixtures, and Zig-local protocol scenarios are
the conformance authority for every semantic claim. The Rust, Deno, Python, and
Racket bindings consume the C ABI as dogfoods; a consumer is never the oracle
for Zig semantics.

[`docs/vision.md`](docs/vision.md) is the goal every change serves. Read it
before scoping new work, and keep the shipped inventory in `docs/shipped.md`
honest about how far the code has actually reached toward it.

## Start Here

Match depth to the task: do not read the whole tree for a one-line fix.

| Task                                                                       | Load first                                                                                      | Gate                                                    |
| -------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------- | ------------------------------------------------------- |
| Quick fix in one layer                                                     | Focused rule for that surface ([rule index](.agents/README.md))                                 | `zig build test` or narrower                            |
| Substantial feature, refactor, sweep, or release check                     | [`docs/vision.md`](docs/vision.md) + [work skill](.agents/skills/work/SKILL.md)                 | `zig build check`                                       |
| Protocol semantics or layer boundary                                       | [architecture rule](.agents/rules/architecture.md) + [tests rule](.agents/rules/tests.md)       | `zig build oracle-check`                                |
| Inbound parsing, length limits, or any attacker-controlled bytes           | [resilience rule](.agents/rules/resilience.md)                                                  | `zig build test` + `zig build oracle-check`             |
| Allocation, copy, or frame ownership on the wire path                      | [memory rule](.agents/rules/memory.md)                                                          | `zig build test` (alloc and footprint budgets run here) |
| Runtime seam — `actors`, `net`, or `driver` (`std.Io`, sockets, turn loop) | [architecture rule](.agents/rules/architecture.md) + [memory rule](.agents/rules/memory.md)     | `zig build test`                                        |
| C ABI surface or a language binding                                        | [architecture rule](.agents/rules/architecture.md) + [`bindings/README.md`](bindings/README.md) | `zig build gen-header-ocapn` + `zig build gen-ts-abi` + `zig build rust-dogfood` |
| Example or example app                                                     | [`examples/README.md`](examples/README.md) + [doc-voice](.agents/rules/doc-voice.md)            | `zig build examples`                                    |
| Agent scaffolding (`.agents/`, overlays, hooks, skills)                    | [agent-scaffolding rule](.agents/rules/agent-scaffolding.md)                                    | `zig build meta-check`                                  |
| Doc edit                                                                   | [doc-drift](.agents/rules/doc-drift.md) + [doc-voice](.agents/rules/doc-voice.md)               | same change updates claims                              |

**Context map** (when you need authority, not a tour):

- Destination: [`docs/vision.md`](docs/vision.md)
- Route to 1.0 and rung standings: [`docs/ladder.md`](docs/ladder.md)
- Concrete remaining work, ordered: [`docs/roadmap.md`](docs/roadmap.md)
- Layer ownership: [`docs/architecture.md`](docs/architecture.md)
- Settled decisions: [`docs/decisions/adr/`](docs/decisions/adr/)
- pancake-authored Syrup oracle corpus and pressure: `test/oracle/` (corpus
  under `test/oracle/corpus/`)
- Live Goblins wire authority: `conformance/goblins-peer/`
- OCapN spec corpus: `conformance/ocapn-spec/`

## First Principles

- Every change moves toward the vision in [`docs/vision.md`](docs/vision.md), or
  holds a line that protects it. Performance, the architecture, and that
  destination do not get traded for convenience.
- Protocol correctness and capability semantics come before implementation
  convenience.
- Performance is a public contract: every allocation and copy on the wire path
  is forbidden, intentional, or measured.
- Production APIs should make the correct path the easy path. Do not rely on
  comments to prevent misuse.
- The portable core stays sync and no-I/O; adapters own `std.Io`, transports,
  scheduling, and host integration.
- Frame movement is owned transfer or bounded borrow. Test/debug copying lives
  outside production modules.
- Session state is authoritative; codecs parse and render but do not own
  authority.
- Conformance is load-bearing. A semantic claim needs a scenario or fixture.
- Names associated with external engineering taste references belong in prompts
  and plans, not in committed files. Encode that taste as explicit protocol
  vocabulary, honest allocation/lifetime surfaces, polished boundaries, and
  tests.

## Agent Scaffolding

Canonical agent guidance lives under [`.agents/`](.agents/); its
[index](.agents/README.md) names every rule and skill and what each governs.
Claude gets rules through one directory symlink,
[`.claude/rules`](.claude/rules/) → `.agents/rules`. Cursor gets one symlink per
rule, `.cursor/rules/<name>.mdc` → `.agents/rules/<name>.md`, because Cursor
discovers rules by `.mdc` file.

The scaffolding is itself a public API for agents, with its own gate. Read
[`.agents/rules/agent-scaffolding.md`](.agents/rules/agent-scaffolding.md)
before changing anything under `.agents/`, the `.claude/` or `.cursor/`
overlays, the hooks, or the skills.

Serena is first-class for code-symbol work. Read
[`.agents/rules/serena-mcp.md`](.agents/rules/serena-mcp.md) before symbol
lookup, reference walks, renames, implementation lookup, body-level edits, or
single-file diagnostics in Zig source. The operator notes live at
[`.agents/skills/serena/SKILL.md`](.agents/skills/serena/SKILL.md).

For substantial work — scoping, sweeps, architectural moves, or release
readiness — follow
[`.agents/skills/work/SKILL.md`](.agents/skills/work/SKILL.md).
