---
id: ADR-0226
status: superseded
date: 2026-10-14
tags: [net, c_abi, bindings, webrtc]
decision: "A managed WebRTC dial is one signaling exchange, driven by whichever host owns the peer. Outside a browser that host is the C library's WebRTC provider: it brings up the offerer, calls the application's signaling callbacks, takes the answer and remote candidates back through two netlayer calls, and completes the driver's dial when the channel opens, so every non-browser binding dials through the driver with a provider shaped like iroh's. In a browser the host is the binding's own RTCPeerConnection code. Both hosts call the same signaling shape: send an offer and get the answer, send a candidate, receive candidates."
supersedes: []
superseded_by: [ADR-0244]
amends: []
amended_by: []
---

# ADR-0226 A WebRTC dial is one signaling exchange in the peer's own host

[ADR-0244](ADR-0244-webrtc-signaling-routes-by-exchange.md) consolidates this decision. It retains managed dialing in the peer-owning host and incorporates managed acceptance and exchange-id routing.

## Context

A WebRTC peer has no address. Bringing a DataChannel up means trading an
SDP offer, an SDP answer, and ICE candidates through something the
application already holds (ADR-0089), then pinning the keyed session to the
designator that exchange was scoped to (ADR-0105). Before this decision the
Zig completion backend ran that exchange for `driver.HostRuntime`, the
TypeScript browser connector ran its own copy over `RTCPeerConnection`, and
the C library let the driver claim only a peer the caller had already opened
by hand. Rust, Python, Racket and Deno had no managed dial outside a browser.

The WebRTC peer runs in one of two places. Outside a browser it is the Rust
library behind `libglowcap_net_transport_webrtc`. In a browser it is the
browser's own `RTCPeerConnection`, and wasm owns no I/O (ADR-0112), so the
browser never composes through the provider seam. One abstraction over both
would have exactly one implementation on each side of that line.

## Decision

The host that owns the peer runs the exchange, and the application supplies
signaling in one shape everywhere: `send_offer(exchange, designator, sdp)`,
which the application answers later with the far peer's SDP,
`send_candidate(exchange, ice)`, and candidates coming back from the far
peer. Zig (`webrtc.SignalingAuthority`), the C library
(`GlowcapWebrtcSignaling`), and the TypeScript browser connector
(`SignalingAuthority`) are that shape in three languages.

Outside a browser the C library's WebRTC provider is the host. A netlayer
created with `GlowcapWebrtcConfig.signaling` set fills the multiplexed
provider table's `start_connect`, `finish_connect` and `cancel_connect`.
`start_connect` creates the offerer, authorizes the dialed designator as the
channel's remote key (ADR-0105), produces the offer and calls `send_offer`.
Each local candidate the Rust library gathers goes out through
`send_candidate`. The application hands the answer and each remote candidate
back with `glowcap_webrtc_netlayer_provide_answer` and
`glowcap_webrtc_netlayer_provide_candidate`, naming the exchange by the
driver's request id. When the channel opens the provider reports a connect
record, `finish_connect` claims the peer as a connection, and the driver
runs the keyed handshake over it. A failed or cancelled exchange closes its
peer, and `done(exchange)` tells the application the exchange is over so it
can stop forwarding candidates. A netlayer without signaling leaves the three
dial verbs null, so a dial through it is refused by the driver as an
unsupported operation, the same refusal a bare locator earns in Zig. The raw
peer calls and `claim_external` stay for an application that drives the
exchange itself. The owner is `src/c_abi/net_transport/webrtc/dial.zig`.

Every binding's `webrtc.provider(signaling, config)` installs that package
the way `iroh.provider` does, so a binding's ordinary `connect(locator)`
dials WebRTC with no binding-side state machine. Zig registers
`webrtc.CompletionResident` over `webrtc.Backend` with `driver.connect` or
`driver.listen`, which is the same exchange the completion backend already
ran. In a browser, `@glowcap/webrtc` and the Rust browser peer keep driving
`RTCPeerConnection` directly.

## Scope (what this does not decide)

This decision covers the dial. ADR-0232 amends it with the accepting side,
where the same host answers an inbound offer through one more signaling
callback.

## Alternatives Considered

- **A peer slot behind one Zig exchange, filled by the Rust library or the
  browser's WebRTC**: rejected because the Zig exchange depends on
  descriptors, locks and wake channels the browser has none of, so the slot
  would have one implementation per side and the abstraction would buy
  nothing.
- **Reuse `webrtc.Backend` inside the C netlayer**: rejected because the
  backend consumes the netlayer's signaling readiness queue, which the raw
  peer calls on the same netlayer also read, and because the provider already
  owns packet I/O over its peers. The dial is a small state table beside that
  I/O, not a second loop.
- **A pull model with no callbacks, where the binding polls an outbox for
  offers and candidates**: rejected because an offer needs a wake the Zig
  side cannot inject into the Rust library's descriptor, and because the
  Zig side already speaks in callbacks (`SignalingAuthority`).

## Consequences

`GlowcapWebrtcConfig` grows a `signaling` field, so every binding's layout
mirror, the generated constants, the header, and the archive fingerprint
change together. The provider's `drain_ready` routes CANDIDATE, OPEN and
CLOSED records for exchanges it owns and keeps routing READABLE, WRITABLE
and CLOSED for claimed connections. Callbacks run on the thread that steps
the driver, and the two `provide_*` calls must be made on that thread too.

## Evidence and gate

`zig build webrtc-internal-test` holds the provider table's shape with and
without signaling, what each callback receives, how an answer and a
candidate find their exchange, and how an exchange ends as a connection, a
failure, or a cancel. `zig build webrtc-driver-provider` dials through the C
provider against a peer answered by hand, holds a session over the channel,
and releases the loop with a second exchange still waiting for its answer,
which cancels it and announces the end. Each binding's WebRTC proof dials the Zig answerer through its
`webrtc.provider`. `zig build gen-header-net-transport-webrtc-check` and the
`gen-binding-*-check` steps hold the generated surfaces.

## Notes

ADR-0089 (the DataChannel netlayer), ADR-0105 (the authorized remote key),
ADR-0112 (the driver archive and provider seam).
