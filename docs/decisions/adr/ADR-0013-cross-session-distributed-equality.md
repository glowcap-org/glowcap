---
id: ADR-0013
status: accepted
date: 2026-05-11
tags: [session, runtime, equality, registry, sturdyref, peerid, goblins, interop]
decision: One session per peer pair is enforced by a caller-held `SessionRegistry` keyed on `PeerId`, consulted at the `negotiating → open` transition; a second open is a loud `Error.PeerAlreadyOpen`. With that invariant, in-memory structural `Reference` equality (`referencesEqual`) is the distributed-equality evidence for OCapN Pass Invariant Equality — two references naming the same target compare equal on `(import_id, kind)` regardless of codec — and the sturdyref dedup cache supplies the sturdyref-vs-handoff collapse onto one import row. The `equality` feature gate means "this peer commits to session-pair uniqueness." No new wire field carries equality.
supersedes: []
superseded_by: []
---

# ADR-0013 Cross-session distributed-equality evidence

## Context

OCapN's `Model.md` gives targets Pass Invariant Equality: a target sent to a peer and sent back compares equal to the original and to no other value. `CapTP Specification.md` names the strategy — only one active session should exist between two peers, so equality checks against a remote peer's objects are well-defined. Reduce to that invariant and cross-session equality becomes same-session equality: the same target always lands at the same import row, so two references to it compare equal.

Two gaps stand between that property and the code. There is no session-pair-uniqueness enforcement, so two sessions to one peer would give a target two import ids and two unequal references. And a sturdyref-enlivened far-ref and a handoff-introduced far-ref for the same target have no defined relationship. This ADR closes both.

Engages the First Principles *session state is authoritative* (the registry and the dedup cache are session/runtime state), *codec-neutral semantics* (equality on `Reference` means the same thing across every codec and profile), *conformance is load-bearing* (the collapse and the duplicate-refusal are scenarios), and *pancake is not OCapN* — the equality "evidence" is an in-memory assertion, never a new wire field.

## Decision

### Session-pair uniqueness in `SessionRegistry`

[`src/runtime/registry.zig`](../../../src/runtime/registry.zig) holds a `SessionRegistry` — a set of [`foundation.PeerId`](../../../src/foundation/id.zig) (a fixed 32-byte id compared with `eql`). `register` returns `Error.PeerAlreadyOpen` when an entry for that `PeerId` already exists; `unregister` and `contains` round out the surface. The registry is **caller-held**, mirroring the cross-peer posture: the adapter threads it through and consults it at the `negotiating → open` transition (`register` on open, `unregister` on close), never the session state machine itself, which stays a passive observer. A peer that negotiated `equality = false` opts out — the adapter simply does not consult the registry for that session.

### Structural `Reference` equality is the evidence

There is no wire field. [`src/model/equality.zig`](../../../src/model/equality.zig) `referencesEqual` is the whole of the distributed-equality evidence: two `Reference.far` values compare equal on `(import_id, kind)` (the wire-kind discriminator participates per [ADR-0010](ADR-0010-payload-descriptor-discriminator.md)), and conformance asserts that property on the values the session tables hold. Once one-session-per-peer holds, the same partner target always installs at one import id, so the structural predicate *is* Pass Invariant Equality for target references.

### Sturdyref dedup supplies the sturdyref-vs-handoff collapse

The per-session dedup cache from [ADR-0012](ADR-0012-sturdyref-shape-and-enliven.md) (swissnum → `(import_id, kind)`) is what makes multiple paths to one target reduce to a single import row. When a sturdyref is enlivened to a `Reference.far`, the cache records `(import_id, kind)`; a later enliven of the same swiss-number on the same session returns that same far-ref. Combined with session-pair uniqueness, an enlivened far-ref and a handoff-introduced far-ref for the same target land on the same import id and compare equal under `referencesEqual` — without any cross-export identity token pancake would have to invent, which would either extend OCapN or rely on identity the partner has no obligation to preserve.

### The `equality` feature gate

`FeatureSet.equality` is load-bearing: a peer advertising it commits to session-pair uniqueness — a future inbound session from a peer it already has open will be refused with `Error.PeerAlreadyOpen`. A peer negotiating `equality = false` permits multiple sessions per peer and forgoes the collapse property; the `intersect` arm reduces the negotiated set to what both peers advertised. No separate error variant gates the flag; the registry consult is simply skipped when it is off.

## Scope (what this does not decide)

- **Container-type value-tree equality.** `referencesEqual` settles target (`Reference.*`) equality; Pass Invariant Equality over List / Set / Tagged value-tree shapes is a separate value-tree concern — [ADR-0021](ADR-0021-ocapn-value-tree-breadth.md). (`argumentsEqual` provides a structural substrate, but the container semantics are not settled here.)
- **Cross-process registries.** `SessionRegistry` is in-process; one logical identity spanning multiple processes must coordinate registration externally.
- **Transport-side crossed-hellos tie-break.** The registry refuses the second registration synchronously; which side wins when two peers dial each other at once is a transport concern with no Zig netlayer today.

## Alternatives Considered

- **No enforcement; each composition root self-polices.** Rejected: the spec makes one-session-per-peer load-bearing for equality, and the `equality` flag would mean nothing if no layer held the invariant.
- **A cross-export identity token for import-table dedup.** Rejected: the token either extends OCapN or is a pancake-internal identity the partner need not preserve. The partner owns dedup; the same `import_id` is the only axis, with sturdyref enlivenment as the one path where pancake locally knows the swiss-number.
- **An out-of-band equality-evidence wire arm.** Rejected: it would extend OCapN and improve nothing the in-memory equality already expresses.

## Consequences

- `src/runtime/registry.zig` carries `SessionRegistry` with `register` / `unregister` / `contains` and `Error.PeerAlreadyOpen`; the adapter consults it at `negotiating → open`.
- `referencesEqual` is the conformance-bearing equality predicate; the sturdyref cache from [ADR-0012](ADR-0012-sturdyref-shape-and-enliven.md) supplies the collapse.
- `FeatureSet.equality` carries the session-pair-uniqueness commitment; `stage3Default` turns it on.
- Same-session far-ref equality, the cross-session sturdyref-and-handoff collapse to one far-ref, and the second-session refusal are conformance scenarios.

## Forward compatibility

A future `lookup` helper on `SessionRegistry` (retrieving an in-flight session by `PeerId`) is additive over the duplicate-detection surface. When a production netlayer lands, the registry is the consult point a transport-side crossed-hellos tie-break feeds back into: the losing side `unregister`s and retreats. Container-type Pass Invariant Equality ([ADR-0021](ADR-0021-ocapn-value-tree-breadth.md)) composes on the same in-memory `referencesEqual` substrate, with `Reference.*` arms reducing to the contract settled here.

## Notes

[ADR-0006](ADR-0006-handshake-substrate-and-bootstrap-fetch.md) drives the `negotiating → open` transition the registry consults. [ADR-0009](ADR-0009-three-party-handoff-substrate.md) is the path the collapse scenario's handoff branch travels. [ADR-0012](ADR-0012-sturdyref-shape-and-enliven.md) is the typed sturdyref and dedup cache this ADR's collapse binds to. The full project contract is the [First Principles](../../../AGENTS.md#first-principles).
