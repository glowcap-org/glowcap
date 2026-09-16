---
id: ADR-0061
status: accepted
date: 2026-06-13
tags: [actors, persistent, collections, layer, memory]
decision: "Keep the immutable PersistentMap in Loam's dependency-free collections leaf, with non-atomic reference-counted nodes and path-copy updates for actor snapshots."
supersedes: []
superseded_by: []
amended_by: [ADR-0162]
---

# ADR-0061 Persistent collections module

## Context

Functional `become` (ADR-0060) lets a persistent actor produce its next state
without mutating in place, which is what makes its snapshots pure
pointer-sharing. But if the actor rebuilds its whole state value every turn,
`become` is O(size), losing the cheap _incremental_ mutation Goblins gets from
Racket's persistent data structures. To make `become` O(log n) with structural
sharing: and to back the map-shaped benchmark apps (registry, mint/purse, task
board): glowcap needs a persistent immutable map.

The risk this engages is scope: glowcap is "a native Zig OCapN/CapTP substrate,"
and a collections library is the part of the time-travel work that most
stretches that. This ADR settles the containment so the addition holds the
vision line rather than trading it for a general-purpose library nobody asked
the substrate to own.

## Decision

The leaf layer [`src/loam/collections/`](../../../src/loam/collections/) provides a single
`PersistentMap`: a hash array mapped trie with path-copy updates and non-atomic
refcounted nodes. An update shares every untouched subtree with the prior
version, so a persistent actor that stores its state in it gets O(log n)
`become` and structural sharing with prior versions and with any outstanding
snapshot. Non-atomic refcounts suffice for the same reasons as ADR-0060: the vat
is single-threaded and the immutable trie is acyclic.

Containment is the decision as much as the structure:

- It is a **sharp leaf module**, not a general collections package: one
  `PersistentMap`, no persistent vector or set (those are follow-on work, not
  built here).
- It supports actor snapshots through `glowcap.loam.collections.PersistentMap`.
  Direct internal consumers import `loam_collections`. Both paths use the same
  leaf; neither requires a store, a backend, or managed resource state.
- It **imports nothing from the protocol layers**. It is a `core` layer in
  build.zig's `layer_table` with an empty import set, so the actor-layer import
  law (ADR-0040) is untouched and `arch-check`, the architecture rule layer
  list, and [`docs/architecture.md`](../../../docs/architecture.md) gain the
  module in the same change.

## Scope (what this does not decide)

- **No general collections library.** Only the map exists. A persistent vector,
  set, or ordered map is not implemented.
- **Not required by the vat itself.** The Vat does not import `loam_collections`;
  functional `become` works with any state type. The map only makes a large
  persistent actor's `become` cheap.

## Alternatives Considered

- **Put the map in `foundation`.** Rejected: `foundation` owns bytes, IDs, and
  frame ownership; a persistent map is the wrong semantic neighbor and would
  blur that module's responsibility.
- **Skip it; rebuild actor state each `become`.** Rejected: O(size) `become`
  loses the incremental cheapness that is the whole point of tier 3, and the
  benchmark could not show parity with Goblins's structural sharing.

## Consequences

The `src/loam/collections/` module owns the `PersistentMap` implementation.
Its `core` row in build.zig's `layer_table` enforces the dependency-free boundary.
`test/loam/collections` proves structural sharing across updates,
refcount correctness, no cycles, and leak-freedom under the testing allocator.
The memory rule gains a load-bearing-allocation entry for the refcounted trie
nodes. No protocol-layer source changes.

## Notes

Supports [ADR-0060](ADR-0060-vat-local-time-travel.md). Placement obeys the
layer import law of [ADR-0040](ADR-0040-layer-modules-as-import-law.md).
