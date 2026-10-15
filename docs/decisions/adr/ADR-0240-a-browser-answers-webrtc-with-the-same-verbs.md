---
id: ADR-0240
status: superseded
date: 2026-10-14
tags: [bindings, webrtc, browser]
decision: "A browser answers WebRTC with the same verbs a server does. `@glowcap/webrtc` gains `listener(host, signaling, options)`, which drives its own RTCPeerConnection for each offer the application hands in with the offerer's key, answers through the signaling object, and yields a session pinned to that key once the channel opens. One `SignalingAuthority` type serves the browser connector, the browser listener, and the Deno driver, and its `answer` may return a promise. One authority signals one exchange per peer at a time in either direction, and the in-flight accept limit is one exported constant."
supersedes: []
superseded_by: [ADR-0244]
amends: []
amended_by: []
---

# ADR-0240 A browser answers WebRTC with the same verbs

[ADR-0244](ADR-0244-webrtc-signaling-routes-by-exchange.md) consolidates this decision. It retains the browser listener and asynchronous signaling, and removes the one-exchange-per-peer restriction.

## Context

ADR-0232 gave every non-browser binding a managed accept: the application
hands an offer and the offerer's designator to `provide_offer`, the host
answers through `send_answer`, and the accepted session names the offerer.
It left the browser out. A browser application that wanted to accept WebRTC
built the answerer by hand from `RtcPeer`, set the offer, sent the answer,
and called `Session.establishAccepted` without a verified channel key, so
the accepted session could not say who had connected. The browser package's
`SignalingAuthority` also differed from the Deno driver's, which added
`answer`, so one application's signaling code could not serve both.

## Decision

`listener(host, signaling, options)` in `@glowcap/webrtc` answers offers for
a browser Host. It mirrors the driver's `Server`:

- `provideOffer(designator, sdp)` takes the offerer's key and returns the
  exchange id, or throws a `GlowcapError` with nothing started: `CLOSED`
  after close, `INVALID_ARGUMENT` for a malformed key or an oversized offer,
  and `WOULD_BLOCK` when that peer is still signaling or too many accepts
  are in flight.
- `failExchange(exchange)` gives up an accept whose channel has not opened.
- Iterating the listener yields each accepted `Session`. Its partner
  identity names the offerer with authenticated-transport provenance when
  the offerer's hello signs that key, because the listener passes the key as
  the channel's verified key (ADR-0105).
- `close` ends every accept still in flight and closes the sessions nobody
  took.

The browser builds its answer asynchronously, so a failure after
`provideOffer` returns ends that accept and is kept as a callerless failure
on the Host. A Deno `provideOffer` answers before it returns, so there a
throwing `answer` refuses the offer.

`SignalingAuthority` is one type in `bindings/ts/webrtc/exchange.ts`, and
the connector, the listener, and the Deno driver import it. `answer` returns
`void | Promise<void>`, and a rejected promise gives the accept up in both
environments. A side that only dials or only answers passes the authority
without the other verb.

Candidates route by target, so one authority signals one exchange per peer
at a time, whichever direction each runs. The browser keeps that rule per
authority object across its connector and listener, as the C netlayer does
per netlayer. The in-flight accept limit is
`GLOWCAP_WEBRTC_MAX_ACCEPTS_IN_FLIGHT`, owned by
`src/net/transport/webrtc.zig` and generated into every binding, so the C
provider and the browser listener bound accepts by one number.

The connector and the listener share one bring-up in `exchange.ts`: ICE
source resolution, the peer, candidate subscription and sends, cancellation
of each step, and the handshake with cleanup of a session that opens after
a cancel.

## Scope (what this does not decide)

How an offer reaches the browser stays the application's choice. The Rooms
browser client is Rust compiled to WebAssembly, and its own answering side
is outside this package.

## Alternatives Considered

- **Keep browser answering by hand**: rejected because every browser
  application would repeat the bring-up and none could name its partner.
- **A browser-only signaling type with a synchronous `answer`**: rejected
  because one application's signaling code then could not serve a browser
  and a Deno process, and a browser's own signaling send is asynchronous.
- **Learn the offerer's key from the handshake instead of the offer**:
  rejected for the reason ADR-0232 gives. The channel's verified key must be
  fixed before the session runs.

## Consequences

The C header and every binding's generated constants gain
`WEBRTC_MAX_ACCEPTS_IN_FLIGHT`. `connector` takes the shared authority
without `answer`, and its options type is `PeerOptions`. `isKeyDesignator`
moves into `@glowcap/runtime`, and `@glowcap/relay` uses it in place of its
own `isRendezvousDesignator`.

## Evidence and gate

`bindings/ts/webrtc/test/listener_test.ts`, run by `zig build
bindings-fmt-check`, holds the refusals, the in-flight limit, the
one-exchange-per-peer rule across a listener and a dial, give-up and close
semantics, and a rejected `answer`. `zig build webrtc-browser-to-browser`
has one Chromium tab dial through the connector and another accept through
the listener, and the answering tab checks that the session names the
offerer's key with authenticated-transport provenance.

## Notes

ADR-0232 (the managed accept this extends to the browser), ADR-0089 (the
DataChannel netlayer), ADR-0105 (the verified channel key).
