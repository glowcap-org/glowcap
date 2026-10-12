---
id: ADR-0035
status: accepted
date: 2026-06-06
tags: [conformance, goblins, interop, netlayer, handshake]
decision: "A native glowcap peer holds a real OCapN conversation with a live Spritely Goblins vat over TCP, proven by `zig build goblins-interop`: keyed op:start-session (verify Goblins' Ed25519 signature), bootstrap fetch, deliver/resolve, arbitrary-precision integer round-trip, pipelined op:index / op:get, sturdyref enliven + dedup, inbound pipelined enliven-and-call, bootstrap miss→break with Goblins-readable ['break, reason-symbol], and the reverse listener bracket: a Goblins client enlivens and calls a glowcap-hosted actor, subscribes with `listen` on a live glowcap object export, and writes canonical op:get / op:index at glowcap's responders, then observes resolver-callback fulfillments for both projected answers. The TCP transport symbol is `tcp` to match Goblins' netlayer. Goblins version is whatever the devcontainer / host install provides (see pins.sh). The driver does not pin a version string at runtime."
supersedes: []
superseded_by: []
---

# ADR-0035 Live Goblins interop

## Context

Conformance artifacts were glowcap-vs-glowcap or glowcap-authored fixtures, so
no test parsed a byte Goblins emitted. Measured against Goblins v0.18.0
(installed as a `raco` package), the wire handshake was already byte-compatible:
the same `"1.0"` version, `op:start-session` record, Ed25519 signed-bytes
derivation `syrup(<my-location <ocapn-peer …>>)`, `public-key` / `sig-val`
descriptors, and self-delimiting framing. The only gap was the transport symbol:
glowcap advertised `tcp-testing-only` while Goblins' conformance netlayer
(`^tcp-netlayer`) matches only `tcp`, so the two could not address each other.

## Decision

The TCP transport symbol is `tcp`
([`net.tcp.transport_name`](../../../src/net/transport/tcp.zig)), matching
Goblins' conformance TCP netlayer. glowcap's locator shape (`ocapn-peer` label,
`host:port` designator, `#f` hints) already matched. The live proof is
`zig build goblins-interop`
([`interop/goblins_interop/driver.zig`](../../../interop/goblins_interop/driver.zig)).
It needs `racket` and the `goblins` collection on PATH, so it is a sibling of
the hermetic `check`, not part of it.

**Client bracket.** glowcap spawns `goblins-host.rkt`, dials over `net.tcp`,
runs the keyed `op:start-session` handshake (real Ed25519, `tcp` locator with
`#f` hints so the signed bytes match what Goblins re-encodes), verifies
Goblins' own start-session signature, bootstrap-fetches the echo cap, and
calls it to a fulfilled resolution (V1.0 resolver-callback deliver, Goblins
has no `op:resolve`). The same bracket pipelines asker-side `op:index` /
`op:get`, then enlivens the echo swiss-num through the ADR-0012 dedup cache
and proves a repeat enliven hits the cache with no wire traffic. An
arbitrary-precision integer round-trip against Goblins also lands here.

**Listener bracket.** glowcap binds a TCP listener and publishes a vat actor
behind a swiss-num. Five Goblins clients share that bracket: a settled call
([`glowcap-actor-call.rkt`](../../../conformance/goblins-peer/racket/glowcap-actor-call.rkt)),
a reverse-pipelined enliven-and-call
([`goblins-tap-dialer.rkt`](../../../conformance/goblins-peer/racket/goblins-tap-dialer.rkt)),
a bootstrap miss→break with a Goblins-readable
`['break, reason-symbol]`
([`glowcap-break-call.rkt`](../../../conformance/goblins-peer/racket/glowcap-break-call.rkt)),
an export-side `op:listen` where Goblins subscribes on a live glowcap object
export and hears the settlement
([`glowcap-export-listen.rkt`](../../../conformance/goblins-peer/racket/glowcap-export-listen.rkt)),
and a projection asker that writes canonical `op:get` / `op:index` at
glowcap's ADR-0050 responders, subscribes with `op:listen` on each projected
answer, and observes glowcap's resolver-callback fulfillments
([`glowcap-projection-asker.rkt`](../../../conformance/goblins-peer/racket/glowcap-projection-asker.rkt)).
This is live proof of the actor layer against a non-glowcap peer. The asker
`op:index` / `op:get` legs of the client bracket exercise engine-synthesized
`op:listen` on projection answers (ADR-0007).

## Scope (what this does not decide)

This proves, over a live socket and in both directions, the keyed handshake,
signature verification, bootstrap fetch, deliver/resolve (including break),
bignum round-trip, asker-side `op:index` / `op:get` (and the synthesized listen
those projections imply), sturdyref enliven + dedup, inbound pipelined
enliven-and-call, a published actor a Goblins client enlivens and calls,
Goblins listening on a live glowcap object export, and glowcap accepting
canonical `op:get` / `op:index` frames a Goblins netlayer wrote and answering
them through the V1.0 resolver-callback form. It does not prove a public
Goblins application API for outbound projections, live `op:untag`, or Goblins
over iroh. Sibling `zig build goblins-handoff`
proves recipient-side three-party handoff. `zig build goblins-gift` proves
gifter-vs-Goblins (binding `*-goblins-gift` twins that path over the C ABI).
Crossed hellos and wait-before-deposit stay with the upstream suite, not this
driver. The transport remains cleartext `tcp`. A confidential transport is a
separate netlayer slice.

## Alternatives Considered

- **Keep comparing only against glowcap-authored fixtures.** Rejected: it never
  establishes that Goblins emits or accepts the same bytes.
- **Rename to `tcp` only in docs, keep `tcp-testing-only` on the wire**.
  Rejected: Goblins' netlayer matches the wire symbol, so it must be `tcp`.

## Consequences

`net.tcp.transport_name` is `tcp`. The C ABI comment and `bindings/README.md`
follow. New `interop/goblins_interop/driver.zig` and the `goblins-interop`
build step ([`build.zig`](../../../build.zig)), documented in
[`.agents/rules/cli.md`](../../../.agents/rules/cli.md). This is the first
glowcap test that spawns a subprocess and drives real cross-implementation
traffic. The keyed-handshake building blocks in `engine.pairing` and
`engine.fetch` drove it unchanged.

## Notes

Supersedes the live-interop and `tcp-testing-only` framing deferred in
[ADR-0030](ADR-0030-netlayer-connection-and-memory-posture.md), and builds on
its named transport seam. The signed-bytes derivation it relies on is
[ADR-0006](ADR-0006-handshake-substrate-and-bootstrap-fetch.md).
