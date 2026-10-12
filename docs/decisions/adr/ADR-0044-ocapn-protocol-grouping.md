---
id: ADR-0044
status: accepted
date: 2026-06-11
tags: [architecture, build, modules, layering, naming]
decision: "The four layers that are the OCapN/CapTP protocol (model, codec, session, engine) live under src/ocapn/ and are reached as glowcap.ocapn.<layer>, so both the tree and the public namespace say which layers are the protocol and which are built on top of it."
supersedes: []
superseded_by: []
---

# ADR-0044 OCapN protocol grouping

## Context

`src/` held ten flat layer directories in dependency order (ADR-0040), which
does not say which layers are the OCapN/CapTP protocol and which are built on
top of it. `model`, `codec`, `session`, and `engine` are the protocol. `actors`
is a Goblins-shaped framework that adds no CapTP semantics, `net` is the I/O
machinery, and `driver`/`c_abi` are surfaces. The four protocol layers are a
contiguous block in the DAG, so they group without reordering anything.

## Decision

The four protocol layers move under `src/ocapn/`. `src/ocapn/model`,
`src/ocapn/codec`, `src/ocapn/session`, `src/ocapn/engine`, and `src/root.zig`
nests them under one public namespace, so a consumer reaches
`glowcap.ocapn.engine.Peer`, `glowcap.ocapn.model.Message`, and so on. The tree
and the public API both show that these four are the protocol and everything
else adds none.

The name is `ocapn` because these layers carry OCapN concepts beyond classic
CapTP (locators, URIs, sturdyrefs, three-party handoff). `foundation` stays at
the top level as the substrate beneath the protocol. `actors`, `net`, `driver`,
`c_abi`, and `conformance` stay flat as the framework, I/O, and surfaces above
it. Their core/adapter boundary is already compiler-enforced (the `std.Io` ban
in the core), so a grouping folder there would add a level and no law.

The move is structural only. The build module names stay flat
(`@import("engine")` is unchanged), so every internal cross-layer import is
untouched (ADR-0040). Only `build.zig`'s path strings, the
`glowcap.ocapn.<layer>` access in tests and examples, the arch gate's `layerOf`
(which now descends through `ocapn/` to recover the layer name), the doc/rule
path references, and the docs change. The netlayer contract stays in `net` with
its tcp/loop implementation, because it is the seam to transports, not protocol
core. `ocapn/` is the protocol core, not every OCapN concept.

## Scope (what this does not decide)

`net`, `driver`, `c_abi`, and `conformance` are not grouped under an `adapters/`
umbrella, since that boundary is already enforced. The public namespace stays
flat for everything outside `ocapn/` (`glowcap.actors`, `glowcap.net`, …). No
layer is renamed and no import edge changes.

## Alternatives Considered

- **Keep ten flat directories.** Rejected: it is correct as a DAG but does not show the
  protocol boundary.
- **`captp/` instead of `ocapn/`.** Rejected: it under-names the OCapN concepts
  beyond CapTP (locators, URIs, sturdyrefs, handoff) those layers carry.
- **Also group `net`/`driver`/`c_abi` under `adapters/`.** Rejected: the
  core/adapter line is already a compile-enforced law, so the folder adds no
  guarantee, and it would lump I/O infrastructure with surfaces.

## Consequences

- The tree and `glowcap.ocapn.*` both name the protocol explicitly. The "adds no
  protocol" claims for `actors`/`driver`/`c_abi` are structural.
- `tools/check/arch_check.zig` `layerOf` descends through `ocapn/`, so the no-I/O-core
  bans still key on the real layer name (`engine`, not `ocapn`). `known_layers`
  and `core_layers` are unchanged.
- Internal imports are untouched (flat module names), so a miswire is a compile
  error, as ADR-0040 guarantees.
- Doc and rule path references and the rule-frontmatter globs move with the
  files.

## Notes

Refines [ADR-0040](ADR-0040-layer-modules-as-import-law.md) (module-per-layer
import law). The mechanism is unchanged, only the protocol layers' directories
nest.
