---
id: ADR-0087
status: accepted
date: 2026-07-20
tags: [handoff, locator, transport, browser]
decision: "Multi-transport reachability rides an exporter-advertised alt-locators hint on its own locator. The handoff record and signing domain do not change."
supersedes: []
superseded_by: []
---

# ADR-0087 Alternative locators ride exporter-advertised hints

> **Status:** accepted and complete. The producer half is an exporter
> advertising the hint on its own locator, which a handoff give carries
> verbatim. The recipient Node stages the primary and bounded alternatives once,
> and Host/Node retry the same pending ticket in order. The C pending-dial view
> exposes the active parsed path, so bindings do not parse or own fallback
> policy. Focused Node and Host scenarios hold ordering, refusal, retry, and
> teardown.

## Context

A browser peer that redeems a three-party handoff may not be able to dial the
exporter's primary transport: the exporter may listen on `iroh` or `keyed-tcp`
while the browser can only reach it through a relay (ADR-0086) or a
browser-native transport. The recipient therefore needs to learn, before any
connection to the exporter exists, that more than one dial path reaches the
same peer.

The OCapN locator grammar fixes where such advice can live. `desc:handoff-give`
is a five-field record inside an Ed25519 `desc:sig-envelope`. The running
Goblins unmarshaller parses it at fixed arity, so the signed record cannot grow
a field without breaking cross-implementation parse and signature verification
(proved against the reference fixture generator). Locator hints are the spec's
open extension point: a locator carries any number of hints, and locators
differing only in hints designate the same peer. The `direct-addresses` hint
travels this way: the gifter embeds the exporter's own session location bytes
verbatim into every give it mints, so anything the exporter advertises on its
locator reaches every recipient, signed, with no encoder change.

## Decision

The exporter advertises alternative reachability as one `alt-locators` hint on
its own locator. The value is a pipe-separated list of `ocapn://` peer URIs.
Pipe is structural after the outer hint value is decoded, and a pipe in a nested
URI stays percent-encoded. Comma cannot serve because a nested transport may use
it inside `direct-addresses`. The string-valued hint survives the hint dict
encoding, canonical ordering, URI query projection, and both codecs without new
wire structure. It flows into handoff gives through the verbatim
exporter-location bytes the gifter embeds
(`src/ocapn/engine/handoff_gifter.zig`). The give schema, the signing domain,
and the oracle corpus are unchanged.

The recipient consumes the hint at redeem staging: `engine.Node` parses the
exporter locator once when it stages a pending dial, splits `alt-locators`
there, and stages ranked dial paths (primary first, then each alternative)
as parsed parts, with no URI re-parse on the redeem path. Fallback across paths
is dial-plan policy owned by the Node/Host and surfaced identically to every
binding, and no binding has its own fallback order.

## Scope (what this does not decide)

- The C ABI does not expose the complete alternative list. It exposes the
  active parsed path through the existing pending-dial row. The Node advances
  that row and emits the same ticket again after a failed attempt. No binding
  parses or ranks the hint.
- Alternatives must still name transports available to the recipient. The
  hint does not install providers or grant signaling authority.
- Per-binding producer conveniences beyond ordinary locator construction are
  not specified.
- Goblins' tolerance of the unknown hint key is an external interoperability
  check. The hint rides the signed locator bytes and is ignored by peers that do
  not implement recipient fallback.

## Alternatives Considered

- **A signed seventh record field**: rejected. Goblins parses
  `desc:handoff-give` at fixed arity, and the reference fixture generator
  proved the byte drift.
- **A negotiation transport**: rejected. Negotiation needs a connection, and
  the recipient must choose what to dial before one exists.
- **`op:start-session` negotiation**: rejected. Start-session runs after the
  transport was already chosen and dialed.
- **Application-level discovery only** (a rooms `/locators` endpoint): rejected
  as the general mechanism. Engine-level auto-redeem must work for any
  application. Apps may still layer richer discovery above.

## Consequences

- `src/ocapn/model/transport.zig` owns the `alt-locators` hint name beside
  `direct-addresses`.
- The recipient work lives in `engine.Node` staging and the Host action seam.
  Codecs, session, generic driver loops, and bindings are unchanged.
- The evidence is the focused Node/Host scenario:
  an unreachable primary advances one ticket to a working alternative, with
  ordering, malformed/oversized refusal, ordinary dialing, and teardown
  ownership covered. The hint is locator advice and does not change the signed
  handoff record or its codec corpus.
