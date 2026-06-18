---
id: ADR-0012
status: accepted
date: 2026-05-10
tags: [model, session, engine, sturdyref, enliven, equality, goblins, interop]
decision: A sturdyref is a `Reference.sturdy` arm carrying `SturdyRef { peer, swissnum }` with structural equality on `(peer, swissnum)`; a `sturdyref` feature gate makes a sturdyref-bearing payload on a non-negotiated session a loud refusal; and enlivenment rides the existing bootstrap-fetch behind a feature+open precondition, a per-session dedup cache (swissnum → `(import_id, kind)`) that short-circuits a repeat enliven with no wire traffic, and an in-flight marker that collapses a concurrent enliven onto the outstanding answer.
supersedes: []
superseded_by: []
---

# ADR-0012 Sturdyref shape and enliven substrate

## Context

A sturdyref is a persistent locator for an object that may outlive its current
session: the OCapN `Locators.md` describes it as a capability obtainable "with
this information alone," and Goblins enlivens one by looking up the location,
reusing the open session, and asking that session's bootstrap for the
swiss-number. pancake already has the bootstrap-fetch substrate
([ADR-0006](ADR-0006-handshake-substrate-and-bootstrap-fetch.md)); enlivenment
is a thin orchestration over it, plus the model shape a sturdyref decodes to and
the gate that keeps it off a session that did not ask for it.

Engages the First Principles _session state is authoritative_ (the feature gate
and the dedup cache live on the session, not the codec), _conformance is
load-bearing_ (the shape and the enliven happy/sad paths are scenario-pinned),
and _fail loud rather than succeed wrong_ (a settlement that is not a live
`Reference.far` is refused, never surfaced as an unreachable reference).

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
`referencesEqual` compares the `.sturdy` arm field-wise — `peerLocatorsEqual`
over `(transport, designator, hints)` and byte-equality on `swissnum`. Because
it is structural on the codec-neutral value tree, two sturdyrefs naming the same
target compare equal regardless of which codec or Syrup profile carried them
(First Principle _codec-neutral semantics_).

**Amendment (2026-06-10).** The locator axis above over-counted. OCapN
`Locators.md` (§ Peer object) is explicit: "the designator and transport are the
only pieces of information which need to match" — two peer locators with the
same designator and transport but different hints are the same peer.
`peerLocatorsEqual` therefore compares `(transport, designator)` only, and
sturdyref equality is `(transport, designator, swissnum)`; hints are connection
advice, never identity.

### The `sturdyref` feature gate

`FeatureSet.sturdyref` is load-bearing, not advertised-and-ignored. Both
reference-validation paths in
[`src/ocapn/session/mod.zig`](../../../src/ocapn/session/mod.zig) refuse a
`Reference.sturdy` with `Error.FeatureNotNegotiated` when the session did not
negotiate the flag — on inbound decode and on outbound encode alike, so a peer
cannot smuggle a sturdyref across a session that never agreed to speak them.
`FeatureSet.fullExceptStreaming` turns `sturdyref` (and `equality`, consumed by
the Cross-session distributed equality section below) on; the handshake
`intersect` reduces the negotiated set to what both peers advertised.

### Enliven over bootstrap-fetch

[`src/ocapn/engine/sturdyref.zig`](../../../src/ocapn/engine/sturdyref.zig) adds
only the enliven-specific halves the sync core owns; the wire loop is an adapter
concern, exactly as for the bootstrap-fetch it rides.

- **Precondition.** `checkEnlivenPreconditions` requires the session to have
  negotiated `FeatureSet.sturdyref` (`Error.SturdyrefsNotNegotiated`) and to be
  `open` (`Error.SessionNotOpen`). Whether `sturdyref.peer` names this session's
  remote is a dial/adapter concern — the core tracks no remote locator and never
  dials.
- **Dedup.** `prepareEnliven` resolves to one of three starts. A cache hit
  (`sturdyrefCacheHit`) rebuilds the cached `Reference.far` — kind preserved per
  [ADR-0010](ADR-0010-payload-descriptor-discriminator.md) — with no wire
  traffic. An in-flight match (`pendingEnlivenAnswer`) collapses a concurrent
  enliven for the same swiss-number onto the outstanding answer id. A miss
  issues a fresh bootstrap-fetch and records the in-flight marker
  (`notePendingEnliven`), releasing every allocation if the marker cannot be
  recorded.
- **Settle.** `recordEnlivenment` clears the in-flight marker, then caches
  `(import_id, kind)` on a `fulfilled(Reference.far)` and returns the live
  reference. A non-`far` fulfillment, a `break`, or a malformed settlement
  releases any owned payload and fails with `Error.EnlivenmentBroke`.

The dedup state lives on the session
([`src/ocapn/session/mod.zig`](../../../src/ocapn/session/mod.zig)):
`cacheSturdyrefEnlivenment` / `sturdyrefImportFor` / `sturdyrefKindFor` over a
swissnum → `(import_id, kind)` cache, and `notePendingEnliven` /
`finishPendingEnliven` over the in-flight markers. The cache is non-load-bearing
— a miss costs one extra round-trip, never correctness — so it is bounded by
`SessionLimits.max_sturdyref_cache_entries` and evicts the oldest entry on
overflow rather than erroring.

### Cross-session distributed equality

This builds on the sturdyref dedup cache above. One session per peer pair is
enforced by a caller-held `SessionRegistry` keyed on `PeerId`, consulted at the
`negotiating → open` transition; a second open to a peer already held is a loud
`Error.PeerAlreadyOpen`. With that invariant, in-memory structural `Reference`
equality (`referencesEqual`) is the distributed-equality evidence for OCapN Pass
Invariant Equality: two references naming the same target compare equal on
`(import_id, kind)` regardless of which codec carried them, because the same
target always lands in the same import row. The sturdyref dedup cache above
supplies the sturdyref-vs-handoff collapse onto one import row. The `equality`
feature gate means "this peer commits to session-pair uniqueness." No new wire
field carries equality.

## Scope (what this does not decide)

- **Sturdyref withdrawal.** There is no sturdyref-revocation channel; the
  `(peer, swissnum)` shape is unsigned and irrevocable. (Handoff-gift withdrawal
  is unrelated handoff state,
  [ADR-0009](ADR-0009-three-party-handoff-substrate.md).)
- **Locator-URI parsing.** The `ocapn://…/s/<swiss-num>` URI form is not parsed;
  the core consumes the in-band Syrup record, not a URI string. URI interchange
  is an adapter concern.
- **Dial-on-enliven.** Enliven requires an already-open session; opening one on
  miss is a dial/transport concern outside the no-I/O core.

## Alternatives Considered

- **Opaque-bytes sturdyref with lazy parse.** Rejected: two sturdyrefs that
  should compare equal under Pass Invariant Equality would compare unequal once
  each codec chose its own byte layout, breaking codec-neutral semantics.
- **A `Value`-level sturdyref arm.** Rejected: a sturdyref is authority-bearing
  — it enlivens to a live reference — so it belongs on `Reference`, alongside
  near/far/promise.
- **Per-adapter enliven orchestration.** Rejected: the enliven story
  (precondition → dedup → fetch → settle) is identical everywhere; centralizing
  it in the core lets scenarios exercise it without a transport.

## Consequences

- The model carries `SturdyRef { peer, swissnum }` as `Reference.sturdy`;
  `referencesEqual` compares it structurally.
- The session refuses a sturdyref on a non-negotiated session
  (`Error.FeatureNotNegotiated`) and owns the dedup cache and in-flight markers.
- `src/ocapn/engine/sturdyref.zig` exposes the precondition / prepare / settle
  halves; the adapter drives the wire loop, as for bootstrap-fetch.
- Enliven happy-path, cache-hit short-circuit, in-flight collapse, and the
  not-negotiated / broken refusals are conformance-bearing scenarios.

## Forward compatibility

A future signed sturdyref grows additively as a wrapped Syrup record on the
`v1_0` profile, mirroring the handoff signature-envelope pattern; the `pre_spec`
profile refuses the extended form via the feature flag. The unsigned
`(peer, swissnum)` shape and its structural equality are the substrate the
Cross-session distributed equality section above binds its dedup sidecar to.

## Notes

[ADR-0003](ADR-0003-codec-interoperability-posture.md) owns the profile posture
the sturdyref record sits inside; the shape is profile-uniform across all cells.
[ADR-0006](ADR-0006-handshake-substrate-and-bootstrap-fetch.md) is the
bootstrap-fetch substrate enliven composes on, unchanged.
[ADR-0010](ADR-0010-payload-descriptor-discriminator.md) settles the
`(import_id, kind)` discriminator the cache preserves. The full project contract
is the [First Principles](../../../AGENTS.md#first-principles).
