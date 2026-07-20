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

> **Status:** accepted as the direction. The producer half — an exporter
> advertising the hint on its own locator, which a handoff give already carries
> verbatim — needs no code change. The recipient half (parsing the hint at
> redeem staging) and its C-ABI surface are proposed, not yet implemented; the
> Scope section marks what does not exist today.

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

- Recipient-side ranked-path staging and the C ABI exposure of alternatives
  are not implemented. When they land, the C ABI rows must be extern structs
  materialized by the C ABI layer, not layout casts of engine types.
- No browser-native transport (WebRTC) exists; `alt-locators` only names
  transports that already have residents.
- Per-binding producer conveniences beyond ordinary locator construction are
  not specified.
- Goblins' tolerance of the unknown hint key inside a give's locator is
  asserted by the locator grammar but not yet pinned by a live scenario; a
  wire-compatibility claim requires that evidence first.

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

- `src/ocapn/model/transport.zig` grows the `alt-locators` hint name beside
  `direct-addresses` when the consumer lands.
- The recipient work concentrates in `engine.Node` staging and the dial plan;
  codecs and session stay untouched.
- Evidence obligations for the implementation change: a pancake-only
  two-transport scenario where the primary path is unreachable and an
  alternative succeeds; corpus fixtures only ever regenerated through
  `test/oracle/generate.rkt`; a live Goblins run covering a give whose
  exporter locator carries the unknown hint.
