# ADR-0086: Byte-Transparent Relay for Browser Peers

**Status:** Decided
**Date:** 2026-07-19
**Decision:** A browser peer reaches a native CapTP server through a
byte-transparent relay: an intermediary that forwards the raw session bytes
without parsing them, so the keyed handshake and session authority run end to
end unchanged. The relay is a first-class pancake capability, assembled in each
runtime from the pieces named below and governed by the contract in this ADR.
Its consistency across runtimes is enforced by a per-binding conformance test,
not by shared code, because one leg of the relay is always the host runtime's
own WebSocket server.

---

## Problem

Browser JavaScript cannot open a socket. A browser peer still needs to send and
receive OCapN frames over the network and to verify the keyed handshake with the
native server, so something has to carry its bytes. That carrier must be
transparent to CapTP: the peer and the server conduct the full handshake and
exchange capabilities as if directly connected, and the carrier learns nothing
it could use to impersonate either end.

The same need recurs in every server language a rooms-style UI might talk to. A
Deno, Python, Rust, or Zig server that hosts browser peers runs the same relay,
so the relay's semantics belong to pancake, stated once here, rather than being
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
pancake's; the code that fills them is each runtime's, and the cross-runtime
relay matrix (below) proves every runtime filled them the same way.

1. **A raw byte channel** to the target, `read() -> bytes | null`,
   `write(bytes)`, `close()` (idempotent). For an iroh target this is a pancake
   C-ABI primitive (below); for a TCP target it is the runtime's own socket,
   which is already byte-level and already backpressured by the kernel.
2. **The pump** that moves bytes between the two legs with the semantics below.
   It is roughly forty lines and lives in each binding, not in the C ABI,
   because it straddles the host runtime's WebSocket (which the C ABI cannot
   touch) and the byte channel.
3. **A WebSocket adapter** wiring an accepted WebSocket to the pump. The wiring
   is agnostic across JavaScript runtimes (any WHATWG `WebSocket`), which is why
   `@pancake/relay` ships it; producing the accepted socket is the host's own
   HTTP server, and another language re-implements the wiring against its own
   WebSocket type.
4. **A dial dispatcher** that classifies the target locator and opens the
   matching channel. The classification should run through the shared core
   primitive `pancake_host_plan_dial` (the same classifier the handoff
   redeem-dial uses), which sorts any locator into a `host_port` or `peer_id`
   shape, so every runtime's relay agrees. The Deno reference relay classifies
   locally today; exporting that classifier and routing dispatch through it is
   part of the cross-runtime build-out. The open is per-transport: a `host_port`
   opens the runtime's socket, a `peer_id` composes the iroh channel.
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
idempotent, so no session half-closes and no leg leaks. CapTP does not use
half-close, so full pair-close is the correct semantics.

**Byte-transparency and no capability.** The pump moves bytes and holds no
session object. It parses nothing.

**Backpressure on both legs.** Flow control is end to end only if *both* legs
can block their producer.

- The **target leg** blocks through the byte channel: a socket write blocks on
  the kernel, and the iroh C-ABI channel returns `WOULD_BLOCK` until writable.
  So a slow target slows the browser. This leg's backpressure is core: any
  binding that dials through the pancake channel gets it for free.
- The **browser-bound leg** must gate on the WebSocket's own send buffer. A
  `WebSocket` has no drain event, so the pump holds its next read until
  `bufferedAmount` (or the runtime's equivalent: Python `websockets`' awaited
  `send`, Rust `SinkExt::poll_ready`) falls below a high-water. **This gate is
  not optional.** A runtime whose WebSocket `write` returns before its send
  buffer drains has no browser-bound flow control and will grow server memory
  until the byte cap or idle timeout fires. The conformance harness asserts a
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
| Dial classification (shape, admission facts) | `pancake_host_plan_dial` | `driver_core` (sans-io) + `libpancake_driver` |
| iroh target open → raw byte channel | iroh C-ABI conn + readiness, composed per binding | `libpancake_net_transport_iroh` |
| TCP target open → raw byte channel | the runtime's own socket | binding-native |
| Pump semantics | this contract, one thin impl per runtime | per-binding, pinned by conformance |
| WebSocket / browser leg | the runtime's HTTP/WebSocket server | per-runtime |
| Target admission (allow-list, Origin, SSRF) | the embedding app | above pancake |

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
shared parameterized harness per proof — TCP forwarding (`bindings-relay`), the
backpressure clause (`bindings-relay`), and the iroh leg (`bindings-relay-iroh`)
— runs against every runtime's relay, so proving a new runtime's relay is a row,
never a forked test. The harness spawns the relay program named on its command
line and drives a browser-shaped peer through it; only the program and its ready
marker change per row.

## Scoping boundaries (honest facts)

- **Zig has no WebSocket server.** "Relay across a Zig server" needs a Zig
  WebSocket (or WebTransport) server built first. The other three server
  runtimes ship one.
- **Deno FFI has no native fd-readiness primitive.** The iroh channel is driven
  by a readiness fd that Rust (`AsyncFd`), Python (`add_reader`), and Racket (an
  fd thread) poll natively; Deno's iroh loop already solved this, so a Deno relay
  reuses that strategy rather than inventing a second one.
- **The C-ABI TCP conn is frame-level, not raw.** `pancake_tcp_conn_read_frame`
  delimits frames against a codec, which a relay cannot use. A TCP relay
  therefore opens the runtime's own socket, which is byte-level and needs no
  pancake wrapper.

## Threat Model

**SSRF.** A browser asking an open relay to dial an arbitrary `host:port` could
attack internal networks. The app's TCP allow-list admits only the room server's
own port. An iroh target is an `ocapn://` locator dialed over the iroh netlayer,
which reaches no local service a direct dial could not; a deployment that wants
to bound the iroh destination set pins it the same way.

**Session hijacking.** A relay sits on the wire path, so it could try to
eavesdrop or forge. The keyed handshake is signature-verified end to end, and
the relay cannot forge a signature without the peer's private key. A deployment
that does not trust its network runs TLS to the relay and keyed CapTP on top.

**Resource exhaustion.** Many sessions, or sessions held open forever. The
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

- **Shipped — Deno, Python, Rust, all three legs:** `zig build bindings-relay`
  proves TCP forwarding and the backpressure clause for the Deno reference relay
  (`bindings/ts/relay/serve.ts`), the Python relay (`bindings/python/relay.py`,
  `websockets` server), and the Rust relay (`bindings/rust/relay`,
  tokio-tungstenite). `zig build bindings-relay-iroh` proves the iroh leg for all
  three, each dialing a real iroh endpoint over QUIC — Deno and Python through the
  binding's `dial_locator_for_relay`, Rust through `IrohNetlayer::connect_owned`
  (behind an opt-in `iroh` feature so the TCP relay stays archive-free). A single
  runtime's cells are also addressable on their own (`deno-relay-test`,
  `python-relay-iroh-test`, and so on). Beyond the matrix, `rooms-web-relay-peer`,
  `rooms-web-browser-peer`, and `rooms-web-page` drive the room directory through
  the Deno relay with a real Chromium.
- **Racket relay (not built):** a Racket relay is a matrix row waiting on two
  pieces the other three runtimes already had. First, a WebSocket server: the
  pinned Racket toolchain ships none (`net/rfc6455` is a separate package that is
  not installed, and `web-server` has no WebSocket module), so the row needs
  either that package added to the devcontainer or a hand-rolled RFC 6455 server.
  Second, a bare iroh relay-channel dial: the Racket binding drives the iroh
  readiness loop for sessions but exposes no `dial-locator-for-relay` returning a
  raw byte channel, the way `@pancake/iroh`, the Python binding, and the Rust
  binding do. The contract-level pieces do exist — the iroh conn and readiness
  are C-ABI primitives the binding already drives, and the classifier is
  `pancake_host_plan_dial` — so once a WebSocket server is on hand the row is the
  shared harness plus a Racket pump.
- **A named `PancakeRelayChannel` C-ABI shape (not built):** iroh's raw conn plus
  its readiness already satisfy the byte-channel contract; naming them as one
  documented `PancakeRelayChannel` (readiness fd, pump, `try_read`/`try_write`
  with `WOULD_BLOCK`, close, release), and adding the same for `inproc` so
  in-tree conformance is transport-uniform, is the remaining C-ABI work.
- **Browser DMs through the relay (not built):** the allow-list admits no TCP
  target beyond the room server's own port, so the browser DM path is a stub.
- **Goblins through the relay (not built):** a live byte-transparency proof
  against a real Goblins peer has no build step.

## Alternatives Considered

**Proxy instead of relay.** Forward at the CapTP layer: parse, validate,
re-encode. Rejected: it adds protocol-interpretation risk and latency, couples
the relay version to the CapTP version, and defeats third-party handoff because
the proxy would have to route introductions.

**A single cross-transport relay-dial C-ABI symbol.** Rejected: it recouples the
à-la-carte transport archives and drags the iroh Rust sidecar into a TCP-only
relay. The classifier (`pancake_host_plan_dial`) is transport-neutral; the open
stays per-transport.

**A C-ABI pump.** Rejected: the pump straddles a runtime WebSocket the C ABI
cannot touch, so it would need per-runtime callbacks that invert
embedder-owns-the-loop, to move a forty-line accountant. The pump is a contract
pinned by conformance instead.

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

- **Reference implementation:** `@pancake/relay` (`bindings/ts/relay/`):
  `relayBytes` (the pump) and `webSocketRelay` (the WebSocket adapter), with the
  `RelayChannel` shape. The rooms endpoint that adds policy is
  `apps/rooms/deno/relay_server.ts`.
- **Shared classifier:** `pancake_host_plan_dial` (`src/driver/core/dial_plan.zig`,
  exported in `libpancake_driver`).
- **iroh byte channel:** the `pancake_iroh_*` conn and readiness primitives in
  `libpancake_net_transport_iroh`, driven identically by all four bindings.
- **Remaining work:** the relay item in [`docs/roadmap.md`](../../roadmap.md).
