---
id: ADR-0109
status: accepted
date: 2026-08-06
tags: [engine, driver, netlayer, locators, handoff, identity]
decision: "A peer owns complete advertised locator snapshots and selects one acceptable location independently of a session's transport. Every hello signs that selection, and handoff uses the exporter's signed claim. Locator hints carry routing or profile data, never a session identity credential."
supersedes: []
superseded_by: []
amends: [ADR-0079, ADR-0093, ADR-0097, ADR-0105]
amended_by: [ADR-0113]
---

# ADR-0109 A peer owns its advertised locators

## Context

An OCapN locator names the peer it describes. The same value appears as this
peer's `acceptable-location` in `op:start-session` and as an exporter's location
in three-party handoff.

Assembling that value at several call sites lets dial and accept advertise
different hints for the same peer while a handoff reconstructs a third value.
With iroh, an accepted session that omits `direct-addresses` leaves a third
party with no address to dial when reachability is disabled.

A connection-specific credential such as `session-key-attestation` does not
belong in a locator: hints are not part of locator identity in OCapN and
Goblins does not need the credential. Authenticated-channel realizers can prove
the durable endpoint. Raw keyed TCP and keyed relay cannot, and a static
signature in a hello does not make their cleartext byte channel authenticated.

## Decision

### The node stores the published value

`engine.Node` owns one complete `model.PeerLocator` snapshot per transport.
The map key is derived from `locator.transport`. Callers cannot supply a second
transport string that could disagree with the value.

The node also selects one retained snapshot as its current
`acceptable-location`. A peer may reach the room over TCP while asking other
peers to reach it through keyed relay, WebRTC, iroh, Onion, or a deployment
proxy. The selected locator describes the peer's route. It does not describe
the byte channel carrying the current session.

The mutation contract:

- Setting a locator deep-copies the transport, designator, and hints, then
  selects that snapshot.
- Preparing a missing dial fallback retains it without displacing an existing
  selection, and selects it only when the node has none.
- Replacement is transactional. Allocation or validation failure leaves the
  old locator and selection intact. A successful replacement releases the old
  allocation.
- Removing the selected locator leaves no selection. The node does not choose
  another route by map iteration order.
- A getter returns a borrowed locator valid until that transport is replaced or
  removed, or until the node is deinitialized.

The node stores data but performs no I/O. A native netlayer adapter publishes
its locator after bind and replaces it when reachability changes. A byte-fed
embedder uses the same host setter because it owns transport realization.
Listener-derived reachability is a default, not policy: a deployment may
replace the complete locator with a proxy, ingress, externally mapped address,
or another route peers should dial.

### One selected snapshot serves every protocol use

Every dialed and accepted hello reads the node's selected locator, regardless
of the current session transport. A session retains the partner's signed
locator claim. When that partner later becomes an exporter, handoff embeds the
retained claim instead of rebuilding it from the current channel or an
application registration argument.

Profile offers are peer configuration and are part of the stored snapshot.
A routing update creates a new snapshot for subsequent hellos and gifts and
leaves an established session's signed hello unchanged.

### Hints contain no session credential

`session-key-attestation` does not exist in the model, codec, engine, public
ABI, bindings, fixtures, or documentation. Every CapTP session uses a fresh
signing key, and the ordinary `acceptable-location` signature verifies the
session signer and the integrity of its locator claim. It does not authenticate
durable ownership of the claimed designator, and no second signature has a
durable key authorize the session key through a locator hint.

Durable identity provenance has two outcomes:

- `authenticated_transport`: the code that realized the end-to-end channel
  proved its far-end key, bound that proof to the session, and the partner
  claimed that same key.
- `unauthenticated`: no matching channel proof exists.

When the selected locator uses a key designator, a dial that named a key still
requires the same claim. An address locator is an independent proxy or ingress
route and makes no claim about the current channel's target. Raw `keyed-tcp`
and `keyed-relay` therefore trust their netlayer to honor the dial target. iroh
and WebRTC realizers bind their authenticated remote as channel evidence. The
Noise_XK channel in ADR-0107 does the same for byte pipes: its authenticated,
integrity-protected channel binds the CapTP hello and fresh session key to the
durable peers, so another signature would add no proof.

### Partner identity reports three facts

`PartnerIdentity.session_key` is verified by the ordinary hello signature.
`designator` and `locator_record` are the locator claim that verified session
signer made. They are signed, but they are not authenticated durable identity by
themselves. `provenance` reports whether the realized channel independently
proved the same durable key. `designatorIsSessionKey` is a literal diagnostic.
Neither equality nor a key-form designator is an authentication predicate.

### Goblins locator indexing

Goblins indexes an open exporter session by the complete locator, including
hints. That is inconsistent with its hint-insensitive node equality and the
OCapN locator identity rule, and glowcap's architecture does not follow the
defect.

The production Goblins Onion locator is stable: `(onion, service-id, #f)`.
There is no changing hint to mismatch. In glowcap, `direct-addresses` changes
only when an iroh deployment without reachability publishes new direct routes,
which creates a new locator snapshot for subsequent sessions. glowcap passes
through the hints it uses and adds no session-only field that guarantees a
mismatch.

## Consequences

- A peer has one authority for retained routes and one explicit selection.
- The selected route is independent of the current session transport.
- Dial, accept, and handoff cannot drift by construction.
- Locator replacement has owned memory and a testable lifetime contract.
- Onion interoperation uses the Goblins-native hint-less locator.
- Raw keyed transports make no authentication claim they cannot support.
- Authenticated channels and Noise need no duplicate hello credential.

The host setter retains and selects a complete locator. Automatic dial
preparation adds a fallback without replacing that selection. The native
Server publishes its listener-derived locator and exposes a same-transport
replacement for deployment routing. Per-session open functions carry only the
channel transport and no local locator fragments.

## Alternatives considered

**Keep a session credential in hints.** Rejected because it is not an OCapN or
Goblins convention, changes every session's locator value, duplicates real
channel authentication, and still does not authenticate a cleartext channel.

**Let each driver half assemble a locator.** Rejected because dial, accept, and
handoff can then disagree about one peer-owned fact.

**Work around Goblins by stripping or sorting hints.** Rejected because hint
order is canonicalized for signatures, and altering a peer's locator to satisfy
an upstream full-value lookup would advertise a value the peer did not publish.

## Evidence

- Node tests cover deep copy, transactional replacement, removal, borrowed
  getter lifetime, explicit selection, fallback preparation, and deriving the
  map key from `locator.transport`. Peer and Host tests preserve multi-entry
  caller hint maps while adding the configured profile offer.
- Driver tests prove a TCP dial and accept both sign a selected keyed-relay
  locator. Browser relay and WebRTC room tests then redeem that signed route
  through handoff. A keyed-TCP server test replaces the listener default with
  a proxy route and proves later sessions advertise the replacement.
- Keyed TCP and keyed relay report `unauthenticated`. iroh and WebRTC report
  `authenticated_transport` only when their realizer supplied channel proof.
- `zig build goblins-gift-hints` holds a generic mapping-shaped hint round trip
  against live Goblins without assigning authentication meaning to the hint.
- `zig build goblins-rooms-dm`, `zig build goblins-rooms-dm-iroh`,
  `zig build oracle-check`, `zig build check-external`, and `zig build check`
  cover the protocol, foreign-peer, and project checks.

## Notes

This record keeps ADR-0097's fresh per-session signing keys and removes its
durable-key credential. It keeps ADR-0105's connection-scoped provenance and
removes the credential branch. ADR-0107's Noise design provides the channel
proof this record requires.
