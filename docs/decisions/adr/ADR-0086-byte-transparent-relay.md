---
id: ADR-0086
status: accepted
date: 2026-07-19
tags: [relay, browser, transport, websocket, bindings]
decision: "A browser peer reaches a native CapTP server through a byte-transparent relay: an intermediary that forwards the raw session bytes without parsing them, so the keyed handshake and session authority run end to end unchanged. The relay is a first-class glowcap capability, assembled in each runtime from the pieces named below and governed by the contract in this ADR. Its consistency across runtimes is enforced by a per-binding contract test, not by shared code, because one leg of the relay is always the host runtime's own WebSocket server."
supersedes: []
superseded_by: []
amends: []
amended_by: [ADR-0117, ADR-0143]
---

# ADR-0086 Byte-transparent relay for browser peers

## Decision

A browser peer reaches a native CapTP server through a byte-transparent relay:
an intermediary that forwards the raw session bytes without parsing them, so the
keyed handshake and session authority run end to end unchanged. The relay is a
first-class glowcap capability, assembled in each runtime from the pieces named
below and governed by the contract in this ADR. Its consistency across runtimes
is enforced by a per-binding contract test, not by shared code, because one
leg of the relay is always the host runtime's own WebSocket server.

## Problem

Browser JavaScript cannot open a socket. A browser peer still needs to send and
receive OCapN frames over the network and to verify the keyed handshake with the
native server, so something has to carry its bytes. That carrier must be
transparent to CapTP: the peer and the server conduct the full handshake and
exchange capabilities as if directly connected, and the carrier learns nothing
it could use to impersonate either end.

A Deno, Python, Rust, or Zig server that hosts browser peers runs the same
relay, so its semantics belong to glowcap and are stated once here.

## The relay is byte-transparent by construction

The relay never parses a frame and never holds a capability, by the shape it is
built from. It only touches a **byte-level** channel, one that reads and writes
opaque `bytes`. A frame-level channel (one that delimits CapTP frames against a
codec) would have to parse the stream the relay must stay blind to. A relay that
moves only opaque bytes cannot read a capability off the wire or forge a
handshake signature: it lacks the peer's key and never sees a decoded message.

## The five parts each binding provides

A relay in any runtime is assembled from five pieces. The shapes are glowcap's,
the code that fills them is each runtime's, and the cross-runtime relay matrix
proves every runtime filled them the same way.

1. **A raw byte channel** to the target, `read() -> bytes | null`,
   `write(bytes)`, and one idempotent result-bearing close barrier. For an iroh
   target this is a glowcap C-ABI primitive. For a TCP target it is the
   runtime's own socket, which is already byte-level and already backpressured
   by the kernel.
2. **The pump** that moves bytes between the two legs with the semantics below.
   It lives in each binding, not in the C ABI, because it straddles the host
   runtime's WebSocket (which the C ABI cannot touch) and the byte channel.
3. **A WebSocket adapter** wiring an accepted WebSocket to the pump. The wiring
   works with any WHATWG `WebSocket`, so `@glowcap/relay` ships it. Producing
   the accepted socket is the host's own HTTP server, and another language
   re-implements the wiring against its own WebSocket type.
4. **A dial dispatcher** that opens the matching channel for the target. A
   reference relay dispatches on which query parameter the browser's WebSocket
   URL carries: `?to=host:port` opens the runtime's socket, `?locator=<ocapn-uri>`
   composes the iroh channel. The browser peer chooses the parameter (`wsUrl`),
   so the relay reads no locator grammar and links no capability core, and iroh
   stays opt-in: the iroh binding loads lazily, only when a `?locator=` dial
   needs it. `source-check` (`checkReferenceRelayIrohLazy`) holds that lazy load
   for every reference relay. The rooms production relay classifies through the
   shared core instead: it already links the full stack, so it takes a single
   `?target=<locator>` and routes it through `glowcap_host_plan_dial` (the
   classifier the handoff redeem-dial uses), which owns transport-symbol parsing
   and fail-closed-on-unknown, because its target allow-list must sort a target
   as the dial it admits will. A dependency-light reference relay must not
   classify through the core, since that would link the capability library for
   one bit the parameter already carries.
5. **Config**: an idle timeout and a per-session byte cap. The app supplies the
   target admission policy separately.

## Pump semantics (the normative contract)

Every binding's pump holds all of these. The cross-runtime relay matrix
(`zig build bindings-relay`) pins them: one shared harness proves the keyed
session and byte-transparency, a second proves the backpressure clause, and a
third proves the idle timeout reclaims a silent pair, each run against every
runtime's relay.

**Pair-atomic lifetime.** Either leg ending, for any reason (EOF, error, the
byte cap, the idle timeout, or a clean close), tears both legs down: the channel
through `close()` and the WebSocket through the caller's closer. Both closes are
idempotent and joined before the pump returns. A refusal remains the result when
no earlier I/O failure exists, otherwise it is retained as a consequence. No session
half-closes and no leg leaks. CapTP does not use half-close.

**Byte-transparency and no capability.** The pump moves bytes and holds no
session object. It parses nothing.

**Backpressure on both legs.** Flow control is end to end only if both legs can
block their producer.

- The **target leg** blocks through the byte channel: a socket write blocks on
  the kernel, and the iroh C-ABI channel returns `WOULD_BLOCK` until writable.
  So a slow target slows the browser. This leg's backpressure is core: any
  binding that dials through the glowcap channel gets it for free.
- The **browser-bound leg** must gate on the WebSocket's own send buffer. A
  `WebSocket` has no drain event, so the pump holds its next read until
  `bufferedAmount` (or the runtime's equivalent: Python `websockets`' awaited
  `send`, Rust `SinkExt::poll_ready`) falls below a high-water. A runtime whose
  WebSocket `write` returns before its send buffer drains has no browser-bound
  flow control and grows server memory until the byte cap or idle timeout fires.
  The relay contract harness floods a stalled reader through the relay under
  test and fails if the sender is not backpressured. The matrix runs it against
  every runtime's relay.

**Bounded resources.** The idle timeout reclaims a stalled pair. The byte cap
ends a session that streams without bound. Instantaneous memory is bounded by
the backpressure above, so the byte cap is a runaway backstop over a session's
life, not a memory bound. The idle-timeout harness tears down a silent pair
whose idle timer is set low, so a runtime that dropped the timeout fails. The
relay has no rate limiter, circuit breaker, or metrics surface. A deployment
that needs those runs its own front tier ahead of it.

**Admission is app policy.** The relay enforces no CapTP policy. Which targets
may be dialed (a TCP allow-list, an `Origin` check, an iroh destination policy)
is the embedding app's decision, made over the classifier's transport/shape
output before the pump starts. It does not live in the relay core or in the
session or codec layer.

## Where each piece lives

| Concern | Owner | Layer |
| --- | --- | --- |
| Dial classification (shape, admission facts) | `glowcap_host_plan_dial` | `driver_core` (sans-io) + `libglowcap_driver` |
| iroh target open → raw byte channel | iroh C-ABI conn + readiness, composed per binding | `libglowcap_net_transport_iroh` |
| TCP target open → raw byte channel | the runtime's own socket | binding-native |
| Pump semantics | this contract, one thin impl per runtime | per-binding, pinned by conformance |
| WebSocket / browser leg | the runtime's HTTP/WebSocket server | per-runtime |
| Target admission (allow-list, Origin, open dial) | the embedding app | above glowcap |

There is no single cross-transport relay-dial entry point. One symbol routing
every transport would link every transport archive, dragging the iroh Rust
sidecar into a TCP-only relay and breaking the à-la-carte archive split
(ADR-0059). Transport-neutrality lives in the channel shape and the shared
classifier.

## Consistency is a gate, not a library

The pump straddles a runtime WebSocket, so it cannot be shared C-ABI code
without per-runtime callbacks that would invert the embedder-owns-the-loop model
the byte-fed Host rests on (ADR-0072, ADR-0057). The relay is made consistent as
the live Goblins conversation is, by a per-runtime conformance matrix: the
`bindings-goblins-interop` family swaps the consumer language per row, and the
relay matrix does the same. One parameterized harness per proof (TCP forwarding,
the backpressure clause, and the idle-timeout reclaim under
`zig build bindings-relay`, plus the iroh leg under
`zig build bindings-relay-iroh`) runs against every runtime's relay, so a new
runtime's relay is a row, not a forked test. The harness spawns the relay
program named on its command line and drives a browser-shaped peer through it.
Only the program and its ready marker change per row.

## Scoping boundaries

- **Zig has no WebSocket server.** "Relay across a Zig server" needs a Zig
  WebSocket (or WebTransport) server built first. The other three server
  runtimes ship one.
- **Deno FFI has no native fd-readiness primitive.** The iroh channel is driven
  by a readiness fd that Rust (`AsyncFd`), Python (`add_reader`), and Racket (an
  fd thread) poll natively. A Deno relay reuses Deno's iroh loop strategy.
- **The C-ABI TCP and inproc conns are frame-level, not raw.**
  `glowcap_tcp_conn_read_frame` and `glowcap_inproc_conn_read_frame` delimit
  frames against a codec, which a relay cannot use. A TCP relay therefore opens
  the runtime's own socket, which is byte-level and needs no glowcap wrapper.
- **iroh is the only transport that supplies a relay byte channel.** The other
  legs a relay opens are the runtime's own socket and, for the cold-dial
  rendezvous, a held WebSocket. So the channel is a shape each binding fills in
  its own language, not a C-ABI object (see Alternatives).

## Relay bounds

**Open dial.** A browser asking an open relay to dial an arbitrary `host:port`
could reach private networks. The app's TCP allow-list admits only the room server's
own port. An iroh target is an `ocapn://` locator dialed over the iroh netlayer,
which reaches no local service a direct dial could not. A deployment that wants
to bound the iroh destination set pins it the same way.

**Wire position.** A relay sits on the wire path, so it could try to
eavesdrop or forge. The keyed handshake is signature-verified end to end, and
the relay cannot forge a signature without the peer's private key. A deployment
that does not trust its network runs TLS to the relay and keyed CapTP on top.

**Resource pressure.** Many sessions, or sessions held open forever. The
live-session cap refuses new upgrades when full, the idle timeout reclaims
stalled pairs, and the backpressure plus byte cap bound a streaming session.

**Authorization creep.** The relay does not take a capability policy ("only
allow FooCapability"). It forwards bytes, and the session layer validates
capabilities. Relay-side policy would couple every CapTP change to a relay
change.

## Status and proof matrix

The relay matrix in `build.zig` is the authority for which runtime is proven.
Each cell is one shared harness against one runtime's relay.

- **Shipped (Deno, Python, Rust, Racket, all three legs):** `zig build
  bindings-relay` proves TCP forwarding, the backpressure clause, and the
  idle-timeout bounded-resources clause for the Deno reference relay
  (`bindings/ts/relay/serve.ts`), the Python relay (`bindings/python/relay.py`,
  `websockets` server), the Rust relay (`bindings/rust/relay`,
  tokio-tungstenite), and the Racket relay (`bindings/racket/relay.rkt`,
  `net/rfc6455` server). `zig build bindings-relay-iroh` proves the iroh leg for
  all four, each dialing a real iroh endpoint over QUIC: Deno, Python, and
  Racket through the binding's `dial_locator_for_relay` (`dial-locator-for-relay`
  in Racket), Rust through `Netlayer::connect_owned` (behind an opt-in `iroh`
  feature so the TCP relay stays archive-free). A single runtime's cells are also
  addressable on their own (`deno-relay-test`, `python-relay-iroh-test`,
  `racket-relay-idle-test`, and so on). Beyond the matrix,
  `rooms-web-relay-peer` drives the room directory through the relay from the
  standalone Web binding, while `rooms-web-page` drives the shipped Rust
  browser application through it in real Chromium.
- **A named `GlowcapRelayChannel` C-ABI shape: rejected,** for the reasons in
  Alternatives below. The iroh calls a relay leg composes are named as a set in
  `glowcap_net_transport_iroh.h` instead.
- **Browser DMs through the relay (shipped over the iroh leg):** a browser
  redeems a room introduction and dials the member over the relay's iroh path,
  the room out of the message path (`zig build rooms-web-dm`, and
  [ADR-0088](ADR-0088-fully-functioning-browser-peer.md)). The TCP relay leg
  still admits only the room server's own port, so browser DM rides the iroh
  leg, not a TCP target.
- **Goblins through the relay (shipped):** a browser peer holds a keyed OCapN
  session with a real Goblins vat through the reference relay, and the echo
  round-trip plus the repeat-enliven dedup ride it
  (`zig build goblins-relay`).

## Alternatives Considered

**Proxy instead of relay.** Forward at the CapTP layer: parse, validate,
re-encode. Rejected: it adds protocol-interpretation risk and latency, couples
the relay version to the CapTP version, and defeats third-party handoff because
the proxy would have to route introductions.

**A single cross-transport relay-dial C-ABI symbol.** Rejected: it recouples the
à-la-carte transport archives and drags the iroh Rust sidecar into a TCP-only
relay. The classifier (`glowcap_host_plan_dial`) is transport-neutral. The open
stays per-transport.

**A C-ABI pump.** Rejected. The byte-fed Host (`feed`/`takeOutbound`, ADR-0072)
shows a native core can be pull-based, so the callback model is not the
obstacle. The browser-facing leg is a WebSocket glowcap cannot own, and only the
runtime that owns that socket can pause its reads, so browser-bound backpressure
lives in the runtime however the pump is packaged. A native pump would export a
cross-ABI high-water signal the runtime consults before every read, which is
more work than the runtime's own awaited write (or its `bufferedAmount` poll,
since a WebSocket has no drain event). The pump holds no capability and parses
nothing, so writing it once protects no invariant the shared relay harness does
not pin. A native pump with real backpressure would also have to own a far leg
to reuse the completion loop's high-water parking, linking a transport archive
into every relay (the ADR-0059 split). The byte channel it pumps over is named
as a set of calls in the iroh header, not as a C object.

**A named `GlowcapRelayChannel` C-ABI shape.** Rejected, whether as a struct of
per-transport function pointers, an opaque handle with its own verb family, or a
typedef plus per-transport adapters. Three facts defeat every variant.

First, readiness cannot cross the ABI as a call. A channel is usable only once
its owner can *wait* on it, and that wait is the runtime's own reactor. So every
binding would still write the half that decides when to read, and Rust would
still want `AsyncRead`/`AsyncWrite` over a glowcap object.

Second, the legs are not one kind. A relay opens the runtime's socket for a TCP
target and a held WebSocket for the cold-dial rendezvous, and only the iroh leg
comes from glowcap at all. A cross-transport shape would have one member.

Third, `inproc` cannot be the second member. Its resident carries no file
descriptor, and its pipes are unbounded because a mock has a cooperative
partner, so an inproc channel would advertise the backpressure clause while
lacking it. No relay could dial one either, since the target would have to be a
peer inside the relay's own process.

For discoverability, `glowcap_net_transport_iroh.h` names the calls a relay leg
composes as a set.

**A blocking-with-thread channel.** Rejected: a thread per relay session
contradicts the one-loop-serves-many-connections model (ADR-0057) and the
connection footprint budget. The channel is readiness-driven, like the iroh
conn.

**WebRTC data channel.** Direct browser-to-browser over WebRTC is ADR-0070
Milestone 2. It complements the relay, which stays the path to a native server.
WebTransport could serve as a second browser-leg adapter. The contract is
defined over an abstract byte duplex, not over `WebSocket`, so a second adapter
needs no contract change.

## References

- **Reference implementation:** `@glowcap/relay` (`bindings/ts/relay/`):
  `relayBytes` (the pump) and `webSocketRelay` (the WebSocket adapter), with the
  `RelayChannel` shape. The rooms endpoint that adds policy is
  `apps/rooms/rust/services/src/web/relay.rs`.
- **Rooms target admission:** the native relay uses glowcap locator and
  host/port parsing, admits the resulting endpoint, and transfers that selected
  target to the byte-channel dial job. The relay owns deployment admission.
  CapTP negotiation and peer authentication remain with the endpoints.
- **iroh byte channel:** the `glowcap_iroh_*` conn and readiness primitives in
  `libglowcap_net_transport_iroh`, named as a set in
  `include/glowcap_net_transport_iroh.h` and driven identically by all four
  bindings.
