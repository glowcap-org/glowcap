# glowcap — Agent Guide

This repository is `glowcap`: a Zig implementation of the OCapN / CapTP
substrate. glowcap is the implementation. There is no released predecessor to
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
| Substantial feature, refactor, sweep, or release check                     | [`docs/vision.md`](docs/vision.md) + [work skill](.agents/skills/work/SKILL.md)                 | `zig build check`, plus `runtime-check` when process behavior changed |
| Red gate, flaky failure, or bug hunt                                       | [debugging rule](.agents/rules/debugging.md)                                                    | reproduce alone, then the narrowest failing step        |
| Protocol semantics or layer boundary                                       | [architecture rule](.agents/rules/architecture.md) + [tests rule](.agents/rules/tests.md)       | `zig build oracle-check`, then `check-external`          |
| Inbound parsing, length limits, or untrusted inbound bytes              | [resilience rule](.agents/rules/resilience.md)                                                  | `zig build test` + `zig build oracle-check`             |
| Allocation, copy, or frame ownership on the wire path                      | [memory rule](.agents/rules/memory.md)                                                          | `zig build test` (alloc and footprint budgets run here) |
| Runtime seam — `actors`, `net`, or `driver` (`std.Io`, sockets, turn loop) | [architecture rule](.agents/rules/architecture.md) + [memory rule](.agents/rules/memory.md)     | `zig build test`                                        |
| C ABI surface or a language binding                                        | [architecture rule](.agents/rules/architecture.md) + [`bindings/README.md`](bindings/README.md) | `zig build gen-header-ocapn` + `zig build gen-ts-abi` + `zig build rust-dogfood` |
| Example or example app                                                     | [`examples/README.md`](examples/README.md) + [doc-voice](.agents/rules/doc-voice.md)            | `zig build examples`                                    |
| Live CapTP from the shell (call/host/REPL)                                | [glowcap-cli skill](.agents/skills/glowcap-cli/SKILL.md) (+ [`docs/cli.md`](docs/cli.md) for humans) | `zig build cli-test`                              |
| Live CapTP via project MCP tools                                          | [glowcap-mcp skill](.agents/skills/glowcap-mcp/SKILL.md) (+ `.cursor/mcp.json` / `.mcp.json`) | `zig build` then reload MCP                       |
| Runtime process, application, or language workspace                        | [tests rule](.agents/rules/tests.md) + [cli rule](.agents/rules/cli.md)                          | `zig build runtime-check`                                |
| Committed helper script or operations front                               | [scripts rule](.agents/rules/scripts.md) + [ADR-0150](docs/decisions/adr/ADR-0150-operations-fronts-and-script-placement.md) | owning focused check + `zig build source-check`, plus `zig build infrastructure-check` for executable workflow behavior |
| Agent scaffolding (`.agents/`, overlays, hooks, skills)                    | [agent-scaffolding rule](.agents/rules/agent-scaffolding.md)                                    | `zig build source-check`, plus `zig build infrastructure-check` for executable workflow behavior |
| Persona lenses for review / rooms-team members                             | [`.agents/README.md` Personas](.agents/README.md#personas) + [lookup](.agents/personas/README.md) | `zig build source-check`                                 |
| Doc or plan edit                                                           | [doc-drift](.agents/rules/doc-drift.md) + [doc-voice](.agents/rules/doc-voice.md)               | `zig build source-check`                                 |

**Context map** (when you need authority, not a tour):

- Destination: [`docs/vision.md`](docs/vision.md)
- Route to 1.0 and step standings: [`docs/ladder.md`](docs/ladder.md)
- Concrete remaining work, ordered: [`docs/roadmap.md`](docs/roadmap.md)
- Layer ownership: [`docs/architecture.md`](docs/architecture.md)
- Settled decisions: [`docs/decisions/adr/`](docs/decisions/adr/)
- glowcap-authored Syrup oracle corpus and pressure: `test/oracle/` (corpus
  under `test/oracle/corpus/`)
- Live Goblins wire authority: `conformance/goblins-peer/`
- OCapN spec corpus: `conformance/ocapn-spec/`

## First Principles

- Every change moves toward the vision in [`docs/vision.md`](docs/vision.md), or
  holds a line that protects it. That destination is a networking library, not a
  polite CapTP port: write the ambition as shape, never as a first-read slogan.
  Performance, the architecture, and that destination do not get traded for
  convenience.
- Protocol correctness and capability semantics come before implementation
  convenience.
- Match depth without lowering the bar. Progressive disclosure chooses what to
  read first; checks, generated inventories, and scripts stand in for repeated
  reasoning. If correctness depends on a surface you have not read, widen
  context or run the check that owns it.
- **Principled moves only. No workarounds, no quick fixes.** Every change fixes
  the root, or it is not the change. A shortcut is a design decision made badly
  and then hidden, and it costs most where it is easiest: the layer stops
  explaining itself, and the next reader inherits a shape nobody chose. When
  the right fix looks too big, that is the design asking to be understood, not
  routed around. Understand it, then make it.
- Performance is a public contract: every allocation and copy on the wire path
  is forbidden, intentional, or measured.
- Production APIs should make the correct path the easy path. Do not rely on
  comments to prevent misuse.
- A fact has one authority, an effect stays local to the seam that owns it, and
  of two otherwise equal shapes the easier one to change wins. This is the
  "DRY, orthogonal, and easier to change" value in
  [project-values](.agents/rules/project-values.md); hold it in every diff.
- The portable core stays sync and no-I/O; adapters own `std.Io`, transports,
  scheduling, and host integration.
- Frame movement is owned transfer or bounded borrow. Test/debug copying lives
  outside production modules.
- Session state is authoritative; codecs parse and render but do not own
  authority.
- Conformance is load-bearing. A semantic claim needs a scenario or fixture.
- Live CapTP runs through the product fronts — the
  [glowcap-mcp](.agents/skills/glowcap-mcp/SKILL.md),
  [glowcap-cli](.agents/skills/glowcap-cli/SKILL.md), and
  [rooms-peer](.agents/skills/rooms-peer/SKILL.md) skills — never a throwaway
  Zig harness for a product-shaped CapTP act.
- Engineering-taste reference names stay in prompts and plans, never in
  committed files; the taste lands as structure
  ([agent-scaffolding](.agents/rules/agent-scaffolding.md)).
- glowcap is AI-assisted and maintainer-directed, not an AI project. The
  maintainer is a human learning OCapN and networking by building, answerable
  for what lands, not an auditor of every line. Disclose assistance on
  landings; [`PROVENANCE.md`](PROVENANCE.md) owns the rest. Do not write that
  biography, a line-audit claim, or the destination's ambition into human docs.

## Agent Scaffolding

Canonical agent guidance lives under [`.agents/`](.agents/); its
[index](.agents/README.md) names every rule and skill, what each governs, and
the overlay symlinks that load them into each tool.

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

Codex loads those project skills directly from [`.agents/skills/`](.agents/skills/);
[`.codex/README.md`](.codex/README.md) records the thin Codex overlay.
