---
id: ADR-0068
status: accepted
date: 2026-07-05
tags: [driver, actors, handoff, three-party, host, crossed-hellos, api]
decision: "The Zig multi-session tier is `driver.core.Host`: one identity, one `engine.Node`, one crossed-hellos registry, many node-registered sessions. An introduction is a typed third outcome (`actors.Resolution` and `driver.Settled` gain a `.give` arm projected in the vat's far-resolve path while the event frame is live (the verbatim signed envelope and dialable locator URI survive only there)) and the Zig forms of the two handoff halves are explicit where a binding's are invisible: `Host.redeem(from, give)` is the blocking recipient executor over the ADR-0067 serve step, and origination is the vat's served-reply interceptor, installed by the host on every session, so a published actor that returns a foreign-homed capability answers with a signed give and no new public verb exists. The host also owns the crossed-hellos tiebreak: `dial` registers the outbound before bytes move, only *accepted* connection attempts compare inbound start-sessions against the registry, and a listening host signs its first listener's bound designator into every dial so the comparison keys on a real address. Proven hermetically by the three-host scenario in `test/driver/core_host/` and live by `zig build goblins-handoff`, whose driver is the tier's consumer."
supersedes: []
superseded_by: []
amends: []
amended_by: [ADR-0096, ADR-0097, ADR-0100, ADR-0113]
---

# ADR-0068 The Zig multi-session tier is an explicit Host

> ADR-0100 amends handoff ownership: Host resolves live sessions but owns no
> shared gift or replay table. Each Peer owns that session authority.

## Context

ADR-0066/0067 gave every language binding a transparent three-party story: each
binding's `connect` built a composite that owned the retained identity, the gift
registry, and the serve step, so an application redeems and originates handoffs
without naming them. Zig had no such tier. The driver's `Connection` is
one-connection-one-vat and embeds its peer by value, so no existing surface
could produce a node-registered connection. A `BlockingSession` draws a session
secret it does not retain, so it could not even sign the withdraw a gifter's
give addresses, and a handoff give reaching a Zig caller arrived as a
`.fulfilled` argument whose two essential parts, the verbatim signed envelope (a
span over the raw frame) and the dial hints in the locator record, had been
destroyed by the owned decode. Zig had the weakest handoff surface in the
project, and the only worked example was a hand-rolled engine choreography in
the Goblins interop driver.

Two adjacent pieces shared the gap. The crossed-hellos tiebreak (ADR-0030)
had a passing unit test, but nothing in production registered an outbound dial,
so the registry every inbound comparison consulted was always empty and the
tiebreak could not fire. And a served
reply that fulfills with a capability homed on another connection is the
moment gifter-side origination must intercept, which only serve-time code can
observe. The actors layer had no seam for it.

## Decision

One composite owns what the bindings' composites own.

`driver.core.Host` holds the identity seed, the `engine.Node`, the netlayer
slice, and a crossed-hellos registry. `Host.dial` and `Host.listen`/`accept`
mint owning connections whose peers are node-registered and whose keyed sessions
sign with the host identity, so an exporter verifies a handoff signature against
the one key the gifter named. Every connection carries two hooks: the
before-serve hook offers each inbound resolve to the node before the vat sees it
(a claimed resolve is serve-step bookkeeping, not the application's), and the
vat's served-reply interceptor (a single seam on `actors.Vat`) turns a reply
that fulfills with a foreign-homed capability into a signed give through the
node, drawing gift-id entropy at the host's I/O boundary. `call`/`send`/`tell`
route through `Node.routeReference`, so a redeemed route is addressable from any
of the host's connections.

An introduction is a typed outcome, not a dead argument. `actors.Resolution`
and `driver.Settled` carry a third arm, `.give`, projected in the vat's
far-resolve path while the wire event is still in hand: the only place the
verbatim envelope span and the locator record's hints survive. The projection
rides the same `engine.handoff_recipient.projectGiveForRedeem` definition the
C ABI and Host use. That helper reads the parser-recorded `raw_signed` span and
typed exporter locator together, so there is one definition of "what a give
projects to" for the Zig path and the waist. No frame-wide substring search
participates.

The two halves are explicit. A binding hides redeem inside `connect` because its
runtime hides I/O. In Zig a dial inside `call` would hide a socket, an
allocation, and an identity decision. `Host.redeem(from, give)` is one blocking
call that executes the serve step's actions: dial through the same netlayer
slice, flush, offer resolves for claiming, answer `need_gift_id` with host
entropy, and hand back an ordinary routable ref. Origination has no public verb:
it is not caller-initiated, it is what serving does when a reply crosses
connections, and the interceptor is where that is observable.

The host owns the crossed-hellos tiebreak because the host is the identity the
tiebreak keys on. `dial` registers the outbound before any bytes move. Only
*accepted* connections compare inbound start-sessions against the registry (a
partner's start-session on a connection this host dialed is the ordinary
handshake response, and comparing those aborts every dial to a listed partner),
and a listening host signs its first listener's bound designator
into every dial, so the partner's registry compares against a real address. A
give minted against this host then names a dialable exporter.

## Consequences

The Zig tier reaches parity with the bindings, proven the same way: the
hermetic three-host scenario (`test/driver/core_host/`) runs
originate, give, redeem, and the direct call over real loopback sockets, which
makes `zig build check` prove Zig origination, and the live
`goblins-handoff` driver consumes `Host.redeem` against a real Goblins
introducer and exporter. The exporter in the scenario serves both of its
connections from one thread with `stepReadable` round-robin, which works because a
withdraw that beats its deposit parks and settles when the deposit lands
(ADR-0056).

Every settled-outcome consumer handles the third arm. Zig's exhaustive switches
make the compiler enumerate the sites, and the README's first snippet teaches
that a capability can arrive as an introduction. A `.give` that fails to project
falls back to the plain fulfilled argument, so the projection fails closed.

The single-connection tier (`connect`/`listen`) stays beneath the host for the
client that never holds two connections. The fan-out tier (`LoopHost`/
`LoopDialer`) remains TCP-only and node-less, a boundary stated in
`docs/boundaries.md`. `driver.core.Host` owns handoffs and the loop owns scale.

## Amendment (2026-07-11): executed and superseded in part by ADR-0072

ADR-0072 rebuilt this tier over the byte-fed core. The Zig multi-connection
path is `driver.Bridge` + `completion.Loop` over `driver_core.Host` (ADR-0076).
`Host.redeem` does not exist: the core auto-redeems every give inside the serve
step. ADR-0072's fourth amendment deleted the node-less loop tier, which retires
the fan-out boundary above.
