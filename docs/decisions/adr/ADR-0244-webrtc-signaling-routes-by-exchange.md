---
id: ADR-0244
status: accepted
date: 2026-10-14
tags: [bindings, browser, c_abi, net, signaling, webrtc]
decision: "The host that owns a WebRTC peer runs its dial and accept exchanges, authorizes the remote key before CapTP, and routes application signaling by exchange id across native and browser bindings."
supersedes: [ADR-0226, ADR-0232, ADR-0240]
superseded_by: []
amends: []
amended_by: []
---

# ADR-0244 WebRTC signaling and exchange ownership

## Context

A WebRTC DataChannel requires an SDP offer, an answer, and ICE candidates.
The application carries those texts through its signaling service. The host
that owns the WebRTC peer can enforce its bring-up, remote-key authorization,
and cleanup once for every binding that uses it.

Peer identity cannot identify a signaling exchange. Concurrent offers or
crossed dials with one peer need separate candidate routes. Refusing one at
the signaling layer prevents CapTP's ordinary crossed-hellos rule from
choosing the surviving session.

## Decision

The host that owns the peer runs both dial and accept exchanges. Outside a
browser, the C library's WebRTC provider owns the Rust peer. The Zig
completion backend drives its own exchange through its signaling authority.
Browser bindings drive their own `RTCPeerConnection`, because WebAssembly
owns no I/O and the browser does not use the native provider seam.

The application supplies offer, answer, candidate-send, and candidate-subscription
callbacks. Every exchange has an id. Binding authority calls that establish a
route name both the exchange and target, and later candidates name the id.
The browser connector and listener share one id counter. An application
whose signaling service has different ids maps between the two namespaces.

A native managed dial fills the provider's connect verbs. It authorizes the
dialed designator before establishing the session, sends the offer, and
accepts the answer and candidates under the driver's request id. A managed
accept takes an offer and its sender's designator, authorizes that key,
sends the answer, and yields an ordinary accepted connection. Accept ids
occupy a separate range from driver request ids in the same exchange table.

The browser listener mirrors managed acceptance. `provideOffer` returns an
exchange id, iteration yields accepted sessions, and `failExchange` abandons
an unfinished accept. The shared authority permits an asynchronous answer.
An asynchronous failure is reported on the Host when it has no waiting
caller. Closing the listener retires pending exchanges and untaken sessions.

The channel's verified remote key is fixed before CapTP starts. The peer's
hello must attest that key before the accepted session reports authenticated
transport provenance. Failed or cancelled exchanges close their peers and
retire candidate subscriptions. The native provider's `done` callback lets
the application stop forwarding for that exchange. Native callbacks and
the calls that supply their answers run on the thread stepping the driver.

Concurrent exchanges with the same peer remain independent. The shared
in-flight accept limit bounds admission, and CapTP decides which session
survives crossed dials. A provider without a signaling direction leaves that
direction's managed verbs unavailable. Raw peer adoption remains available
to an application that owns bring-up itself.

## Alternatives Considered

- **Implement bring-up in every binding.** This repeats authorization and
  cleanup around the same native peer operations.
- **Put browser and native peers behind one Zig exchange.** The native
  exchange depends on descriptors and wake channels absent in the browser.
- **Learn the remote identity from the handshake alone.** A session key
  does not establish the durable identity authorized by signaling.
- **Route candidates by peer or break ties during signaling.** Independent
  exchanges collide, or a dial fails before CapTP can settle crossed hellos.
- **Return answers only from the offer call.** Callbacks accommodate both
  native exchange lifetimes and asynchronous browser signaling.

## Consequences and evidence

The native owners are `src/c_abi/net_transport/webrtc/dial.zig`,
`src/c_abi/net_transport/webrtc/accept.zig`, and their shared exchange table.
`src/net/transport/webrtc/backend/signaling.zig` owns the Zig exchange.
The browser connector and listener share
`bindings/ts/webrtc/exchange.ts`. The signaling carrier remains an
application choice.

`test/net/webrtc_provider_accept_test.zig` covers a dial and offers with one
peer under separate ids. `zig build webrtc-internal-test` and
`zig build webrtc-driver-provider` cover native admission, authorization,
cancellation, and driver integration. `bindings/ts/webrtc/test/listener_test.ts`
covers browser refusal and cleanup. `zig build webrtc-browser-to-browser`
checks an accepted browser session's authenticated partner.

## Related decisions

ADR-0089 owns the DataChannel netlayer. ADR-0105 owns authorized remote keys,
ADR-0112 owns the provider seam, and ADR-0030 owns crossed hellos.
