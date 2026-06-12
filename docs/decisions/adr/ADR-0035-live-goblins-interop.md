---
id: ADR-0035
status: accepted
date: 2026-06-06
tags: [conformance, goblins, interop, netlayer, handshake]
decision: "A native pancake peer holds a real OCapN conversation with a live Spritely Goblins v0.18.0 vat over TCP, proven by the gated `zig build goblins-interop` step: it spawns the conformance Goblins host, dials it, completes the keyed op:start-session handshake (verifying Goblins' Ed25519 signature over its own start-session), bootstrap-fetches Goblins' echo cap, and calls it (deliver) to a fulfilled resolution. A second bracket runs the reverse: pancake listens, publishes a vat actor behind a swiss-num, and a real Goblins client enlivens and calls it. The TCP transport symbol is `tcp` to match Goblins' netlayer."
supersedes: []
superseded_by: []
---

# ADR-0035 Live Goblins interop

## Context

The whole point of pancake is OCapN conformance, yet every prior conformance
artifact was pancake-vs-pancake or pancake-vs-pancake-authored fixtures — a
Goblins maintainer's fair charge was "you've never actually parsed a byte
Goblins emitted." Two things stood in the way of a live conversation, and both
were small once measured against a real Goblins v0.18.0 (installed here as a
`raco` package): the wire handshake was already byte-compatible (same `"1.0"`
version, the same `op:start-session` record, the **same** Ed25519 signed-bytes
derivation `syrup(<my-location <ocapn-peer …>>)`, the same `public-key` /
`sig-val` descriptors, the same self-delimiting framing), but pancake advertised
the transport symbol `tcp-testing-only` while Goblins' conformance netlayer
(`^tcp-netlayer`) matches only `tcp` — so the two could not address each other.

## Decision

The TCP transport symbol is `tcp` ([`net_adapter.tcp.transport_name`](../../../src/net_adapter/tcp.zig)),
matching Goblins' conformance TCP netlayer; pancake's locator shape (`ocapn-peer`
label, `host:port` designator, `#f` hints) already matched. The live proof is the
gated step `zig build goblins-interop`
([`conformance/goblins_interop/driver.zig`](../../../conformance/goblins_interop/driver.zig)):
it spawns `goblins-host.rkt`, reads its NDJSON readiness to learn the
listen port and echo swiss-num, dials it over `net_adapter.tcp`, runs the keyed
`op:start-session` handshake (real Ed25519, a `tcp` locator with `#f` hints so the
signed bytes match what Goblins re-encodes), **verifies Goblins' own start-session
signature**, bootstrap-fetches Goblins' echo cap, then **calls it** —
`echo("pancake-ping")` — and asserts Goblins resolves the answer fulfilled (the
resolution arrives via the V1.0 listen/deliver path, which `Event.view()`
re-projects as a `Resolve`, since Goblins has no `op:resolve`). It needs `racket`
+ the `goblins` collection on PATH, so it is a sibling of the hermetic `check`
(like the binding dogfoods), not part of it.

The same `goblins-interop` step also runs the reverse direction. A listener bracket has pancake bind a TCP listener and publish a vat actor behind a swiss-num; a real Goblins client ([`conformance/goblins-peer/racket/pancake-actor-call.rkt`](../../../conformance/goblins-peer/racket/pancake-actor-call.rkt)) dials in, enlivens the actor, and calls it, and the driver asserts Goblins received the actor's reply. This is the first live proof of the actor layer against a non-pancake peer.

## Scope (what this does not decide)

This proves, over a live socket and in both directions, the keyed handshake,
signature verification, bootstrap fetch, a deliver to a fetched cap resolving
fulfilled, and a published actor a Goblins client enlivens and calls. The current
`goblins-interop` driver also proves the inbound pipelined enliven-and-call path,
and the sibling `zig build goblins-handoff` step proves recipient-side
three-party handoff against a live Goblins introducer and exporter. Crossed
hellos is exercised by the upstream OCapN suite rather than by the live Goblins
driver. The transport remains cleartext `tcp`; a confidential transport (TLS) is
a separate netlayer slice.

## Alternatives Considered

- **Keep comparing only against pancake-authored fixtures**. Rejected: it never
  establishes that Goblins emits or accepts the same bytes — exactly the gap.
- **Rename to `tcp` only in docs, keep `tcp-testing-only` on the wire**. Rejected:
  the wire symbol is what Goblins' netlayer matches; it must be `tcp` to address.

## Consequences

`net_adapter.tcp.transport_name` is `tcp`; the C ABI comment and `bindings/README.md`
follow. New `conformance/goblins_interop/driver.zig` and the `goblins-interop`
build step ([`build.zig`](../../../build.zig)), documented in
[`.agents/rules/cli.md`](../../../.agents/rules/cli.md). This is the first pancake
test that spawns a subprocess and drives real cross-implementation traffic; the
keyed-handshake building blocks in `engine.pairing` and `engine.fetch` drove it
unchanged.

## Notes

Supersedes the live-interop and `tcp-testing-only` framing deferred in
[ADR-0030](ADR-0030-netlayer-connection-and-memory-posture.md), and builds on its
named transport seam. The signed-bytes derivation it relies on is
[ADR-0006](ADR-0006-handshake-substrate-and-bootstrap-fetch.md).
