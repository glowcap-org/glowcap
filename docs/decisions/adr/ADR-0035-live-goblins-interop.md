---
id: ADR-0035
status: accepted
date: 2026-06-06
tags: [conformance, goblins, interop, netlayer, handshake]
decision: "A native pancake peer holds a real OCapN conversation with a live Spritely Goblins vat over TCP, proven by `zig build goblins-interop`: keyed op:start-session (verify Goblins' Ed25519 signature), bootstrap fetch, deliver/resolve, arbitrary-precision integer round-trip, pipelined op:index / op:get, sturdyref enliven + dedup, inbound pipelined enliven-and-call, bootstrap miss→break with Goblins-readable ['break, reason-symbol], and the reverse listener bracket (Goblins client enlivens and calls a pancake-hosted actor). The TCP transport symbol is `tcp` to match Goblins' netlayer. Goblins version is whatever the devcontainer / host install provides (see pins.sh); the driver does not pin a version string at runtime."
supersedes: []
superseded_by: []
---

# ADR-0035 Live Goblins interop

## Context

The whole point of pancake is OCapN conformance, yet every prior conformance
artifact was pancake-vs-pancake or pancake-vs-pancake-authored fixtures: a
Goblins maintainer's fair charge was "you've never actually parsed a byte
Goblins emitted." Two things stood in the way of a live conversation, and both
were small once measured against a real Goblins v0.18.0 (installed here as a
`raco` package): the wire handshake was already byte-compatible (same `"1.0"`
version, the same `op:start-session` record, the **same** Ed25519 signed-bytes
derivation `syrup(<my-location <ocapn-peer …>>)`, the same `public-key` /
`sig-val` descriptors, the same self-delimiting framing), but pancake advertised
the transport symbol `tcp-testing-only` while Goblins' conformance netlayer
(`^tcp-netlayer`) matches only `tcp`: so the two could not address each other.

## Decision

The TCP transport symbol is `tcp`
([`net.tcp.transport_name`](../../../src/net/transport/tcp.zig)), matching
Goblins' conformance TCP netlayer; pancake's locator shape (`ocapn-peer` label,
`host:port` designator, `#f` hints) already matched. The live proof is
`zig build goblins-interop`
([`interop/goblins_interop/driver.zig`](../../../interop/goblins_interop/driver.zig)).
It needs `racket` and the `goblins` collection on PATH, so it is a sibling of
the hermetic `check`, not part of it.

**Client bracket.** pancake spawns `goblins-host.rkt`, dials over `net.tcp`,
runs the keyed `op:start-session` handshake (real Ed25519, `tcp` locator with
`#f` hints so the signed bytes match what Goblins re-encodes), verifies
Goblins' own start-session signature, bootstrap-fetches the echo cap, and
calls it to a fulfilled resolution (V1.0 resolver-callback deliver; Goblins
has no `op:resolve`). The same bracket pipelines asker-side `op:index` /
`op:get`, then enlivens the echo swiss-num through the ADR-0012 dedup cache
and proves a repeat enliven hits the cache with no wire traffic. An
arbitrary-precision integer round-trip against Goblins also lands here.

**Listener bracket.** pancake binds a TCP listener and publishes a vat actor
behind a swiss-num. Three Goblins clients share that bracket: a settled call
([`pancake-actor-call.rkt`](../../../conformance/goblins-peer/racket/pancake-actor-call.rkt)),
a reverse-pipelined enliven-and-call
([`goblins-tap-dialer.rkt`](../../../conformance/goblins-peer/racket/goblins-tap-dialer.rkt)),
and a bootstrap miss→break with a Goblins-readable
`['break, reason-symbol]`
([`pancake-break-call.rkt`](../../../conformance/goblins-peer/racket/pancake-break-call.rkt)).
That is live proof of the actor layer against a non-pancake peer. The asker
`op:index` / `op:get` legs exercise engine-synthesized `op:listen` on
projection answers (ADR-0007). Export-side listen on pancake's own object and
promise exports ships in-tree; this driver does not re-prove those against
Goblins.

## Scope (what this does not decide)

This proves, over a live socket and in both directions, the keyed handshake,
signature verification, bootstrap fetch, deliver/resolve (including break),
bignum round-trip, asker-side `op:index` / `op:get` (and the synthesized listen
those projections imply), sturdyref enliven + dedup, inbound pipelined
enliven-and-call, and a published actor a Goblins client enlivens and calls.
It does not prove Goblins-as-asker against pancake's get/index responders,
live `op:untag`, or Goblins over iroh. Sibling `zig build goblins-handoff`
proves recipient-side three-party handoff; `zig build goblins-gift` proves
gifter-vs-Goblins (binding `*-goblins-gift` twins that path over the C ABI).
Crossed hellos and wait-before-deposit stay with the upstream suite, not this
driver. The transport remains cleartext `tcp`; a confidential transport is a
separate netlayer slice.

## Alternatives Considered

- **Keep comparing only against pancake-authored fixtures**. Rejected: it never
  establishes that Goblins emits or accepts the same bytes: exactly the gap.
- **Rename to `tcp` only in docs, keep `tcp-testing-only` on the wire**.
  Rejected: the wire symbol is what Goblins' netlayer matches; it must be `tcp`
  to address.

## Consequences

`net.tcp.transport_name` is `tcp`; the C ABI comment and `bindings/README.md`
follow. New `interop/goblins_interop/driver.zig` and the `goblins-interop`
build step ([`build.zig`](../../../build.zig)), documented in
[`.agents/rules/cli.md`](../../../.agents/rules/cli.md). This is the first
pancake test that spawns a subprocess and drives real cross-implementation
traffic; the keyed-handshake building blocks in `engine.pairing` and
`engine.fetch` drove it unchanged.

## Notes

Supersedes the live-interop and `tcp-testing-only` framing deferred in
[ADR-0030](ADR-0030-netlayer-connection-and-memory-posture.md), and builds on
its named transport seam. The signed-bytes derivation it relies on is
[ADR-0006](ADR-0006-handshake-substrate-and-bootstrap-fetch.md).
