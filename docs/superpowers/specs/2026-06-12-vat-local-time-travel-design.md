# Vat local time-travel (snapshot / restore) — design

Role: a design spec for a not-yet-built feature. Not a living-state surface; it
describes a proposed shape, not the current code. When the feature lands, the
living-state claims move into the `vat.zig` module header and the tests, and this
file becomes a historical record.

## Goal

Give a pancake `Vat` the same time-travel that Spritely Goblins demonstrates in
its tutorial: freeze the current state of the vat's local objects into a value
you can keep, and later restore that value to bring those objects back to how
they were. In Goblins this is `snapshot-whactormap` plus `hasheq->whactormap`
(`conformance/spritely-goblins/upstream/goblins/core.rkt:734` and `:739`); the
tutorial's "Time travel: snapshotting and restoring" section
(`.../scribblings/tutorial.scrbl:1286`) keeps several snapshots of a `lunchbox`
cell and revisits each.

The one intended difference from Goblins is deliberate and is the whole point of
the design: Goblins copies every object automatically because Racket is
garbage-collected and its behaviors are immutable values, so its runtime can copy
anything safely. pancake has explicit ownership and no GC, so it cannot safely
copy an arbitrary actor's state on its own. pancake's time-travel is therefore
**opt-in per actor**: an actor that wants to be snapshottable writes a `clone`
method, exactly as it already optionally writes a `deinit`. Goblins is automatic
for all; pancake is pay-for-what-you-rewind, with the cost visible at the actor
boundary. That asymmetry is consistent with the rest of pancake (no hidden
runtime, explicit allocation), not a compromise against Goblins.

## Verified foundation (read from code, not prose)

These were checked by reading the source during the design conversation. They are
the load-bearing facts the design rests on; the runtime proof comes with the
tests the feature ships.

- **Time-travel is local-only, in Goblins and pancake alike.** A Goblins snapshot
  copies *only* the actormap's object-reference-to-behavior hash
  (`snapshot-whactormap`, `core.rkt:734`). The CapTP connection's
  import/export/question/answer tables and position counters are separate mutable
  cells inside the connection closure (`ocapn/captp.rkt:376-387`), never actormap
  entries, so a snapshot cannot capture them and a restore cannot rewind a remote
  peer. This spec inherits that boundary rather than fighting it.
- **The vat cannot copy an actor's state by itself.** A `Cell` holds an opaque
  `state: *anyopaque`, a `handle`, and a `destroy` — and nothing else, not even
  the state's size (`src/actors/vat.zig:216`). A blind byte-copy would be wrong
  for any actor that owns heap memory (it would alias, then double-free). So a
  per-actor `clone` is required, not optional-for-convenience.
- **An optional method is already discovered at spawn by comptime.** `Vat.spawn`
  builds a `Glue` whose `destroy` does `if (@hasDecl(Behavior, "deinit"))`
  (`vat.zig:270-274`). A `clone` is discovered the identical way, entirely inside
  `vat.zig`.
- **The driver forwards `spawn` generically.** `driver.spawnAt` passes
  `comptime Behavior` straight through to `vat.spawn` and never names `Cell` or
  its function pointers (`src/driver/mod.zig:766`). Adding a `clone` pointer to
  `Cell` therefore changes no signature the driver depends on.
- **`model` already exports every clone primitive an actor's `clone` would call.**
  `cloneArgument`, `cloneReference`, `cloneArgumentSlice`, and the rest live in
  `src/ocapn/model/owned.zig`, and `vat.zig` already imports `model`. No new
  cross-layer import, so the actor-layer import law (ADR-0040) is satisfied.

## The design

### 1. The opt-in actor contract

An actor becomes snapshottable by adding one method alongside its `handle` (and
its optional `deinit`):

```zig
pub fn clone(self: *const @This(), allocator: std.mem.Allocator) std.mem.Allocator.Error!*@This()
```

`clone` returns a freshly allocated deep copy of the actor's state: a copy that
shares no mutable storage with the original, so the two can diverge. An actor
whose state is plain data copies its fields; an actor that owns sub-allocations
(say a stored `model.Argument`) deep-copies them with the existing `model.clone*`
helpers. The actor owns this method the same way it owns `deinit`, which keeps
the "how do I copy this exact type" knowledge where the type is known and out of
the vat's type-erased core.

An actor that does not define `clone` stays exactly as it is today and simply is
not snapshottable. Existing actors in examples and tests compile unchanged.

### 2. The `Cell` gains a nullable clone pointer

```zig
const Cell = struct {
    state: *anyopaque,
    handle: ...,
    destroy: ...,
    clone: ?*const fn (state: *anyopaque, allocator: std.mem.Allocator) std.mem.Allocator.Error!*anyopaque = null,
};
```

`spawn`'s `Glue` sets `clone` to a wrapper around `Behavior.clone` when
`@hasDecl(Behavior, "clone")`, and leaves it null otherwise. The pointer is
nullable so that a vat holding even one non-cloneable actor fails loud at snapshot
time rather than silently dropping that actor from the snapshot.

### 3. What a snapshot captures, and when

A snapshot is only coherent when the vat is **quiescent**: no turn in flight
(`turn_depth == 0`), no queued sends (`queue.items.len == 0`), and no nested drive
(`drive_depth == 0`). At quiescence the only state that defines "where the local
objects are" is the actor table and the id counter. So a snapshot captures:

- a deep clone of every entry in `actors` (each cell's `state` via its `clone`),
  carrying the same `handle` / `destroy` / `clone` pointers; and
- `next_actor`, so objects spawned after a restore never reuse a live id.

A snapshot deliberately does **not** capture, and a restore does not touch:

- `peer`, `exports`, `far_listeners` — the wire. These are out of scope by the
  verified boundary above. For a pure-local vat they are empty anyway.
- `turn_arena`, `queue_arena`, `queue`, `listeners`, `turn_depth`, `drive_depth`
  — transient turn machinery, empty or irrelevant at quiescence.

### 4. The two new `Vat` methods

```zig
pub fn snapshot(self: *Vat) Error!Snapshot
pub fn restore(self: *Vat, snap: *const Snapshot) Error!void
```

- `snapshot` checks quiescence (else `error.NotQuiescent`), then walks `actors`
  and clones each state. If any cell's `clone` is null it returns
  `error.NotSnapshottable` after freeing whatever it already cloned. On success it
  returns a `Snapshot` that owns its cloned cells and a copy of `next_actor`.
- `restore` checks quiescence, then rebuilds the live `actors` table by cloning
  *from the snapshot* (not moving), freeing each displaced live state through its
  `destroy`, and sets `next_actor` from the snapshot. Cloning from the snapshot
  keeps the snapshot reusable, so one snapshot can be restored repeatedly — the
  Goblins property of revisiting an old revision many times.

`restore` swaps the local object states in place and leaves the vat's identity
(its peer binding, its arenas) intact. This is the systems-shaped analog of
Goblins building a fresh working actormap from a snapshot: same objects rewound,
same vat still running.

### 5. The `Snapshot` value

```zig
pub const Snapshot = struct {
    actors: std.AutoHashMapUnmanaged(u64, Cell),
    next_actor: u64,
    pub fn deinit(self: *Snapshot, allocator: std.mem.Allocator) void { ... }
};
```

A `Snapshot` owns its cloned states. `deinit` frees each through its `destroy`. A
caller may hold several snapshots at once and restore any of them, matching the
tutorial's two-snapshot demonstration.

## Memory posture (named, not hidden)

This is opt-in, off the wire path, and not a violation of the copy budget — but it
is honest about its cost. A snapshot is a deep copy of all participating live
state, allocated on the vat allocator (not a turn arena, because a snapshot
outlives turns). Its size is O(total cloned actor state), and unlike Goblins it
gets no structural sharing — pancake copies bytes where Racket shares immutable
structure. The cost is bounded by the application's own choice of which actors
opt in and how often it snapshots. The vat allocator owns every cloned state and
frees it in `Snapshot.deinit` or when `restore` displaces it, so the testing
allocator's leak detector is the gate that this ownership is complete.

This keeps the feature consistent with the actor layer's contract (ADR-0036): the
vat stays sync and no-I/O, snapshot/restore enqueue nothing and read no wire, and
the feature adds no CapTP semantics the engine lacks.

## Test plan (`test/actors`)

A new test file proves the behavior and the ownership:

- snapshot, mutate an actor via a near-call, restore, and observe the actor back
  at its pre-mutation state — the core round-trip;
- keep two snapshots across two mutations and confirm each restores its own
  revision independently (the tutorial's exact shape);
- restore the same snapshot twice to prove a snapshot is reusable;
- a vat containing a non-cloneable actor returns `error.NotSnapshottable` and
  leaks nothing;
- `snapshot` / `restore` called mid-turn return `error.NotQuiescent`;
- a snapshot of an actor whose state owns a heap allocation (e.g. a stored
  `model.Argument`) deep-copies it, so mutating the live actor does not disturb
  the snapshot, and both free cleanly under the testing allocator.

The gate is `zig build test` (the `test/actors` suite, plus the allocator leak
checks). `zig build arch-check` confirms no new cross-layer import sneaks in.

## Build and doc obligations (same change)

- The `vat.zig` module header documents `clone`, `snapshot`, `restore`, and the
  quiescence and locality boundaries, in the doc-voice register.
- `test/api_surface_test.zig` covers the new public declarations automatically
  (it references every exported `pancake` symbol), so no manual registration.
- If a living-state doc inventories vat capabilities (for instance a vat section
  in `docs/capabilities.md` or `docs/shipped.md`), it gains a line for local
  time-travel and states the opt-in and local-only boundaries, per doc-drift.

## Explicitly out of scope (named boundaries, not omissions)

- **Any wire time-travel.** Verified impossible in Goblins and pancake alike: a
  snapshot never captures session/connection state and a restore never rewinds a
  remote peer. The design captures local actor state only.
- **Automatic / universal snapshotting.** pancake cannot copy an arbitrary
  type-erased state safely, so snapshottability is opt-in per actor. Matching
  Goblins's "every object, for free" would require a GC or a uniform copyable
  value model the library deliberately does not have.
- **Far refs as live capabilities across a restore.** A snapshot copies an
  actor's stored `Ref{.far}` as plain data, but the wire meaning of that
  capability is engine-owned, forward-only state the vat does not snapshot. A
  restored far ref is only as valid as the live session still makes it. The
  feature is therefore honest only for local object graphs; the docs say so.
- **Transactional rollback-on-error (Goblins's "as if the message never
  happened").** A related but distinct feature: run a turn against a copy and
  discard on failure. It shares the `clone` contract but adds turn-boundary
  machinery, and it has its own wire caveat (a far send is handed to the engine's
  outbound queue immediately, so it cannot be reverted from the vat). Worth a
  follow-on spec; not built here.
- **C ABI exposure.** This spec is the native Zig `Vat` surface. Surfacing
  snapshot/restore over the C ABI (and thus to the language bindings) is separate
  work with its own ownership vocabulary.

## Risks and how the design answers them

- **Silent partial snapshots.** Answered by the nullable `clone` pointer and the
  loud `error.NotSnapshottable`: a vat with a non-cloneable actor cannot produce a
  half-complete snapshot.
- **Mid-turn snapshots capturing inconsistent state.** Answered by the quiescence
  check and `error.NotQuiescent`.
- **Leaks from clone/restore ownership.** Answered by routing every clone through
  the vat allocator with a single owner, freed in `Snapshot.deinit` and on
  `restore` displacement, and gated by the testing allocator's leak detector.
- **A reader mistaking this for distributed rewind.** Answered by the module
  header and the out-of-scope section stating the local-only boundary in words.
