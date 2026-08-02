# Waiting on upstream

These are open questions in OCapN and Spritely Goblins. pancake cannot close
them by writing code, so they are not on [the roadmap](roadmap.md).

Where two pinned sources disagree, `zig build ocapn-findings-check` reproduces
the disagreement against the exact upstream revisions this repository pins, and
fails if an observation stops matching its source. The
[findings corpus](../conformance/ocapn-findings/README.md) has the details.

## OCapN Null

Goblins does not marshal Null and the upstream encoding is unsettled, so
pancake keeps unknown Syrup records as tagged values. Converging would mean a
model arm, codec round trips, and a live Goblins check.

## Live `op:untag`

The responder and fixtures ship. Goblins has no live marshaller for the
operation, so there is nothing to check against yet.

## `op:listen` arity

The draft shows two operands; Goblins and the upstream test suite use a third,
`wants_partial`. pancake follows the working implementations. That is a choice
about interoperating with what runs today, not a claim about which shape is
correct.

## Locator hints type

The draft describes hints as a mapping; the pinned Goblins constructor contract
accepts only false or a string. The wire unmarshaller builds nodes through the
raw constructor, so a mapping-shaped hints field does decode in practice, which
`zig build goblins-gift-hints` observes live.

This one has a dependent: ADR-0097's `session-key-attestation` credential rides
the hints extension point, so its wire shape stays provisional until the type
question settles upstream. Canonical vectors and live foreign-decode evidence
are committed; the proposal itself has not been sent.

## Handoff withdrawal lookup

Goblins resolves a give's session by the full node value including hints, while
its own node equality deliberately ignores hints. A give therefore redeems only
when its exporter locator matches the exporter's hello-declared location
hints-and-all. pancake satisfies this by embedding the exporter's signed
location record verbatim.

## Settlement encoding

Draft discussion sometimes names a separate `op:break`. Goblins CapTP 1.0 uses
resolver-callback fulfill and break, while the pancake-native profile carries
both under `op:resolve`. Revisit the native profile if the specification and
Goblins converge.

## Goblins over iroh

pancake's iroh transport is complete for native peers and bindings, but Goblins
ships no iroh netlayer, so there is no live Goblins-over-iroh check to write.

## Native Zig QUIC

pancake uses iroh rather than implementing QUIC. The decision reopens when
iroh's protocols stabilize and a production Zig QUIC stack exists
([ADR-0055](decisions/adr/ADR-0055-iroh-netlayer-sidecar.md)).
