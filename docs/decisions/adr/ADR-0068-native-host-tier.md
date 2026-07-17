---
id: ADR-0068
status: accepted
date: 2026-07-05
tags: [driver, actors, handoff, three-party, host, crossed-hellos, api]
decision: "The native multi-connection tier is `driver.core.Host`: one identity, one `engine.Node`, one crossed-hellos registry, many node-registered connections. An introduction is a typed third outcome (`actors.Resolution` and `driver.Settled` gain a `.give` arm projected in the vat's far-resolve path while the event frame is live (the verbatim signed envelope and dialable locator URI survive only there)) and the native spellings of the two handoff halves are explicit where a binding's are invisible: `Host.redeem(from, give)` is the blocking recipient executor over the ADR-0067 serve step, and origination is the vat's served-reply interceptor, installed by the host on every connection, so a published actor that returns a foreign-homed capability answers with a signed give and no new public verb exists. The host also owns the crossed-hellos tiebreak: `dial` registers the outbound before bytes move, only *accepted* connections compare inbound start-sessions against the registry, and a listening host signs its first listener's bound designator into every dial so the comparison keys on a real address. Proven hermetically by the three-host scenario in `test/driver/core_host_test.zig` and live by `zig build goblins-handoff`, whose driver is the tier's consumer."
supersedes: []
superseded_by: []
---

# ADR-0068 The native multi-connection tier is an explicit Host

## Context

ADR-0066/0067 gave every language binding a transparent three-party story:
each binding's `connect` builds a composite that owns the retained identity,
the shared gift registry, and the serve step, so an application redeems and
originates handoffs without naming them. Native Zig had no such tier. The
driver's `Connection` is one-connection-one-vat and embeds its peer by value,
so no existing surface could produce a node-registered connection; a
`BlockingSession` draws a session secret it does not retain, so it could not even
sign the withdraw a gifter's give addresses; and a handoff give reaching a
native caller arrived as a `.fulfilled` argument whose two load-bearing parts
the verbatim signed envelope (a span over the raw frame) and the dial hints
in the locator record: had already been destroyed by the owned decode. The
reference implementation's own language had the weakest handoff surface in the
project, and the only worked example was a hand-rolled engine choreography in
the Goblins interop driver.

Two adjacent pieces shared the gap. The crossed-hellos tiebreak (ADR-0030)
existed with a passing unit test, but nothing in production ever registered an
outbound dial, so the registry every inbound comparison consulted was always
empty: machinery OCapN requires, structurally unable to fire. And a served
reply that fulfills with a capability homed on another connection is exactly
the moment gifter-side origination must intercept, which only serve-time code
can observe; the actors layer had no seam for it.

## Decision

One composite owns what the bindings' composites own, spelled Zig-natively.

`driver.core.Host` holds the identity seed, the `engine.Node`, the netlayer slice,
and a crossed-hellos registry. `Host.dial` and `Host.listen`/`accept` mint
owning connections whose peers are node-registered and whose keyed sessions
sign with the host identity, so an exporter verifies a handoff signature
against the one key the gifter named. Every connection carries two hooks: the
before-serve hook offers each inbound resolve to the node before the vat sees
it (a claimed resolve is serve-step bookkeeping, never the application's), and
the vat's served-reply interceptor: a new, single seam on `actors.Vat`,
turns a reply that fulfills with a foreign-homed capability into a signed give
through the node, drawing gift-id entropy at the host's I/O boundary.
`call`/`send`/`tell` route through `Node.routeReference`, so a redeemed token
is addressable from any of the host's connections.

An introduction is a typed outcome, not a dead argument. `actors.Resolution`
and `driver.Settled` carry a third arm, `.give`, projected in the vat's
far-resolve path while the wire event is still in hand: the one place the
verbatim envelope span and the locator record's hints survive. The projection
rides the same engine definitions the C ABI's resolve projection uses
(`engine.handoff_recipient.exporterLocatorUri`,
`codec.syrup.spanSignedHandoffGive`), so there is one definition of "what a
give projects to" for the native path and the waist.

The two halves stay explicit on purpose. A binding hides redeem inside
`connect` because its runtime hides I/O anyway; in Zig a hidden dial inside
`call` would be a hidden socket, a hidden allocation, and a hidden identity
decision. `Host.redeem(from, give)` is one blocking call that executes the
serve step's actions: dial through the same netlayer slice, flush, offer
resolves for claiming, answer `need_gift_id` with host entropy: and hands
back an ordinary routable ref. Origination gets no public verb at all, because
it is not caller-initiated: it is what serving does when a reply crosses
connections, and the interceptor is where that fact is observable.

The host owns the crossed-hellos tiebreak because the host is the identity the
tiebreak keys on. `dial` registers the outbound before any bytes move; only
*accepted* connections compare inbound start-sessions against the registry (a
partner's start-session on a connection this host dialed is the ordinary
handshake response: the first wiring compared those too, and aborted every
dial to a listed partner; the three-host scenario caught it before it
shipped); and a listening host signs its first listener's bound designator
into every dial, so the partner's registry compares against an address that is
real: which also makes a give minted against this host name a dialable
exporter.

## Consequences

The native tier reaches parity with the bindings, proven the same way: the
hermetic three-host scenario (`test/driver/core_host_test.zig`) runs
originate, give, redeem, and the direct call over real loopback sockets: the
first time `zig build check` proves native origination: and the live
`goblins-handoff` driver consumes `Host.redeem` against a real Goblins
introducer and exporter. The exporter in the scenario serves both of its
connections from one thread with `stepReadable` round-robin, correct because a
withdraw that beats its deposit parks and settles when the deposit lands
(ADR-0056).

Every settled-outcome consumer handles the third arm; Zig's exhaustive
switches made the compiler enumerate the sites, and the README's first snippet
now teaches that a capability can arrive as an introduction. A `.give` that
fails to project falls back to the plain fulfilled argument, so nothing new
fails open.

The single-connection tier (`connect`/`listen`) stays beneath the host for the
client that never holds two connections; the fan-out tier (`LoopHost`/
`LoopDialer`) remains TCP-only and node-less, a stated boundary in
`docs/boundaries.md`. `driver.core.Host` owns handoffs, the loop owns scale,
and growing the loop under the host is the direction that retires the
boundary.

## Amendment (2026-07-11): executed and superseded in part by ADR-0072

The tier this record designed shipped, then ADR-0072 rebuilt it over the
byte-fed core: the Zig multi-connection path is now `driver.Bridge` +
`completion.Loop` over `driver_core.Host` (ADR-0076), and `Host.redeem` no
longer exists: the core auto-redeems every give inside the serve step, so no
public redeem verb remains. The closing fan-out boundary was retired the other
way: ADR-0072's fourth amendment deleted the node-less loop tier rather than
growing it under the host; the loop-to-Host bridge landed as ADR-0076.
