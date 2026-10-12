---
id: ADR-0071
status: superseded
date: 2026-07-08
tags: [actors, c-abi, bindings, api, architecture]
decision: "The actor layer (`actors.Vat`) is sans-io, yet each of the four language bindings reimplements it over the sans-io peer, which is why they diverge (narrower handler contracts, per-binding drift, and resource guards (the loop-host amplification cap) that exist only in Zig. Rather than keep four actor runtimes, glowcap exposes the one Zig vat as an opt-in composable C ABI archive, `libglowcap_actors` (the ADR-0059 archive model), so every binding shares one implementation and wraps it idiomatically instead of rebuilding it. A consumer hosts a *foreign* actor by handing the vat an opaque `ctx` and an imperative behavior callback `(ctx, turn, verb, args) -> reply | forward`, the `turn` is the full `Turn`, so a foreign actor sends and spawns exactly like a native Zig actor. The actor's state lives in the consumer's language) foreign-owned, mutated in place (so vat-owned time-travel (`snapshot`/`restore`, functional `become`) does not extend to foreign actors: a vat holding one is not snapshottable, because the vat cannot clone state it does not own. The Zig core gains this as `Vat.spawnHosted`: a `StateBox` with a callback `handle`, an optional caller `free`, and no `clone`, so the existing snapshot guard already refuses it (`NotSnapshottable`) with no new machinery. It lands in increments) (1) the Zig `spawnHosted` foundation with tests, (2) the `libglowcap_actors` archive with its header and a C-ABI test, (3) the four bindings rewired onto the shared vat, retiring their reimplementations: and the sans-io peer stays the minimal protocol boundary the archive sits above."
supersedes: []
superseded_by: [ADR-0072]
---

# ADR-0071 The actor layer is exposed as an opt-in C ABI archive

> **Scope of supersession.**
> Superseded by [ADR-0072](ADR-0072-driver-tier-over-c-abi.md). The
> `libglowcap_actors` archive this record proposed does not exist. A binding
> reaches the shared actor layer through `libglowcap_host`, so there is one host
> tier and no bare vat beside it. This record's foundation stands,
> `Vat.spawnHosted` and `HostedActor`: an embedder hosts a foreign actor by
> handing the vat an opaque context and a behavior callback that receives the
> full `Turn`, and a vat holding one is refused a snapshot. ADR-0072 consumes
> that contract.

## Context

`actors.Vat` is a sans-io layer above the engine: spawn, near-call, eventual-send,
drive, vows, snapshot. The C ABI ships only the sans-io *peer* (ADR-0036), so
each binding builds its own vat over that peer in its own language. Four
reimplementations diverge: the bindings' hosted-actor handler is
`(verb, args) -> value | Forward` with no `Turn`, so a foreign handler cannot
eventual-send or spawn the way a Zig handler can, and a resource guard added to
the Zig loop host (the local-turn amplification cap) has no binding equivalent
because there is no shared place to put it.

Sans-io logic belongs in the shared core, and adapters own only I/O and
scheduling, so four bindings each reimplementing a sans-io actor runtime is the
anomaly. The peer is the protocol. The vat is optional sugar that every consumer
wants, which is the signal to share it.

## Decision

Expose the one Zig vat through a new opt-in composable C ABI archive,
`libglowcap_actors`, above `libglowcap_ocapn` (the ADR-0059 archive model). A
consumer hosts a **foreign actor** by giving the vat an opaque `ctx` and an
imperative behavior callback `(ctx, turn, verb, args) -> reply | forward`. The
`turn` is the full `Turn`, so a foreign actor sends and spawns like a native one.

The Zig core gains `Vat.spawnHosted(HostedActor)`, building a `StateBox` whose
`ptr` is the foreign box, whose `handle` calls the consumer's callback, whose
`drop` calls the consumer's `free`, and whose `clone` is `null`. Delivery,
`drive`, `send`, and `on` treat it like any other box.

State is foreign-owned and mutable in place, so time-travel does not extend to
foreign actors: `clone == null` makes `snapshot` return `NotSnapshottable` (the
existing guard), and copy-on-write no-ops on a null clone.

Rollout is incremental: (1) `spawnHosted` in the Zig core, tested. (2) the
`libglowcap_actors` archive, its generated header, and a C-ABI test. (3) the
four bindings rewired onto the shared vat, retiring their reimplementations.

## Scope (what this does not decide)

- The vat/turn C names and struct layouts, settled when the archive lands
  (increment 2).
- Snapshot/time-travel for foreign actors. A functional (`bcom`) contract could
  add it without changing this one.
- The sans-io peer boundary is unchanged. The archive sits above it and a
  consumer that wants only the protocol does not link it.

## Alternatives Considered

- **Functional `bcom` contract** (`(ctx, verb, args) -> (next_ctx, reply)`, the
  Goblins shape): the vat holds foreign state handles, so snapshot works. Richer
  but heavier: the consumer must let the vat retain and free its state objects.
  Foreign state is mutable in place, and the imperative `Turn` gives full
  send/spawn, so the mutable-self contract is the smaller sufficient step.
- **Keep four reimplementations**: rejected, since the divergence is the problem
  this record addresses.

## Consequences

- One actor runtime, tested and conformance-checked once, instead of four.
- Foreign actors have full eventual-send and spawn. The binding actor layers
  are thin idiomatic veneers over the shared vat.
- A vat that hosts a foreign actor cannot snapshot. Zig-native actors keep
  time-travel. A mixed vat forfeits it loudly (`NotSnapshottable`).
- The C ABI has one opt-in archive. The peer archive stays minimal, so a
  consumer that does not want glowcap's actor model pays nothing.

## Forward compatibility

A functional `bcom` behavior contract can be a second foreign-actor shape if
snapshottable foreign actors are wanted, without disturbing the imperative
one.

## Notes

Increment 1 is `Vat.spawnHosted` plus tests: a foreign actor answers a call,
sends to a co-hosted actor through its `turn`, and makes the vat report
`NotSnapshottable`.

[ADR-0072](ADR-0072-driver-tier-over-c-abi.md) supersedes this ADR. A binding
reaches the vat through the `libglowcap_driver` archive (the host tier over the
C ABI), which hosts published actors through increment 1's `Vat.spawnHosted`
contract. No network-free local-vat consumer exists, so the increment-2 archive
(`libglowcap_actors`, `glowcap_actors.h`, and its header and test machinery) is
not built. The Zig `actors` module is unchanged.
