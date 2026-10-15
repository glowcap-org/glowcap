---
id: ADR-0069
status: accepted
date: 2026-07-07
tags: [engine, node, handoff, three-party, routing, gc, api]
decision: "A fetched or redeemed foreign capability is identified across sessions by a node-unique `CapabilityRouteId`, never by a wire import position. `Reference.routed` carries that identity until the Node lowers it at the owning session."
supersedes: []
superseded_by: []
amends: []
amended_by: [ADR-0079, ADR-0091, ADR-0096, ADR-0113, ADR-0116, ADR-0234]
---

# ADR-0069 Foreign capabilities have Node-owned route identities

## Context

CapTP import positions are session-local. Two partners may both introduce
`far(7)` while naming unrelated capabilities. A Host-wide table keyed only by
the import position therefore aliases those capabilities and can route a later
send or re-gift to the wrong exporter.

The application cannot repair that ambiguity. Once it holds only `far(7)`, the
session that gave the reference is the missing fact. Carrying the
home session in every binding would duplicate a protocol identity decision and
make language adapters authoritative for routing.

Glowcap also creates a local capability identity when a three-party handoff is
redeemed. It must route to the exporter session and must not become a wire
import on an unrelated session.

## Decision

`engine.Node` assigns a monotonic `CapabilityRouteId` and stores:

```text
CapabilityRouteId -> { home PeerHandle, real session-scoped Reference }
```

Application- and Host-owned semantic values carry the id in the explicit
`Reference.routed` arm. A routed reference is not a `FarRef`, and no magnitude
test converts between them. Every `u64` remains available to a peer as an
`ImportPosition` (ADR-0091).

The Node owns both route families:

- `foreign_imports` enrolls a fetched import and keeps the id on the live
  session import row as its generation proof
- `redeemed` owns the temporary route produced by a completed handoff until the
  Host adopts it into opaque capability identity

An enrollment is prepared before publication. A fresh foreign-import route
carries rollback authority, so allocation or admission failure removes the map
row and import-row memo before the caller observes the reference. Ids are not
reused after rollback or retirement.

### One lowering authority

`Peer.send` calls the Node lowering hook before encoding every outbound
message. The hook:

- returns ordinary wire references unchanged
- replaces a routed reference with its real wire reference only on its home
  session
- returns `RouteNotLowerable` everywhere else

Codecs reject `Reference.routed`. Bypassing the Node therefore fails closed, and
target, argument, nested value, and resolution emission follow one rule.

Two Host decisions sit above lowering because they may choose a different
session:

- a send target routes to its recorded home before the message enters that
  Peer
- a capability returned to a third session becomes a signed give (or a
  promise proxy) using the real exporter-side reference

Bindings receive opaque Host capabilities and do not inspect
`CapabilityRouteId`, `PeerHandle`, or import positions.

### Lifetime and GC

The session import row is the generation authority for a fetched route. The row
stores its current `CapabilityRouteId`. Releasing and reusing the same wire
position cannot revive the previous identity. `removePeer` reclaims all routes
homed on that peer, and later use fails with `CapabilityRouteUnavailable`.

When Host GC releases a fetched capability, it resolves the opaque capability
to `{home session, ImportPosition}`, emits `op:gc-exports` there, and retires
the route after the final import retain disappears. Partial releases keep both
the import and route live.

## Consequences

- Equal wire positions on different sessions never alias.
- A stale route cannot acquire a later meaning.
- No routed identity can leak onto the wire. The codec is a backstop, not the
  policy owner.
- Ordinary two-party references take one union-tag branch and no map lookup.
  Routed references use the existing Node map. The representation adds no
  allocation or copy to frame processing.
- Routing and handoff policy live once in Zig. C and language bindings remain
  lifecycle, value, and runtime adapters.

## Evidence

Recurring Node and Host scenarios prove:

- identical import positions on two sessions route to their respective homes
- same-home lowering emits the original wire position and cross-home lowering
  fails closed
- prepared enrollment rolls back without publishing authority
- partial/final GC and position reuse preserve generation safety
- object re-gift and promise proxy paths use the same route identity
- old high-band boundaries and `maxInt(u64)` remain valid wire imports

The live Goblins handoff/gift matrix proves the resulting wire behavior. It is
not the authority for the internal route representation.

## Rejected alternatives

- **Key by import position.** Positions are session-local and collide.
- **Key by `{PeerHandle, ImportPosition}` while exposing only `far(position)`.** The
  caller no longer has the home `PeerHandle` when routing is needed.
- **Reserve a numeric import band.** This rejects valid OCapN input and lets a
  local identity masquerade as a wire reference.
- **Store home identity in each binding.** This duplicates routing semantics
  and makes adapters disagree about capability identity and GC.
