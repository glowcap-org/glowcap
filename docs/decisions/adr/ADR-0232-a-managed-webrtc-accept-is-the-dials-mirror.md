---
id: ADR-0232
status: superseded
date: 2026-10-14
tags: [net, c_abi, bindings, webrtc]
decision: "A managed WebRTC accept is the dial's mirror: the host that owns the peer answers an inbound offer on its own. The application hands the offer and the offerer's designator in, the host builds the answerer, scopes the channel to that designator, sends the answer back through one more signaling callback, and completes an ordinary accept when the channel opens. Zig's completion backend gains `startAnswer` and the authority gains `sendAnswer`. The C library's WebRTC provider gains `send_answer` and `provide_offer`, and a netlayer whose signaling can answer fills the multiplexed listen verbs so every non-browser binding accepts WebRTC through the driver's ordinary listen. A browser keeps its own RTCPeerConnection code."
supersedes: []
superseded_by: [ADR-0244]
amends: []
amended_by: []
---

# ADR-0232 A managed WebRTC accept is the dial's mirror

[ADR-0244](ADR-0244-webrtc-signaling-routes-by-exchange.md) consolidates this decision. It retains managed acceptance and remote-key authorization, and includes browser listeners and concurrent exchange routing.

## Context

ADR-0226 made the dial managed: the host that owns the WebRTC peer runs the
offer, answer and candidate exchange, and the application supplies signaling
as callbacks. It left the accepting side by hand. An application that
received an offer created the answerer itself, set the offer, produced the
answer, authorized the offerer's key, and handed the finished peer over
(`adoptAnswerer` in Zig, `claim_external` in C). Every server-side answerer
in the repository repeated those five steps, and a server process that
wanted to accept WebRTC through a binding had no listen at all: the driver's
multiplexed provider table left `listen`, `finish_accept` and `stop_listen`
null.

The dial already fixed where the exchange runs and what the application
provides. The accept has the same two hosts, the C library's Rust peer
outside a browser and `RTCPeerConnection` inside one, and the same need: the
offerer's designator must become the channel's authorized remote key
(ADR-0105) before any session runs over it.

## Decision

The host that owns the peer answers an inbound offer, and the application
supplies one more callback in the same signaling shape: `send_answer(exchange,
designator, sdp)`, carrying the answer back to the offerer the designator
names. The application hands an offer in with the offerer's designator and
gets the exchange id back. The host creates the answerer, authorizes the
designator as the channel's remote key, sets the offer, produces the answer,
and calls `send_answer` under that exchange id before the peer is adopted,
so a refused send closes a peer no far side ever learned about. Later
candidates flow under the same id in both directions, through the existing
`provide_candidate` and `send_candidate`. When the channel opens the host
completes an ordinary accept, and the accepted session's partner identity
names the offerer's designator with authenticated-transport provenance.

In Zig, `webrtc.Backend.startAnswer(designator, sdp)` is that entry, the
fourth thread-safe one beside `adoptAnswerer`, `provideAnswer` and
`provideRemoteCandidate`, and `SignalingAuthority.sendAnswer` is the
callback. `adoptAnswerer` stays for a signaling owner that must build the
peer itself. The owner is `src/net/transport/webrtc/backend/signaling.zig`.

In the C library, `GlowcapWebrtcSignaling` gains `send_answer` and the
netlayer gains `provide_offer(designator, sdp, out_exchange)` beside
`provide_answer` and `provide_candidate`. A netlayer whose signaling sets `send_offer` fills the
dial verbs, and one whose signaling sets `send_answer` fills the listen
verbs: `listen` is immediately ready and records the listener's identity
designator, `listener_locator` and `listener_advertise` project the webrtc
locator for that designator, `finish_accept` hands over each opened answerer,
and `stop_listen` closes the answerers still in flight. `provide_offer` is
refused while no listener is active. Exchange ids the provider mints for
accepts carry a high bit the driver never sets on a request id, so one
exchange table and one `provide_candidate` serve both directions. The owner
is `src/c_abi/net_transport/webrtc/accept.zig`, with `exchange.zig` holding
what the two directions share.

Every binding's `webrtc.provider(signaling, config)` therefore makes its
ordinary `listen` accept WebRTC, with the binding's signaling object
carrying the answer. In a browser, `@glowcap/webrtc` and the Rust browser
peer keep driving `RTCPeerConnection` for both directions.

## Scope (what this does not decide)

How an offer reaches the application is not decided here. A room, a
signaling capability over CapTP, or a stdio pipe each remain the
application's choice, and ADR-0089 owns the DataChannel netlayer they feed.
A browser-side listener in `@glowcap/webrtc` is not decided here either.

## Alternatives Considered

- **Keep accepting by hand and ship a helper per binding**: rejected because
  each helper would re-implement the five steps and the authorization order
  over the raw peer calls, which is exactly the duplication ADR-0226 removed
  from the dial.
- **Let the host take the offer without a designator and learn the remote
  key from the handshake**: rejected because the channel's authorized remote
  (ADR-0105) must be fixed before the session runs, and the handshake proves a
  session key, never a durable identity.
- **Deliver the answer as a return value of `provide_offer` instead of a
  callback**: rejected because the Zig backend's answer is produced on the
  caller's thread but the C provider's exchange outlives the call, and one
  callback shape for every outbound signal keeps the application's forwarding
  code symmetric with `send_offer` and `send_candidate`.

## Consequences

`GlowcapWebrtcSignaling` grows a `send_answer` field, so every binding's
layout mirror, the generated constants, the header, and the archive
fingerprint change together. The Zig `SignalingAuthority` grows a required
`sendAnswer`, and the backend footprint grows by one pointer. The `dials`
exchange table becomes one table of exchanges with a role, and `drain_ready`
routes OPEN for an accept to `GLOWCAP_MULTIPLEXED_EV_ACCEPT` on the
listener's route. Callbacks run on the thread that steps the driver, and
`provide_offer` must be called on that thread.

## Evidence and gate

`zig build webrtc-internal-test` holds that `startAnswer` sends the answer
under the exchange fd with the offerer's designator, adopts a peer whose
authorized remote is the offerer's key, and commits nothing when the
designator is malformed, the sidecar refuses the offer, or the authority
cannot carry the answer. `zig build webrtc-loop` has every one of its
concurrent clients answered by the backend and checks that each accepted
session names its client's designator as an authenticated partner. `zig
build webrtc-redeem` has each exporter's backend answer the recipient's offer
through a loopback authority between two backends. The C provider's listen
verbs are held by `zig build webrtc-internal-test` against the scripted
sidecar and by `zig build webrtc-driver-provider` live, where the generic
driver listens on one loop and dials from another with the program carrying
only the signaling texts. `zig build rust-webrtc-driver-provider` has the
Rust binding accept the Zig offerer through `webrtc::listen` and checks that
the session names the offerer, then dials another listening Host in the same
process. The `gen-*-check` steps hold the generated surfaces.

## Notes

ADR-0226 (the managed dial this mirrors), ADR-0105 (the authorized remote
key), ADR-0112 (the driver archive and provider seam).
