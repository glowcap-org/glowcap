---
id: ADR-0012
status: accepted
date: 2026-05-10
tags: [model, session, engine, sturdyref, enliven, equality, goblins, interop]
decision: A sturdyref is a `Reference.sturdy` arm carrying `SturdyRef { peer, swissnum }` with structural equality on `(peer, swissnum)`. A `sturdyref` feature gate makes a sturdyref-bearing payload on a non-negotiated session a loud refusal, and enlivenment rides the existing bootstrap-fetch behind a feature+open precondition, a per-session dedup cache (swissnum to `(import_id, kind)`) that short-circuits a repeat enliven with no wire traffic, and an in-flight marker that collapses a concurrent enliven onto the outstanding answer.
supersedes: []
superseded_by: []
amends: []
amended_by: [ADR-0098]
---

# ADR-0012 Sturdyref shape and enliven substrate

## Context

A sturdyref is a persistent locator for an object that may outlive its current
session: the OCapN `Locators.md` describes it as a capability obtainable "with
this information alone," and Goblins enlivens one by looking up the location,
reusing the open session, and asking that session's bootstrap for the
swiss-number. Enlivenment is a thin orchestration over the bootstrap-fetch substrate
([ADR-0006](ADR-0006-handshake-substrate-and-bootstrap-fetch.md)), plus the
model shape a sturdyref decodes to and the gate that keeps it off a session that
did not ask for it.

## Decision

### Typed shape and equality

A sturdyref is structured, not opaque bytes.
[`src/ocapn/model/mod.zig`](../../../src/ocapn/model/mod.zig) carries it as a
`Reference.sturdy` arm over

```zig
pub const SturdyRef = struct { peer: PeerLocator, swissnum: []const u8 };
```

reusing the same `PeerLocator` that `op:start-session` and the handoff
descriptors carry. Equality is structural:
[`src/ocapn/model/equality.zig`](../../../src/ocapn/model/equality.zig)
`referencesStructurallyEqual` compares the `.sturdy` arm field-wise:
`peerLocatorsEqual` over the locator and byte-equality on `swissnum`. Because
it is structural on the codec-neutral value tree, two sturdyrefs naming the same
target compare equal whichever codec or Syrup profile carried them.

OCapN `Locators.md` (§ Peer object) states that "the designator and transport
are the only pieces of information which need to match", so two peer locators
with the same designator and transport but different hints are the same peer.
`peerLocatorsEqual` compares `(transport, designator)` only, and sturdyref
equality is `(transport, designator, swissnum)`. Hints are connection advice,
not identity.

### The `sturdyref` feature gate

Both reference-validation paths in
[`src/ocapn/session/mod.zig`](../../../src/ocapn/session/mod.zig) refuse a
`Reference.sturdy` with `Error.FeatureNotNegotiated` when the session did not
negotiate `FeatureSet.sturdyref`, on inbound decode and outbound encode alike.
`FeatureSet.full()` turns `sturdyref` on. The handshake `intersect` reduces the
negotiated set to what both peers advertised.

### Enliven over bootstrap-fetch

[`src/ocapn/engine/sturdyref.zig`](../../../src/ocapn/engine/sturdyref.zig) adds
only the enliven-specific halves the sync core owns. The wire loop belongs to
the adapter, as for the bootstrap-fetch it rides.

- **Precondition.** `checkEnlivenPreconditions` requires the session to have
  negotiated `FeatureSet.sturdyref` (`Error.SturdyrefsNotNegotiated`) and to be
  `open` (`Error.SessionNotOpen`). Whether `sturdyref.peer` names this session's
  remote is a dial/adapter concern: the core tracks no remote locator and does not
  dial.
- **Dedup.** `prepareEnliven` resolves to one of three starts. A cache hit
  (`sturdyrefCacheHit`) rebuilds the cached `Reference.far`: kind preserved per
  [ADR-0010](ADR-0010-payload-descriptor-discriminator.md), with no wire
  traffic. An in-flight match (`pendingEnlivenAnswer`) collapses a concurrent
  enliven for the same swiss-number onto the outstanding answer id. A miss
  issues a fresh bootstrap-fetch and records the in-flight marker
  (`notePendingEnliven`), releasing every allocation if the marker cannot be
  recorded.
- **Settle.** `recordEnlivenment` clears the in-flight marker, then caches
  `(import_id, kind)` on a `fulfilled(Reference.far)` and returns the live
  reference. A non-`far` fulfillment, a `break`, or a malformed settlement
  releases any owned payload and fails with `Error.EnlivenmentBroke`.

Host attaches concurrent callers to one fetch through
[`enliven/group.zig`](../../../src/driver/core/enliven/group.zig). Each caller
owns a separate vow and capability retain. Cancellation detaches that caller.
The last pending observer cancels the listener and clears the in-flight marker.
One reserved answer-release carrier survives settlement while public handles
still permit pipelining, and retires with the last handle. Owned callers consume
the result directly. An in-process vow listener borrows it during its callback.

The dedup state lives on the session
([`src/ocapn/session/mod.zig`](../../../src/ocapn/session/mod.zig)):
`cacheSturdyrefEnlivenment` / `sturdyrefImportFor` / `sturdyrefKindFor` over a
swissnum to `(import_id, kind)` cache, and `notePendingEnliven` /
`finishPendingEnliven` over the in-flight markers. A miss costs one extra
round-trip and no correctness, so the cache is bounded by
`SessionLimits.max_sturdyref_cache_entries` and evicts the oldest entry on
overflow.

### Session-local reuse and Host enrollment

Host CapTP enrollment posture (not a CapTP `FeatureSet` bit) keeps three facts
distinct. The verified
`op:start-session` signature proves control of a fresh session key. The signed
hello also carries the partner's locator claim, but that signature does not
prove control of the durable key or address named by its designator. Only proof
from the realized channel authenticates that durable identity (ADR-0097,
ADR-0105, ADR-0109).

The Host indexes a durable peer for session reuse only when the channel supplied
that proof. An unauthenticated locator claim, including a key-shaped claim from
raw keyed TCP or keyed relay, cannot condemn or replace another session. A
dialed locator still supplies an exact target check, but an expectation is not
reported as authentication. Crossed hellos match the inbound locator claim
against the outstanding dial target where the protocol requires that race to be
resolved, then order the two connections by their distinct session identifiers.
The tiebreak does not treat locator equality as durable-key proof.

`referencesStructurallyEqual` compares `(import_id, kind)` only within one
session. The sturdyref dedup cache reuses that row for repeated enlivenment on
the same session, and the sturdyref scenario proves that an ordinary deliver of
the same export also lands on that row. Neither mechanism identifies a target
that returns through an arbitrary other session, and the scenario does not
execute a handoff. Full OCapN Pass Invariant Equality for targets therefore
remains unproved. No wire field carries equality.

## Scope (what this does not decide)

- **Sturdyref withdrawal.** There is no sturdyref-revocation channel. The
  `(peer, swissnum)` shape is unsigned and irrevocable. (Handoff-gift withdrawal
  is unrelated handoff state,
  [ADR-0009](ADR-0009-three-party-handoff-substrate.md).)
- **Locator-URI interchange at the session waist.** `model.uri` parses
  `ocapn://…/s/<swiss-num>` (and peer URIs) for adapters and the C ABI. The
  CapTP session / enliven core still consumes the in-band `SturdyRef`
  (`peer` + `swissnum`), not a URI string at the waist.
- **Dial-on-enliven.** Enliven requires an already-open session. Opening one on
  miss is a dial/transport concern outside the no-I/O core.

## Alternatives Considered

- **Opaque-bytes sturdyref with lazy parse.** Rejected: two structurally equal
  sturdyrefs would compare unequal once each codec chose its own byte layout,
  breaking codec-neutral semantics.
- **A `Value`-level sturdyref arm.** Rejected: a sturdyref is authority-bearing
  (it enlivens to a live reference) so it belongs on `Reference`, alongside
  near/far/promise.
- **Per-adapter enliven orchestration.** Rejected: the sequence (precondition,
  dedup, fetch, settle) is identical everywhere, and centralizing it in the core
  lets scenarios exercise it without a transport.

## Consequences

- The model carries `SturdyRef { peer, swissnum }` as `Reference.sturdy`.
  `referencesStructurallyEqual` compares it structurally.
- The session refuses a sturdyref on a non-negotiated session
  (`Error.FeatureNotNegotiated`) and owns the dedup cache and in-flight markers.
- `src/ocapn/engine/sturdyref.zig` exposes the precondition / prepare / settle
  halves. The adapter drives the wire loop, as for bootstrap-fetch.
- Enliven happy-path, cache-hit short-circuit, in-flight collapse, and the
  not-negotiated / broken refusals are conformance-bearing scenarios.

## Forward compatibility

A future signed sturdyref grows additively as a wrapped Syrup record on the
`v1_0` profile, mirroring the handoff signature-envelope pattern. The `next`
profile refuses the extended form via the feature flag. The unsigned
`(peer, swissnum)` shape and its structural equality are the substrate the
session-local dedup sidecar uses.

## Notes

[ADR-0003](ADR-0003-codec-interoperability-posture.md) owns the profile posture
the sturdyref record sits inside. The shape is profile-uniform.
[ADR-0006](ADR-0006-handshake-substrate-and-bootstrap-fetch.md) is the
bootstrap-fetch substrate enliven composes on, unchanged.
[ADR-0010](ADR-0010-payload-descriptor-discriminator.md) settles the
`(import_id, kind)` discriminator the cache preserves. 
