---
id: ADR-0125
status: accepted
date: 2026-08-24
tags: [locators, netlayer, negotiation, handoff, pancake-next, upstream]
decision: "pancake multi-homing has one product shape: an id locator names a durable public key, ordered via routes form a bounded key-proving race, alt-locators carries serial handoff-only weak fallbacks, and the comparison-only pancake/locations vocabulary is removed."
supersedes: [ADR-0119]
superseded_by: []
amends: []
amended_by: []
---

# ADR-0125 Identity-route multi-homing

## Context

ADR-0119 required two candidate shapes to produce the same measurement. The
[completed comparison](../../planning/multihome-shape-comparison.md) found that
only the identity-route shape could answer the capability-semantic question:
which fact makes several routes one peer? Its outer durable key is that fact,
and authenticated channels can prove it. The `pancake/locations` candidate
carried a list but supplied no same-peer proof, drove no dial, supported no
sturdyref, and had no product consumer.

Keeping an inert candidate in a release would violate one-authority-per-fact
and make the supported vocabulary larger without making the product more
capable. The OCapN and Goblins baseline remains the conformance floor; neither
private shape is presented as upstream behavior.

## Decision

Ship one `pancake-next` multi-home shape. An `id` locator's designator is the
peer's durable public key. Its required `via` hint contains bounded carrier
locators whose channels must prove that same key. Optional `alt-locators` are
weak fallbacks authorized only for the handoff that carried them. The existing
`multi_location` feature bit admits this vocabulary per session.

Route order is explicit policy, not an incidental parser result. The identity
owner ranks routes by their position in `via`; Node admits the first two as a
bounded race and replenishes that window in source order as attempts fail. The
first admitted route to complete with the required proof wins. Only after every
strong route fails does Node admit `alt-locators`, one at a time and in their
declared order. Thus the publisher can express preference without a hidden
transport table, while the receiver still benefits from latency competition
and cannot let a weak route outrank identity proof.

The limit of two is part of the scheduling contract: it avoids head-of-line
delay from a single path while bounding physical attempts, cancellation state,
and binding tasks per logical dial. Route indices stay stable across DIAL,
CANCEL_DIAL, and completion calls; they are attempt identity as well as rank.

Remove all special meaning for `pancake/locations`. It is not a reserved
tombstone: unknown hints retain the ordinary OCapN hint behavior, while no
pancake layer parses that name, strips it, treats it as route vocabulary, or
claims it reaches the same peer.

## Scope (what this does not decide)

- The `id` and `via` names remain a pancake-private extension until OCapN
  specifies a compatible shape.
- The generic physical-session dial planner continues to reject `id`; Node's
  pending-dial owner expands the bundle before any transport is selected.
- Listener discovery and publication policy remain application-owned.
- The core assigns no built-in weight to iroh, relay, onion, TCP, or any other
  transport. A library consumer controls published preference by ordering the
  locator it authors; receiver-local transport policy remains outside the
  signed route statement rather than silently rewriting its rank.

## Alternatives Considered

- **Keep both names until upstream decides**: rejected because the second name
  had no usable semantics to evaluate or support.
- **Make the locator list dialable without an outer identity**: rejected because
  routing advice cannot establish that several authenticated or
  unauthenticated endpoints are one capability peer.
- **Add an identity field to the locator list**: rejected because that rebuilds
  the `id` locator with a more diffuse authority boundary.

## Consequences

`model.route_bundle` owns the one bounded route grammar. `session.id_route`
owns key agreement between the outer identity and strong routes. Session
validation gates `id` locators on the negotiated feature; Node owns expansion,
bounded racing, retry, winner cancellation, caching, and weak-fallback scope.
Handoff lowering continues to prevent private vocabulary from reaching
baseline peers. Bindings execute exact `(ticket, route_index)` attempts and
close late losing sessions; they do not duplicate route semantics.

The retired hint branches and refusal-only tests are deleted. Documentation
describes a capability that works rather than a comparison that never became
symmetrical.

## Evidence and gate

The route-bundle model tests hold count, byte, nesting, and same-key limits.
Pairing tests hold first-hello silence and bilateral feature admission. Node and
Core Host tests hold route expansion, authenticated identity, retry, cache
discipline, declared-order admission, bounded strong-route racing, serial weak
fallback, winner cancellation, late completion refusal, sturdyref selection,
and lowering. Binding dogfoods hold exact attempt identity at the C waist. The
unchanged live Goblins gates hold the baseline wire boundary; Rooms directory
peering is the live product consumer. `zig build check` aggregates those claims.

## Forward compatibility

If OCapN adopts a different identity-route grammar, the private names converge
on the specification or remain explicitly private. The durable-key authority,
authenticated-carrier rule, and baseline lowering do not depend on the spelling
of the eventual wire vocabulary.

## Notes

Supersedes [ADR-0119](ADR-0119-multihome-comparison-protocol.md). Related:
[ADR-0107](ADR-0107-sealed-byte-channel.md),
[ADR-0109](ADR-0109-peer-owns-its-advertised-locators.md), and
[ADR-0118](ADR-0118-onion-profile-by-knowledge.md).
