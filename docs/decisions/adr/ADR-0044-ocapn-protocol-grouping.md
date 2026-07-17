---
id: ADR-0044
status: accepted
date: 2026-06-11
tags: [architecture, build, modules, layering, naming]
decision: "The four layers that are the OCapN/CapTP protocol (model, codec, session, engine) live under src/ocapn/ and are reached as pancake.ocapn.<layer>, so both the tree and the public namespace say which layers are the protocol and which are built on top of it."
supersedes: []
superseded_by: []
---

# ADR-0044 OCapN protocol grouping

## Context

`src/` held ten flat layer directories. The flat list is the layer DAG in
dependency order (ADR-0040), and that is correct, but it does not say which
layers _are_ the OCapN/CapTP protocol and which are built on top of it. The
distinction is real and load-bearing: `model`, `codec`, `session`, and `engine`
are the protocol; `actors` is a Goblins-shaped framework that explicitly adds no
CapTP semantics, `net` is the I/O machinery, and `driver`/`c_abi` are surfaces.
The README and `root.zig` narrate this in prose, but neither the tree nor the
public namespace showed it. The four protocol layers are also a _contiguous_
block in the DAG, so they group cleanly without reordering anything.

## Decision

The four protocol layers move under `src/ocapn/`. `src/ocapn/model`,
`src/ocapn/codec`, `src/ocapn/session`, `src/ocapn/engine`: and `src/root.zig`
nests them under one public namespace, so a consumer reaches
`pancake.ocapn.engine.Peer`, `pancake.ocapn.model.Message`, and so on. The tree
and the public API now tell the same story: these four are the protocol,
everything else adds none.

The naming is `ocapn`, not `captp`, because these layers carry OCapN concepts
beyond classic CapTP (locators, URIs, sturdyrefs, three-party handoff) so
`captp` would under-name them. `foundation` stays at the top level as the
substrate beneath the protocol; `actors`, `net`, `driver`, `c_abi`, and
`conformance` stay flat as the framework, I/O, and surfaces above it. Their
core/adapter boundary is already compiler-enforced (the `std.Io` ban in the
core), so a grouping folder there would add a level without adding a law.

The move is structural only. The build module _names_ stay flat
(`@import("engine")` is unchanged), so every internal cross-layer import is
untouched (ADR-0040); only `build.zig`'s path strings, the
`pancake.ocapn.<layer>` access in tests and examples, the arch gate's `layerOf`
(which now descends through `ocapn/` to recover the layer name), the doc/rule
path references, and the docs change. One OCapN concept: the netlayer contract
stays in `net` with its tcp/loop implementation, because it is the seam _to_
transports, not protocol core; so `ocapn/` is "the protocol core," not "every
byte of OCapN."

## Scope (what this does not decide)

`net`, `driver`, `c_abi`, and `conformance` are not grouped under an `adapters/`
umbrella: that boundary is already enforced and narrated, and the folder would
not add a law. The public namespace stays flat for everything outside `ocapn/`
(`pancake.actors`, `pancake.net`, …). No layer is renamed and no import edge
changes.

## Alternatives Considered

- **Keep ten flat directories.** Rejected: correct as a DAG, but silent about
  the protocol-vs-built-on-top boundary the codebase actually has.
- **`captp/` instead of `ocapn/`.** Rejected: under-names the OCapN-beyond-CapTP
  concepts (locators, URIs, sturdyrefs, handoff) those layers carry.
- **Also group `net`/`driver`/`c_abi` under `adapters/`.** Rejected: the
  core/adapter line is already a compile-enforced law, so the folder is cost
  without a new guarantee, and it would lump I/O infrastructure with surfaces.

## Consequences

- The tree and `pancake.ocapn.*` both name the protocol explicitly; the "adds no
  protocol" claims for `actors`/`driver`/`c_abi` are now structural, not just
  documented.
- `tools/check/arch_check.zig` `layerOf` descends through `ocapn/`, so the no-I/O-core
  bans still key on the real layer name (`engine`, not `ocapn`). `known_layers`
  and `core_layers` are unchanged.
- Internal imports are untouched (flat module names), so the move could not
  silently break an edge: a miswire is a compile error, as ADR-0040 guarantees.
- Doc and rule path references and the rule-frontmatter globs move with the
  files.

## Notes

Refines [ADR-0040](ADR-0040-layer-modules-as-import-law.md) (module-per-layer
import law); the mechanism is unchanged, only the protocol layers' directories
nest.
