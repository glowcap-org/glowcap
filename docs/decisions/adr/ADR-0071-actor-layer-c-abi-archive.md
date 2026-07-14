---
id: ADR-0071
status: accepted
date: 2026-07-08
tags: [actors, c-abi, bindings, api, architecture]
decision: "The actor layer (`actors.Vat`) is sans-io, yet each of the four language bindings reimplements it over the sans-io peer, which is why they diverge — narrower handler contracts, per-binding drift, and resource guards (the loop-host amplification cap) that exist only in Zig. Rather than keep four actor runtimes, pancake exposes the one Zig vat as an opt-in composable C ABI archive, `libpancake_actors` (the ADR-0059 archive model), so every binding shares one implementation and wraps it idiomatically instead of rebuilding it. A consumer hosts a *foreign* actor by handing the vat an opaque `ctx` and an imperative behavior callback `(ctx, turn, verb, args) -> reply | forward`; the `turn` is the full `Turn`, so a foreign actor sends and spawns exactly like a native Zig actor. The actor's state lives in the consumer's language — foreign-owned, mutated in place — so vat-owned time-travel (`snapshot`/`restore`, functional `become`) does not extend to foreign actors: a vat holding one is not snapshottable, because the vat cannot clone state it does not own. The Zig core gains this as `Vat.spawnHosted`: a `StateBox` with a callback `handle`, an optional caller `free`, and no `clone`, so the existing snapshot guard already refuses it (`NotSnapshottable`) with no new machinery. It lands in increments — (1) the Zig `spawnHosted` foundation with tests, (2) the `libpancake_actors` archive with its header and a C-ABI test, (3) the four bindings rewired onto the shared vat, retiring their reimplementations — and the sans-io peer stays the minimal protocol boundary the archive sits above."
supersedes: []
superseded_by: [ADR-0072]
---

# ADR-0071 The actor layer is exposed as an opt-in C ABI archive

## Context

`actors.Vat` is a sans-io layer above the engine: spawn, near-call, eventual-send,
drive, vows, snapshot. The C ABI ships only the sans-io *peer* (ADR-0036), so
each binding builds its own vat over that peer in its own language. Four
reimplementations is why they diverge: the bindings' hosted-actor handler is
`(verb, args) -> value | Forward` with no `Turn`, so a foreign handler cannot
eventual-send or spawn the way a Zig handler can, and a resource guard added to
the Zig loop host (the local-turn amplification cap) has no binding equivalent
because there is no shared place to put it.

pancake's own principle is that sans-io logic belongs in the shared core and
adapters own only I/O and scheduling. By that principle, four bindings each
reimplementing a sans-io actor runtime is the anomaly. The peer is the protocol;
the vat is optional sugar — but every consumer wants the sugar and rebuilds it,
which is the signal to share it.

## Decision

Expose the one Zig vat through a new opt-in composable C ABI archive,
`libpancake_actors`, above `libpancake_ocapn` (the ADR-0059 archive model). A
consumer hosts a **foreign actor** by giving the vat an opaque `ctx` and an
imperative behavior callback `(ctx, turn, verb, args) -> reply | forward`. The
`turn` is the full `Turn`, so a foreign actor sends and spawns like a native one.

The Zig core gains `Vat.spawnHosted(HostedActor)`, building a `StateBox` whose
`ptr` is the foreign box, whose `handle` calls the consumer's callback, whose
`drop` calls the consumer's `free`, and whose `clone` is `null`. Delivery,
`drive`, `send`, and `on` treat it like any other box.

State is foreign-owned and mutable in place, so **time-travel does not extend to
foreign actors**: `clone == null` means `snapshot` already returns
`NotSnapshottable` (the existing guard), and copy-on-write already no-ops on a
null clone. No new machinery.

Rollout is incremental: (1) `spawnHosted` in the Zig core, tested; (2) the
`libpancake_actors` archive, its generated header, and a C-ABI test; (3) the
four bindings rewired onto the shared vat, retiring their reimplementations.

## Scope (what this does not decide)

- The exact vat/turn C names and struct layouts —
  settled when the archive lands (increment 2).
- Snapshot/time-travel for foreign actors — deliberately out for now; a
  functional (`bcom`) contract could add it later without changing this one.
- The sans-io peer boundary is unchanged; the archive sits above it and a
  consumer that wants only the protocol never links it.

## Alternatives Considered

- **Functional `bcom` contract** (`(ctx, verb, args) -> (next_ctx, reply)`, the
  Goblins shape): the vat holds foreign state handles, so snapshot works. Richer
  but heavier — the consumer must let the vat retain and free its state objects.
  Foreign state is naturally mutable-in-place, and the imperative `Turn` already
  gives full send/spawn, so the mutable-self contract is the smaller, sufficient
  step. `bcom` stays available as a forward option (see above).
- **Keep four reimplementations**: the status quo, and the divergence it causes
  is the problem this record exists to end.

## Consequences

- One actor runtime, tested and conformance-checked once, instead of four.
- Foreign actors gain full eventual-send and spawn; the binding actor layers
  shrink toward thin idiomatic veneers over the shared vat.
- A vat that hosts a foreign actor cannot snapshot. Zig-native actors keep
  time-travel; a mixed vat forfeits it, loud (`NotSnapshottable`).
- The C ABI grows by one opt-in archive; the peer archive stays minimal, so a
  consumer that does not want pancake's actor model pays nothing.

## Forward compatibility

A functional `bcom` behavior contract can be added as a second foreign-actor
shape if snapshottable foreign actors are ever wanted, without disturbing the
imperative one this record establishes.

## Notes

Increment 1 (this record's first code) is `Vat.spawnHosted` plus tests: a
foreign actor answers a call, sends to a co-hosted actor through its `turn`, and
makes the vat report `NotSnapshottable`.

[ADR-0072](ADR-0072-driver-tier-over-c-abi.md) supersedes this ADR. A binding
reaches the vat through the `libpancake_driver` archive (the host tier over the
C ABI), which hosts published actors through increment 1's `Vat.spawnHosted`
contract, so no binding ever rewired onto the bare archive of increment 2.

## Amendment (2026-07-10)

The retirement condition fired: no network-free local-vat consumer emerged, and
the `libpancake_driver` archive hosts published actors from C through the
increment-1 `Vat.spawnHosted` contract directly, making a standalone bare-vat
archive redundant by construction. The increment-2 C archive
(`libpancake_actors`, `pancake_actors.h`, the actors family and its
header/test machinery) is removed. Increment 1 — `Vat.spawnHosted` and the
foreign-actor contract — stands, consumed by the driver tier; the Zig `actors`
module is untouched. See ADR-0072's matching amendment.
