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

The same need recurs in every server language a rooms-style UI might talk to. A
Deno, Python, Rust, or Zig server that hosts browser peers runs the same relay,
so the relay's semantics belong to glowcap, stated once here, rather than being
re-invented (and re-bugged) per runtime.

## The relay is byte-transparent by construction

The relay never parses a frame and never holds a capability. This is not a rule
a reviewer must remember; it is a property of the shape the relay is built from.
The relay only ever touches a **byte-level** channel, one that reads and writes
opaque `bytes`. It is never handed a frame-level channel (one that delimits
CapTP frames against a codec), because a frame-level channel would have to parse
the very stream the relay must stay blind to. Since the relay can only move
opaque bytes, it *cannot* read a capability off the wire or forge a handshake
signature: it lacks the peer's key and never sees a decoded message.

## The five parts each binding provides

A relay in any runtime is assembled from five pieces. Only the shapes are
glowcap's; the code that fills them is each runtime's, and the cross-runtime
relay matrix (below) proves every runtime filled them the same way.

1. **A raw byte channel** to the target, `read() -> bytes | null`,
   `write(bytes)`, and one idempotent result-bearing close barrier. For an iroh target this is a glowcap
   C-ABI primitive (below); for a TCP target it is the runtime's own socket,
   which is already byte-level and already backpressured by the kernel.
2. **The pump** that moves bytes between the two legs with the semantics below.
   It is roughly forty lines and lives in each binding, not in the C ABI,
   because it straddles the host runtime's WebSocket (which the C ABI cannot
   touch) and the byte channel.
3. **A WebSocket adapter** wiring an accepted WebSocket to the pump. The wiring
   is agnostic across JavaScript runtimes (any WHATWG `WebSocket`), which is why
   `@glowcap/relay` ships it; producing the accepted socket is the host's own
   HTTP server, and another language re-implements the wiring against its own
   WebSocket type.
4. **A dial dispatcher** that opens the matching channel for the target. A
   reference relay dispatches locally on which query parameter the browser's
   WebSocket URL carries: `?to=host:port` opens the runtime's socket,
   `?locator=<ocapn-uri>` composes the iroh channel. The transport-to-parameter
   choice is the browser peer's (`wsUrl`), so the relay reads no locator grammar
   and links no capability core, and iroh stays opt-in: the iroh binding loads
   lazily, only when a `?locator=` dial needs it. `source-check`
   (`checkReferenceRelayIrohLazy`) holds that lazy load for every reference
   relay, so a careless hoist to an eager import fails the gate. One relay
   classifies through the shared core instead: the rooms production relay already
   links the full stack, so it takes a single `?target=<locator>` and routes it
   through `glowcap_host_plan_dial` (the same classifier the handoff redeem-dial
   uses), which is where transport-symbol parsing and fail-closed-on-unknown
   live, because its target allow-list must sort a target exactly as the dial it
   admits will. A dependency-light reference relay must not, because routing a
   byte pump's classification through the core would link the capability library
   for one bit the parameter already carries, the fat entry point the constraints
   below reject.
5. **Config**: an idle timeout and a per-session byte cap. The app supplies the
   target admission policy separately.

## Pump semantics (the normative contract)

Every binding's pump must hold all of these. They are pinned by the cross-runtime
relay matrix (`zig build bindings-relay`): one shared harness proves the keyed
session and byte-transparency, a second proves the backpressure clause below
directly, and a third proves the idle timeout reclaims a silent pair — each run
against every runtime's relay.

**Pair-atomic lifetime.** Either leg ending, for any reason (EOF, error, the
byte cap, the idle timeout, or a clean close), tears both legs down: the channel
through `close()` and the WebSocket through the caller's closer. Both closes are
idempotent and joined before the pump returns; a refusal remains the result when
no earlier I/O failure exists, otherwise it is retained as a consequence. Thus
no session half-closes and no leg leaks. CapTP does not use
half-close, so full pair-close is the correct semantics.

**Byte-transparency and no capability.** The pump moves bytes and holds no
session object. It parses nothing.

**Backpressure on both legs.** Flow control is end to end only if *both* legs
can block their producer.

- The **target leg** blocks through the byte channel: a socket write blocks on
  the kernel, and the iroh C-ABI channel returns `WOULD_BLOCK` until writable.
  So a slow target slows the browser. This leg's backpressure is core: any
  binding that dials through the glowcap channel gets it for free.
- The **browser-bound leg** must gate on the WebSocket's own send buffer. A
  `WebSocket` has no drain event, so the pump holds its next read until
  `bufferedAmount` (or the runtime's equivalent: Python `websockets`' awaited
  `send`, Rust `SinkExt::poll_ready`) falls below a high-water. **This gate is
  not optional.** A runtime whose WebSocket `write` returns before its send
  buffer drains has no browser-bound flow control and will grow server memory
  until the byte cap or idle timeout fires. The relay contract harness asserts a
  stalled reader stalls the far sender, precisely to catch a runtime that skipped
  this gate: it floods a stalled reader through the relay under test and fails if
  the sender is not backpressured. The matrix runs it against every runtime's
  relay, so no binding can ship without the assertion.

**Bounded resources.** The idle timeout reclaims a stalled pair; the byte cap
ends a session that streams without bound; instantaneous memory is bounded by
the backpressure above, so the byte cap is a runaway backstop over a session's
life, not a memory bound. The idle-timeout harness pins the reclaim directly: a
silent pair whose idle timer is set low must be torn down, so a runtime that
dropped the timeout fails. Beyond these the relay stays minimal: no rate limiter,
no circuit breaker, no metrics surface. A deployment that needs those runs its
own front tier ahead of the relay.

**Admission is app policy, never relay policy.** The relay enforces no CapTP
policy. Which targets may be dialed (a TCP allow-list, an `Origin` check, an
iroh destination policy) is the embedding app's decision, made over the
classifier's transport/shape output, before the pump starts. It never lives in
the relay core, and it never migrates into the session or codec layer.

## Where each piece lives

| Concern | Owner | Layer |
| --- | --- | --- |
| Dial classification (shape, admission facts) | `glowcap_host_plan_dial` | `driver_core` (sans-io) + `libglowcap_driver` |
| iroh target open → raw byte channel | iroh C-ABI conn + readiness, composed per binding | `libglowcap_net_transport_iroh` |
| TCP target open → raw byte channel | the runtime's own socket | binding-native |
| Pump semantics | this contract, one thin impl per runtime | per-binding, pinned by conformance |
| WebSocket / browser leg | the runtime's HTTP/WebSocket server | per-runtime |
| Target admission (allow-list, Origin, open dial) | the embedding app | above glowcap |

There is deliberately **no** single cross-transport relay-dial entry point. One
symbol routing every transport would link every transport archive, dragging the
iroh Rust sidecar into even a TCP-only relay and breaking the à-la-carte archive
split (ADR-0059). Transport-neutrality is in the channel *shape* and the shared
classifier, not in a fat entry point.

## Consistency is a gate, not a library

Because the pump straddles a runtime WebSocket, it cannot be shared C-ABI code
without per-runtime callbacks that would invert the embedder-owns-the-loop model
the byte-fed Host rests on (ADR-0072, ADR-0057). So the relay is made consistent
the same way the live Goblins conversation is: a per-runtime conformance matrix.
The `bindings-goblins-interop` family swaps the consumer language per row and
proves the same wire behavior by exit code; the relay matrix does the same. One
shared parameterized harness per proof — TCP forwarding, the backpressure clause,
and the idle-timeout reclaim, each under `zig build bindings-relay`, plus the iroh
leg under `zig build bindings-relay-iroh` — runs against every runtime's relay, so
proving a new runtime's relay is a row, never a forked test. The harness spawns the relay program named on its command
line and drives a browser-shaped peer through it; only the program and its ready
marker change per row.

## Scoping boundaries

- **Zig has no WebSocket server.** "Relay across a Zig server" needs a Zig
  WebSocket (or WebTransport) server built first. The other three server
  runtimes ship one.
- **Deno FFI has no native fd-readiness primitive.** The iroh channel is driven
  by a readiness fd that Rust (`AsyncFd`), Python (`add_reader`), and Racket (an
  fd thread) poll natively; Deno's iroh loop already solved this, so a Deno relay
  reuses that strategy rather than inventing a second one.
- **The C-ABI TCP and inproc conns are frame-level, not raw.**
  `glowcap_tcp_conn_read_frame` and `glowcap_inproc_conn_read_frame` delimit
  frames against a codec, which a relay cannot use. A TCP relay therefore opens
  the runtime's own socket, which is byte-level and needs no glowcap wrapper.
- **iroh is the only transport that supplies a relay byte channel.** The other
  legs a relay opens are the runtime's own socket and, for the cold-dial
  rendezvous, a held WebSocket. So the channel is a shape each binding fills in
  its own language, not a C-ABI object. The rejected shape below says why.

## Relay bounds

**Open dial.** A browser asking an open relay to dial an arbitrary `host:port` could
reach private networks. The app's TCP allow-list admits only the room server's
own port. An iroh target is an `ocapn://` locator dialed over the iroh netlayer,
which reaches no local service a direct dial could not; a deployment that wants
to bound the iroh destination set pins it the same way.

**Wire position.** A relay sits on the wire path, so it could try to
eavesdrop or forge. The keyed handshake is signature-verified end to end, and
the relay cannot forge a signature without the peer's private key. A deployment
that does not trust its network runs TLS to the relay and keyed CapTP on top.

**Resource pressure.** Many sessions, or sessions held open forever. The
live-session cap refuses new upgrades when full, the idle timeout reclaims
stalled pairs, and the backpressure plus byte cap bound a streaming session.

**Authorization creep.** The temptation is to teach the relay a capability
policy ("only allow FooCapability"). Do not. The relay forwards bytes;
capabilities are validated by the session layer. Relay-side policy would couple
every CapTP change to a relay change and open a new class of bugs.

## Status and proof matrix

The relay matrix is the authority for which runtime is proven; the rows live in
`build.zig`, not as a hand-maintained list here. Each cell is one shared harness
against one runtime's relay, so this ADR names the shape and points at the gate.

- **Shipped — Deno, Python, Rust, Racket, all three legs:** `zig build
  bindings-relay` proves TCP forwarding, the backpressure clause, and the
  idle-timeout bounded-resources clause for the Deno reference relay
  (`bindings/ts/relay/serve.ts`), the Python relay (`bindings/python/relay.py`,
  `websockets` server), the Rust relay (`bindings/rust/relay`,
  tokio-tungstenite), and the Racket relay (`bindings/racket/relay.rkt`,
  `net/rfc6455` server). `zig build bindings-relay-iroh` proves the iroh leg for
  all four, each dialing a real iroh endpoint over QUIC — Deno, Python, and
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
  `glowcap_net_transport_iroh.h` instead, which is the part of that idea that was
  true.
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
relay. The classifier (`glowcap_host_plan_dial`) is transport-neutral; the open
stays per-transport.

**A C-ABI pump.** Rejected, and not for a callback reason: the byte-fed Host
(`feed`/`takeOutbound`, ADR-0072) shows a native core can be pull-based with no
callbacks, so a pump could be shaped the same way without inverting who owns the
loop. It is rejected because the browser-facing leg is a WebSocket glowcap cannot
own. Only the runtime that owns that socket can pause its reads, so the
browser-bound backpressure has to live in the runtime however the pump is
packaged. A native pump would export a cross-ABI high-water signal the runtime
consults before every read, which is strictly more work than the runtime's own
awaited write (or its `bufferedAmount` poll, since a WebSocket has no drain
event). The pump also holds no capability and parses nothing, so writing it once
protects no invariant the shared relay harness does not already pin. And a
native pump with real backpressure would have to own a far leg to reuse the
completion loop's high-water parking, linking a transport archive into every
relay and dragging the iroh sidecar into a TCP-only one, the à-la-carte split
(ADR-0059) this ADR rejects elsewhere. The pump stays a per-runtime contract
pinned by the relay matrix; the byte channel it pumps over is named as a set of calls
in the iroh header, not as a C object (the alternative below).

**A named `GlowcapRelayChannel` C-ABI shape.** Rejected, whether as a struct of
per-transport function pointers, an opaque handle with its own verb family, or a
typedef plus per-transport adapters. Three facts defeat all three variants.

First, readiness cannot cross the ABI as a call. A channel is usable only once
its owner can *wait* on it, and that wait is the runtime's own reactor. So every
binding would still write the half that decides when to read, and Rust would
still want `AsyncRead`/`AsyncWrite` over a glowcap object.

Second, the legs are not one kind. A relay opens the runtime's socket for a TCP
target and a held WebSocket for the cold-dial rendezvous, and only the iroh leg
comes from glowcap at all. A cross-transport shape would have one member.

Third, `inproc` cannot honestly be the second member. Its resident carries no
file descriptor by design, and its pipes are unbounded because a mock has a
cooperative partner, so an inproc channel would advertise the backpressure clause
above while structurally lacking it. No relay could dial one either, since the
target would have to be a peer inside the relay's own process.

What the idea got right was discoverability, so
`glowcap_net_transport_iroh.h` names the calls a relay leg composes as a set.

**A blocking-with-thread channel.** Rejected: a thread per relay session
contradicts the one-loop-serves-many-connections model (ADR-0057) and the
connection footprint budget. The channel is readiness-driven, like the iroh conn
already is.

**WebRTC data channel.** Direct browser-to-browser over WebRTC is ADR-0070
Milestone 2. It complements the relay (the relay is still the path to a native
server) and does not replace it. WebTransport is a possible future browser-leg
adapter; the contract is already defined over an abstract byte duplex, not over
`WebSocket`, so a second adapter needs no contract change.

## References

- **Reference implementation:** `@glowcap/relay` (`bindings/ts/relay/`):
  `relayBytes` (the pump) and `webSocketRelay` (the WebSocket adapter), with the
  `RelayChannel` shape. The rooms endpoint that adds policy is
  `apps/rooms/rust/services/src/web/relay.rs`.
- **Rooms target admission:** the native relay uses glowcap locator and
  host/port parsing, admits the resulting endpoint, and transfers that selected
  target to the byte-channel dial job. The relay owns deployment admission;
  CapTP negotiation and peer authentication remain with the endpoints.
- **iroh byte channel:** the `glowcap_iroh_*` conn and readiness primitives in
  `libglowcap_net_transport_iroh`, named as a set in
  `include/glowcap_net_transport_iroh.h` and driven identically by all four
  bindings.
