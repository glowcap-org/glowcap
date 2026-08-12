---
id: ADR-0040
status: accepted
date: 2026-06-10
tags: [architecture, build, modules, layering]
decision: Each `src/` layer is an internal build.zig module with an explicit one-way import table, so the layer DAG is compiler-enforced: a cross-layer reach is a compile error, not a review note. `src/root.zig` curates the one public `pancake` namespace over those modules, and `tools/check/arch_check.zig` retains only the content bans a module graph cannot express.
supersedes: []
superseded_by: []
---

# ADR-0040 Layer modules as import law

## Context

The layer DAG (docs/architecture.md § Layer Ownership) was enforced by
`tools/check/arch_check.zig` scanning `@import("…")` strings against an allowed-edge
table. That gate held the line, but it was a linter where the language offers a
law: it ran only inside `zig build check` (a plain `zig build test` admitted a
violation), it parsed text (a comptime-assembled import escaped it), and it
checked layer-to-layer edges only (a file inside an allowed layer could reach a
sibling layer's _internal_ file directly, bypassing that layer's `mod.zig`
surface). The project's own discipline: when a bolt-on solves what a
language-native organ could, use the organ: points at the build system's module
tables.

## Decision

- **One module per layer.** `build.zig` (§ Internal layer modules) creates an
  internal module for each top-level `src/` directory, rooted at its `mod.zig`,
  with an explicit `addImport` table. The table is the authoritative DAG; docs
  describe it and defer to it.
- **Tables carry the edges the code uses,** not the widest defensible allowance.
  A new cross-layer edge is a one-line, reviewable `build.zig` diff made
  deliberately. "explicit over implicit" applied to the architecture itself.
- **Violations are compile errors, both ways.** A layer naming a module outside
  its table fails `no module named '…'`; a relative path escaping the layer's
  directory fails `import of file outside module path`. Either fails every
  build, not only the gate.
- **One public namespace.** `src/root.zig` imports the layer modules and
  re-exports them as the `pancake` module: the only module consumers (tests,
  benches, examples, tools, the C ABI artifacts) see. Layer module names are
  internal vocabulary.
- **The core/adapters split is the graph's second level.** The sync, no-I/O core
  (`foundation`, `model`, `codec`, `session`, `engine`, `actors`) sits below
  `net`, `driver`, `conformance`, and `c_abi` in the same table: no separate
  mechanism.
- **`arch_check` keeps what modules cannot see.** Content bans stay in the gate:
  no `std.Io` / `std.Thread` / `std.atomic` in core (one sanctioned exception,
  ADR-0009), no platform syscall namespaces in portable code, and a loudness
  check that every top-level `src/` directory is declared: under a module graph
  an unwired directory is silently dead code, which is worse than a failing
  gate.

## Scope (what this does not decide)

- One `libpancake` artifact still ships; the modules are compilation structure,
  not packaging or versioning units.
  ([ADR-0059](ADR-0059-composable-c-abi-archives.md) supersedes this on
  packaging: the C ABI now ships as composable per-family archives,
  `libpancake_ocapn` and one per transport, with no single
  `libpancake` umbrella. The module-per-layer mechanism this ADR establishes is
  unchanged; it is the scaffolding the archive set is generated from.)
- Bindings and consumers are unaffected: the C ABI and the `pancake` Zig module
  are unchanged surfaces.

## Notes

The import inventory at the time of the split matched the documented DAG exactly
except one file-level reach (`engine` importing `foundation/crypto.zig`
directly), which the split normalized to `foundation.crypto`. Enforcement was
negative-tested in both failure modes before landing.

[ADR-0044](ADR-0044-ocapn-protocol-grouping.md) later groups the four protocol
layers (`model`, `codec`, `session`, `engine`) under `src/ocapn/`. The
module-per-layer mechanism is unchanged: the module names stay flat and the
import table is the same law; only the directories nest, and the arch gate's
`layerOf` descends through the `ocapn/` grouping to recover the layer name. So
"one module per top-level directory" reads as "one module per layer directory."

[ADR-0048](ADR-0048-codec-sibling-isolation.md) extends the same mechanism below
the codec layer: each sibling wire codec is its own module, so codecs cannot
import each other and only the codec root knows both.

The DAG is now written once, as the `layer_table` declaration in build.zig:
every build graph (host, cross-compile library, sans-io core) is generated from
it, and `tools/check/arch_check.zig` consumes the same table to verify that every
granted edge is actually imported by some file in its layer: so "tables carry
the edges the code uses" is a gate failure, not a review habit.
