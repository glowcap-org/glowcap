---
id: ADR-0060
status: accepted
date: 2026-06-13
tags: [actors, vat, time-travel, snapshot, memory]
decision: "The Vat gains opt-in, local-only time-travel. Actor state moves behind a non-atomic refcounted StateBox. Vat.snapshot shares state pointers (O(objects), no byte copy) and Vat.restore swaps them back, both only at quiescence. Mutable actors opt in with a `clone` method and are copied-on-write before a shared turn runs. Persistent actors opt in with `snapshot_persistent` plus Turn.become and need no copy-on-write. Off by default: a non-snapshotting actor's box stays refs==1 and pays only one indirection per turn."
supersedes: []
superseded_by: []
amends: []
amended_by: [ADR-0096, ADR-0101, ADR-0191]
---

# ADR-0060 Vat local time-travel

## Context

Goblins supports time-travel: `snapshot-whactormap`
(`conformance/spritely-goblins/upstream/goblins/core.rkt:734`) copies the
actormap spine and shares behavior values by reference, and `hasheq->whactormap`
restores an old revision. That is safe in Goblins only because behaviors are
immutable and the runtime is garbage-collected.

glowcap's `Vat` (ADR-0036) made the opposite state choice: an actor's mutable
`self` is its state, copied by nothing. That is why glowcap pays no per-turn
immutability tax and runs no GC, but a snapshot cannot simply share a live state
pointer, because a later in-place mutation would corrupt it. This ADR decides how
the vat gains local time-travel without a hidden runtime or a default-path cost.

This is a local-actor-layer decision with no CapTP semantics. Every copy is
opt-in, named, and off the default path.

## Decision

Actor state in [`src/actors/vat/mod.zig`](../../../src/actors/vat/mod.zig) moves behind
a heap-allocated `StateBox` carrying the state pointer, a non-atomic reference
count, the behavior's `handle`/`destroy`/`clone` function pointers, and a
`persistent` flag. A `Cell` becomes a single `*StateBox`. The reference count is
non-atomic because a vat is single-threaded, and the shared values cannot form
cycles (a box never points at another box), so a plain count suffices with no
collector.

- **`Vat.snapshot`** requires quiescence (`turn_depth == 0`, `drive_depth == 0`,
  empty queue, else `NotQuiescent`) and shares every actor's box pointer,
  incrementing each refcount. It copies no state bytes: O(objects), like
  Goblins's spine copy. A box that is neither cloneable nor persistent fails the
  snapshot with `NotSnapshottable`.
- **`Vat.restore`** requires quiescence, builds the new actor table by sharing
  the snapshot's boxes (refcount up) before releasing the live boxes, so a
  failure leaves the live table intact, and the snapshot stays reusable across
  repeated restores. It captures local actor state only, never `peer`,
  `exports`, `far_listeners`, or the turn arenas.

  A restore leaves the actor-id counter alone. An id is what the export table
  maps a wire position to, and that table is not local state. Rewinding only the
  counter would let the next spawn take an id a live export still names, so a
  partner's capability would reach an object it was never granted. A monotonic
  counter costs only reproducible ids across repeated restores, which nothing
  depends on.
- **Mutable actors (tier 2).** An actor that defines
  `pub fn clone(self, allocator)` is copied-on-write: `ensureUnshared` runs at
  the top of `callLocal` and the `serve` deliver path and, if the box is shared
  (`refs > 1`) and not persistent, deep-clones the state into a fresh box before
  the handler can mutate it. A snapshot copies nothing. The first turn against a
  shared actor pays one clone.
- **Persistent actors (tier 3).** An actor that declares
  `pub const snapshot_persistent = true;` does not mutate `self`. It produces
  its next state with `Turn.become`. The vat stages the new value in the running
  `Turn` and installs it when that turn frame returns successfully, releasing
  the old live box. A handler error discards the staged value. Because the value
  is never mutated in place, `ensureUnshared` skips persistent boxes, so
  snapshots are pure pointer-sharing with no copy-on-write.

When no snapshot is outstanding every box has
`refs == 1`, `ensureUnshared` returns immediately, and the only standing cost is
one pointer indirection (`Cell` to `box` to `ptr`) and one branch per turn.

## Scope (what this does not decide)

- **No wire time-travel.** A snapshot captures no session state and a restore
  rewinds no remote peer. Far references in restored state are copied as data.
  Their wire meaning is engine-owned and forward-only, so snapshot/restore
  applies to local object graphs only.
- **No hard refuse on a peer-bound vat.** A peer-bound vat may hold purely-local
  actors worth rewinding, so snapshot/restore are permitted there. The far-ref
  caveat is documented, not enforced.
- **No general transactional turns.** `become`'s discard-on-error is the only
  state rollback shaped here. ADR-0191 makes a turn's local sends commit with
  it. A general "run a mutable turn against a copy and discard
  on failure" is not implemented.
- **No C ABI exposure.** This is the native Zig `Vat` surface. Surfacing
  snapshot/restore over the C ABI is separate work.

## Alternatives Considered

- **Eager deep-copy snapshot.** Rejected: O(total mutable bytes) per snapshot.
- **Immutable-everything plus GC, like Goblins.** Rejected: it allocates per
  become, needs a collector on every turn, and taxes actors that never
  snapshot.
- **Immediate (non-deferred) become.** Rejected: it loses the discard-on-error
  property, which per-`Turn` staging gives at the same cost.
- **Hard-refuse snapshot/restore on a peer-bound vat.** Rejected: it would
  forbid rewinding local actors that share a vat with the wire.

## Consequences

`src/actors/vat/mod.zig` is organized around `StateBox`: `Cell`, `spawn`,
`callLocal`, `serve`, and `deinit` route through the box. `snapshot`, `restore`,
`Snapshot`, and `Turn.become` exist, with `NotQuiescent` and `NotSnapshottable`
in the `Error` set. `test/actors` covers snapshot/restore, copy-on-write, and
functional become. The memory rule
([`.agents/rules/memory.md`](../../../.agents/rules/memory.md)) names the box
sharing, the COW clone, and the become allocation. `engine`, `model`, and
`driver` are unaffected: `driver.spawnAt` forwards the comptime behavior
generically.

## Notes

Builds on [ADR-0036](ADR-0036-actor-layer.md). The persistent map that makes a
persistent actor's incremental `become` cheap is decided separately in
[ADR-0061](ADR-0061-persistent-collections-module.md).
