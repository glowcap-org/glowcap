---
id: ADR-0087
status: accepted
date: 2026-07-20
tags: [handoff, locator, transport, browser]
decision: "Multi-transport reachability rides an exporter-advertised alt-locators hint on its own locator; the handoff record and signing domain do not change."
supersedes: []
superseded_by: []
---

# ADR-0087 Alternative locators ride exporter-advertised hints

> **Status:** accepted and complete.
> The producer half — an exporter advertising the hint on its own locator, which
> a handoff give already carries verbatim — remains unchanged. The recipient
> Node stages the primary and bounded alternatives once, and Host/Node retry the
> same pending ticket in order. The existing C pending-dial view exposes the
> active parsed path, so bindings do not parse or own fallback policy. Focused
> Node and Host scenarios hold ordering, refusal, retry, and teardown.

## Context

A browser peer that redeems a three-party handoff may not be able to dial the
exporter's primary transport: the exporter may listen on `iroh` or `keyed-tcp`
while the browser can only reach it through a relay (ADR-0086) or a
browser-native transport. The recipient therefore needs to learn, before any
connection to the exporter exists, that more than one dial path reaches the
same peer.

The OCapN locator grammar fixes where such advice can live. `desc:handoff-give`
is a five-field record inside an Ed25519 `desc:sig-envelope`; the running
Goblins unmarshaller parses it at fixed arity, so the signed record cannot grow
a field without breaking cross-implementation parse and signature verification
(a schema-extension attempt proved this against the reference fixture generator
and was reverted). Locator hints are the spec's open extension point: a locator
carries any number of hints, and locators differing only in hints designate the
same peer. The `direct-addresses` hint already travels this way today: the
gifter embeds the exporter's own session location bytes verbatim into every
give it mints, so anything the exporter advertises on its locator reaches every
recipient, signed, with no encoder change.

This engages the first principles that protocol correctness precedes
convenience (the signed record stays Goblins-parseable) and that the portable
core stays free of adapter policy (transport choice is dial advice, not
capability semantics).

## Decision

The exporter advertises alternative reachability as one `alt-locators` hint on
its own locator. The value is a comma-separated list of `ocapn://` peer URIs,
the same string-valued shape `direct-addresses` uses, so it survives the
existing hint dict encoding, canonical ordering, URI query projection, and both
codecs without new wire structure. The hint flows into handoff gives through
the verbatim exporter-location bytes the gifter already embeds
(`src/ocapn/engine/handoff_gifter.zig`); the give schema, the signing domain,
and the oracle corpus are untouched.

The recipient consumes the hint at redeem staging: `engine.Node` parses the
exporter locator once when it stages a pending dial, splits `alt-locators`
there, and stages ranked dial paths (primary first, then each alternative)
as parsed parts — never a URI re-parse on the redeem path. Fallback across
paths is dial-plan policy owned by the Node/Host and surfaced identically to
every binding; a binding never invents its own fallback order.

## Scope (what this does not decide)

- The C ABI does not expose the complete alternative list. It exposes the
  active parsed path through the existing pending-dial row; the Node advances
  that row and emits the same ticket again after a failed attempt. No binding
  parses or ranks the hint.
- Alternatives must still name transports available to the recipient; the
  hint does not install providers or grant signaling authority.
- Per-binding producer conveniences beyond ordinary locator construction are
  not specified.
- Goblins' tolerance of the unknown hint key remains an external
  interoperability check. It does not alter this implementation: the hint is
  carried by the existing signed locator bytes and is ignored by peers that do
  not implement recipient fallback.

## Alternatives Considered

- **A signed seventh record field**: rejected; Goblins parses
  `desc:handoff-give` at fixed arity, and the reference fixture generator
  proved the byte drift.
- **A negotiation transport**: rejected; negotiation needs a connection, and
  the recipient must choose what to dial before one exists.
- **`op:start-session` negotiation**: rejected; start-session runs after the
  transport was already chosen and dialed.
- **Application-level discovery only** (a rooms `/locators` endpoint): rejected
  as the general mechanism; engine-level auto-redeem must work for any
  application. Apps may still layer richer discovery above.

## Consequences

- `src/ocapn/model/transport.zig` owns the `alt-locators` hint name beside
  `direct-addresses`.
- The recipient work lives in `engine.Node` staging and the Host action seam;
  codecs, session, generic driver loops, and bindings stay untouched.
- Evidence for shipment is the focused Node/Host scenario:
  an unreachable primary advances one ticket to a working alternative, with
  ordering, malformed/oversized refusal, ordinary dialing, and teardown
  ownership covered. The hint is locator advice and does not change the signed
  handoff record or its codec corpus.
