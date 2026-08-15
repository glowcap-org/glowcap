---
id: ADR-0084
status: accepted
date: 2026-07-16
tags: [cli, driver, mcp, packaging, operability]
decision: "The installable pancake product is a Zig binary under cli/ that consumes driver/net. One CapTP command registry drives CLI, REPL, and curated MCP. zig build remains the sole developer gate and packages the binary via installArtifact/release-pack. A2A-on-CapTP, timeline viz, and OTEL are deferred own passes, not CapTP roots."
supersedes: []
superseded_by: []
---

# ADR-0084 pancake CLI product boundary

## Context

pancake shipped as libraries (Zig API, composable C ABI archives, language
bindings) plus demo and operator binaries under `apps/` (notably
`rooms-peer`). There was no unified product CLI. Ambition for CapTP scripting,
agent control (MCP), durable presence, A2A interop, and observability risked a
kitchen-sink that hid authority, duplicated Host/loop stacks, or mirrored
`zig build` as a second gate.

This engages no-hidden-runtime, boring public surface, and composition over
abstraction: the CLI is an adapter consumer of `driver`, not a new protocol
layer.

## Decision

1. **Product binary** lives at repo-root `cli/`, imports the public `pancake`
   module, and is **not** part of `libpancake_*` / `src/` layer archives.
2. **One CapTP verb registry** dispatches CapTP leaves for REPL lines and MCP
   `tools/call`. Argv parse, scoped help, and shell completion share one
   in-tree command tree under `cli/cmd/` (same CapTP leaves). `pancake repl`
   aliases `ocapn dial --repl` (one shell).
3. **MCP** exposes a **curated** default tool set generated from the registry;
   `full` / `readonly` catalogs are explicit. CapTP remains the peer wire;
   MCP is the agent-to-local-pancake control plane.
4. **`app rooms-peer`** is the rooms-app CapTP presence harness (wake loop +
   file mailbox; wire dialect is the rooms protocol). Demos nest under
   `demo` (or remain examples), not CapTP roots.
5. **`zig build`** is the only developer gate. The same graph installs and
   release-packs the `pancake` binary. There is no `pancake check`.
6. **Deferred runtimes:** A2A-on-CapTP + optional HTTP facade; OTEL export.
   Day-one ops observability is stderr structured logs plus CapTP
   introspection. The A2A sketch is
   [`pancake-a2a-on-captp-design.md`](../../planning/pancake-a2a-on-captp-design.md);
   the griddle sim runtime and ocapnviz have shipped, and what remains of the
   observability family is recorded in [`docs/roadmap.md`](../../roadmap.md)
   and [ADR-0106](ADR-0106-viz-control-capability.md).
   **Brand:** `pancake griddle` is a subtree of this CLI (`run`, `status`,
   `help`). argv[0] remains `pancake`; CapTP ops stay under `ocapn` / `repl`.
   An optional `griddle` → `pancake griddle` shim may land later.
7. **Operability** (identity, signals, exit codes, XDG state dir, MCP lifecycle,
   POSIX argv/`--`/`-V`, scoped help + completion) is part of the product
   contract. Present edges live in `docs/shipped.md` and `docs/boundaries.md`.

## Scope (what this does not decide)

- Concrete MCP JSON-RPC field layouts beyond “stdio MCP, registry-backed tools.”
- A2A Actor Card / Task type shapes on CapTP (Spec D plan).
- Timeline event schema bytes for ocapnviz revival.
- Whether the `rooms-peer` install argv[0] stays beside `pancake` forever or
  retires once `pancake app rooms-peer` is the only documented entry (shim
  ships today).

## Alternatives Considered

- **Everything under `pancake` including `check` / A2A as CapTP roots.**
  Rejected: conflates gates and CapTP; drifts from `build.zig`. Griddle as a
  **named CLI subtree** (not a CapTP root, not a second argv[0]) is allowed for
  brand locking; the sim runtime ships under that subtree.
- **Rename argv[0] to `griddle` for CapTP + sim.** Rejected: CapTP ops and the
  library brand stay `pancake`; sim brand is the `griddle` subtree.
- **CLI inside `src/cli` as a library layer.** Rejected: product binary must not
  ship inside protocol archives; reverse imports from `src/` into CLI would blur
  the consumer boundary.
- **1:1 MCP tool per CapTP verb by default.** Rejected: agent tool-selection
  explosion and footguns; curated default with opt-in full catalog.
- **A2A as the CapTP substrate.** Rejected: CapTP already is the capability
  mesh; A2A is an application vocabulary (+ optional HTTP facade).

## Consequences

- `cli/` and `test/cli/` land; `build.zig` adds `pancake` executable + install.
- `docs/shipped.md` / `README.md` / `docs/boundaries.md` name the CLI and its
  present edges.
- Rooms peer presence migrates toward `pancake app rooms-peer` without a second Host
  stack.
- `source-check` gains the `zig build pancake` step when documented.
- Future OTEL/timeline attach to one event spine designed with stderr logging.
