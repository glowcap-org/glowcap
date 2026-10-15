---
id: ADR-0084
status: accepted
date: 2026-07-16
tags: [cli, driver, mcp, packaging, operability]
decision: "The installable glowcap product is a Zig binary under cli/ that consumes driver/net. One CapTP command registry drives CLI, REPL, and curated MCP. zig build remains the sole developer gate and packages the binary via installArtifact/release-pack. A2A-on-CapTP, timeline trace, and OTEL are deferred own passes, not CapTP roots."
supersedes: []
superseded_by: []
amended_by: [ADR-0174]
---

# ADR-0084 glowcap CLI product boundary

## Context

glowcap is libraries (Zig API, composable C ABI archives, language bindings)
plus demo and operator binaries under `apps/` (notably `rooms-peer`). A product
CLI for CapTP scripting, agent control (MCP), durable presence, A2A interop, and
observability risks a kitchen sink that hides authority, duplicates Host/loop
stacks, or mirrors `zig build` as a second gate. The CLI is an adapter consumer
of `driver` and adds no protocol layer.

## Decision

1. **Product binary** lives at repo-root `cli/`, imports the public `glowcap`
   module, and is not part of `libglowcap_*` / `src/` layer archives.
2. **One CapTP verb registry** dispatches CapTP leaves for REPL lines and MCP
   `tools/call`. Argv parse, scoped help, and shell completion share one
   in-tree command tree under `cli/cmd/` (same CapTP leaves). `glowcap repl`
   aliases `ocapn dial --repl` (one shell).
3. **MCP** exposes a curated default tool set generated from the registry.
   `full` / `readonly` catalogs are explicit. CapTP remains the peer wire.
   MCP is the agent-to-local-glowcap control plane.
4. **`apps rooms`** is the Rooms product command tree. Its session and team
   operations share one durable session lifecycle (ADR-0174). Demos nest under
   `demo` (or remain examples), not CapTP roots.
5. **`zig build`** is the only developer gate. The same graph installs and
   release-packs the `glowcap` binary. There is no `glowcap check`.
6. **Deferred runtimes:** A2A-on-CapTP + optional HTTP facade. OTEL export.
   Operational observability is stderr structured logs plus CapTP
   introspection. The griddle sim runtime and ocapnviz ship, and the rest of the observability
   family is recorded in [`docs/roadmap.md`](../../roadmap.md) and
   [ADR-0106](ADR-0106-trace-observation-capability.md).
   `glowcap griddle` is a subtree of this CLI (`run`, `status`, `help`).
   argv[0] is `glowcap`, and CapTP ops live under `ocapn` / `repl`.
7. **Operability** (identity, signals, exit codes, XDG state dir, MCP lifecycle,
   POSIX argv/`--`/`-V`, scoped help + completion) is part of the product
   contract. Present edges live in `docs/shipped.md` and `docs/boundaries.md`.

## Scope (what this does not decide)

- Concrete MCP JSON-RPC field layouts beyond “stdio MCP, registry-backed tools.”
- A2A Actor Card / Task type shapes on CapTP (Spec D plan).
- Timeline event schema bytes for ocapnviz revival.

## Alternatives Considered

- **Everything under `glowcap` including `check` / A2A as CapTP roots.**
  Rejected: conflates gates and CapTP. Drifts from `build.zig`. Griddle as a
  **named CLI subtree** (not a CapTP root, not a second argv[0]) is allowed for
  brand locking. The sim runtime ships under that subtree.
- **Rename argv[0] to `griddle` for CapTP + sim.** Rejected: CapTP ops and the
  library brand are `glowcap`, and the sim brand is the `griddle` subtree.
- **CLI inside `src/cli` as a library layer.** Rejected: a product binary must
  not ship inside protocol archives, and imports from `src/` into the CLI would
  blur the consumer boundary.
- **1:1 MCP tool per CapTP verb by default.** Rejected: it explodes agent tool
  selection and adds footguns. The default is curated, with an opt-in full
  catalog.
- **A2A as the CapTP substrate.** Rejected: CapTP is the capability mesh. A2A is
  an application vocabulary (plus an optional HTTP facade).

## Consequences

- `cli/` and `test/cli/` hold the product, and `build.zig` builds and installs
  the `glowcap` executable.
- `docs/shipped.md` / `README.md` / `docs/boundaries.md` name the CLI and its
  present edges.
- Rooms peer presence uses `glowcap apps rooms session` and its shared durable
  session lifecycle ([ADR-0174](ADR-0174-rooms-command-front-and-session-control.md)).
- `source-check` holds the `zig build glowcap` step when documented.
- Future OTEL/timeline attach to one event spine designed with stderr logging.
