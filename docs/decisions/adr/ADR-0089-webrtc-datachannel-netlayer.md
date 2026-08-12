---
id: ADR-0089
status: accepted
date: 2026-07-21
tags: [transport, webrtc, browser, signaling, sidecar, handoff]
decision: "pancake gains a `webrtc` transport: a reliable, ordered WebRTC DataChannel that carries a keyed OCapN session byte-for-byte between two peers, at least one of which is a browser. The transport is a native Rust sidecar over the `webrtc` crate (the same shape as the iroh sidecar, ADR-0055), a Zig netlayer resident over its C ABI, a companion archive `libpancake_net_transport_webrtc` (ADR-0059), and a browser `RTCPeerConnection`/`RTCDataChannel` arm. The signaling that WebRTC needs, the SDP offer/answer and ICE candidates, is exchanged through an OCapN capability rather than a bespoke signaling server."
supersedes: []
superseded_by: []
amends: []
amended_by: [ADR-0110]
---

# ADR-0089 WebRTC DataChannel netlayer

> **Framing amendment (ADR-0110).** Each reliable, ordered DataChannel message
> carries one bare codec frame. The outer Syrup byte-string envelope is only
> for byte-stream transports.

> **Implementation standing.** Decided and implemented. The standalone dial
> ships in the TypeScript stack: a host configured with signaling authority
> (`Host.setSignaling`) dials a bare `webrtc` locator through the one dial path,
> proven by `zig build webrtc-browser-to-browser`; handoff redemption over it is
> proven live by `zig build rooms-web-dm-webrtc`, with the room directory
> carrying the signaling. The native completion tier ships too:
> `completion.Loop(webrtc.Backend)` adopts signaled peers and dials through a
> configured `SignalingAuthority` under `driver.Bridge` and the generic Host,
> proven by `zig build webrtc-loop`, and the native three-party redeem over a
> bare `webrtc` give is proven by `zig build webrtc-bridge-redeem`.

## Decision

pancake gains a `webrtc` transport: a reliable, ordered WebRTC
DataChannel that carries a keyed OCapN session byte-for-byte between two peers,
at least one of which is a browser. The transport is a native Rust sidecar over
the `webrtc` crate (the same shape as the iroh sidecar, ADR-0055), a Zig
netlayer resident over its C ABI, a companion archive
`libpancake_net_transport_webrtc` (ADR-0059), and a browser
`RTCPeerConnection`/`RTCDataChannel` arm. The signaling that WebRTC needs, the
SDP offer/answer and ICE candidates, is exchanged through an OCapN capability
rather than a bespoke signaling server. In the TypeScript stack the dial
executor composes the whole bring-up: a host configured with signaling authority
dials a bare `webrtc` locator, and connect and handoff-redeem share that one
path. The native completion tier holds the same shape, with `webrtc.Backend`
adopting signaled peers and dialing through a configured authority under the
generic Host. The standing note above names the check that proves each half.

This ADR builds on the iroh netlayer sidecar
([ADR-0055](ADR-0055-iroh-netlayer-sidecar.md)), the à-la-carte transport
archive split ([ADR-0059](ADR-0059-composable-c-abi-archives.md)), the browser
binding ([ADR-0070](ADR-0070-browser-binding-via-wasm.md), whose Milestone 2
this is), the byte-transparent relay
([ADR-0086](ADR-0086-byte-transparent-relay.md)), and the fully-functioning
browser peer ([ADR-0088](ADR-0088-fully-functioning-browser-peer.md)).

## Problem

A browser cannot open a listening socket, so ADR-0088 left a browser reachable
only two ways: over a session the browser itself dialed, or through a relay
rendezvous that forwards its bytes. Both route the byte path through an
intermediary for the browser's whole conversation. Two browsers talking to each
other therefore run every frame through a server that sits on the wire for the
life of the session.

WebRTC removes the intermediary from the byte path. Its signaling is small and
transient: two peers exchange an SDP offer and answer plus a handful of ICE
candidates, and from then on the DTLS-encrypted DataChannel runs peer to peer.
An intermediary is touched only during signaling (always) and only as a byte
relay when ICE cannot find a direct path through NAT (the fallback). This is the
one transport that makes a browser cold-dialable and makes two browsers direct
peers, and it keeps the steady-state byte path off any server pancake runs.

WebTransport does not solve this: it is client-only, so it makes neither a
browser cold-dialable nor two browsers direct peers. The "Alternatives
Considered" section says where it could still serve.

## The transport stack, layer by layer

The `webrtc` netlayer reuses the iroh netlayer's proven decomposition. Each
piece is classified against the layer it lives in.

- **Native Rust sidecar (`transports/webrtc/`).** A separate crate wraps the
  `webrtc` crate behind a narrow C ABI, exactly as `transports/iroh/` wraps
  iroh (ADR-0055). `libpancake` and the core stay pure Zig; only the `webrtc-*`
  build steps need cargo on PATH, the same sibling-step posture as the Rust
  dogfood. One endpoint owns a two-worker Tokio runtime and readiness fd shared
  by all of its peers. Peer creation and signaling submissions are synchronous
  control operations. Once submitted, channel establishment, candidates, byte
  I/O, and closure surface as stable peer-id readiness events with non-blocking
  try-I/O, so one reactor can serve many DataChannels. The private blocking byte
  calls exist only for the native `BlockingSession` adapter. Readiness uses a
  coalescing self-pipe: a discarded `WouldBlock` write cannot lose a wake because
  a full pipe is already poll-readable. That one `nudge` operation serves both
  event publication and the re-wake after a short record drain, and the fd
  exposed to callers has its write direction shut down. Its `Cargo.lock` is
  committed, like iroh's, because the
  `webrtc` crate pulls a large transitive tree (DTLS, SCTP, ICE, STUN, SDP) that
  must resolve identically on every machine.

- **Zig resident (`src/net/transport/webrtc.zig`).** One resident owns the
  sidecar endpoint and presents an established peer either as readiness-driven
  try-I/O or as the `net.Connection` contract (ADR-0043) for the explicit
  blocking tier. It is compiled as its own
  module outside the `pancake` root namespace, so its externs resolve only when
  the staticlib links, and a plain `zig build check` type-checks it as an
  object without cargo. Its completion backend accepts answers, candidates, and
  adopted peers from foreign signaling threads through a bounded wake-driven
  inbox. Signaling bytes copy into a fixed 4 MiB endpoint-level transfer pool
  allocated during backend initialization; foreign threads never enter the
  caller's potentially single-threaded allocator, and a full inbox reports
  `WouldBlock` instead of growing behind the reactor.

- **C ABI companion archive (`libpancake_net_transport_webrtc`).** The public
  frame-level ABI ships as its own archive under
  `src/c_abi/net_transport/webrtc/`, exporting only its own pancake_webrtc_*
  symbol family and reusing `c_abi/shared` by layout (ADR-0059). It links the
  Rust sidecar, so it sits outside the layer DAG (`.graph = false`) like the
  iroh companion, and its header is reflected from its own root by a
  gen-header-net-transport-webrtc generator mirroring the iroh one.

- **Browser arm (`bindings/ts/webrtc`).** A new `@pancake/webrtc` package holds
  the browser's `RTCPeerConnection`/`RTCDataChannel` half, the peer of the
  native sidecar. It composes with the browser binding (ADR-0070): the wasm Host
  runs the keyed session, and this arm provides the byte duplex the session runs
  over, the same seam `@pancake/web`'s WebSocket channel fills for the relay
  path. Two browsers each run this arm and speak directly; a browser and a
  native peer each run their own half.

The DataChannel never parses a frame. The keyed CapTP session runs end to end on
top of it, exactly as ADR-0086's relay leg carries opaque bytes. This is the
same byte-transparency contract, now over a peer-to-peer channel instead of a
forwarded one.

## The `webrtc` locator and peer identity

`webrtc` is a new netlayer transport symbol, alongside `tcp`, `keyed-tcp`,
`inproc`, and `iroh`. CapTP itself never names a transport (architecture rule);
the symbol lives only in locators and in the netlayer dispatch.

A peer is named by its Ed25519 designator, the same posture keyed-tcp and iroh
already hold. The DataChannel's DTLS layer authenticates the channel against a
self-signed certificate fingerprint carried in the SDP; the OCapN keyed
handshake then runs over the open channel and is the authority for peer
identity, exactly as it is over iroh's QUIC. The DTLS fingerprint binds the two
ends of *this* channel together so signaling cannot be man-in-the-middled into a
different channel; the keyed handshake binds the channel to the *designator*.
Neither replaces the other: DTLS secures the pipe, the keyed handshake proves
who is on the far end of it.

A bare `webrtc` locator names the designator but carries no authority through
which to signal it. The application supplies that authority on the dialing
host (`Host.setSignaling`), and the dial executor performs the composition:
the dial classifier's `signaling` shape routes to the exchange rather than a
socket, while a resident deliberately exposes no fake address-based `dial` or
`listen` method. A host with no configured authority refuses the dial.

## OCapN-native signaling

WebRTC needs a signaling channel to exchange the offer, the answer, and ICE
candidates before the DataChannel opens. pancake already has a signaling
channel: the capability graph. Introductions flow through it as the three-party
handoff, and the browser cold-dial rendezvous (ADR-0088) already routes a
browser's reachability through a room. Signaling is the same shape, so it uses
the same mechanism rather than a bespoke server.

**The signaling capability.** A peer that wants to be reached over `webrtc`
holds, or is introduced to, a signaling object. Its shape is a small, sync
capability with two directions of message:

- `offer(designator, sdp)` delivers the initiator's SDP offer to the target and
  returns (as a promise, or via a paired `answer` call back) the target's SDP
  answer.
- `candidate(designator, ice)` delivers one trickled ICE candidate to the peer,
  in either direction, for as long as gathering continues.

The object is a plain OCapN capability: the messages are ordinary `op:deliver`s
carrying byte strings (the SDP and the JSON-serialized ICE candidate). It holds
no WebRTC state and parses none of the payloads; it only routes them between the
two designators it introduces, the same way a room routes a chat line. A room is
the natural host for it (members already meet there), but any peer both parties
can reach can carry the exchange, including a peer reached over iroh or a relay.

**Composition with the three-party handoff.** WebRTC redemption is two
movements instead of one. The existing handoff delivers a `desc:handoff-give`
that names an exporter and a way to reach it; the recipient dials that way and
then runs the keyed handshake. For `webrtc`, the dial executor pairs the
exporter's designator with the dialing host's configured signaling authority,
runs the offer, answer, and candidate exchange, adopts the resulting
DataChannel, and continues withdrawal over its keyed session. The rooms app
proves the whole path live (`zig build rooms-web-dm-webrtc`): the give's
exporter locator names a bare `webrtc` designator and the room directory
carries the exchange as ordinary OCapN messages.

This keeps signaling inside the object-capability model. There is no signaling
server to run, authenticate, or secure separately: the right to signal a peer is
the capability to reach its signaling object, granted and attenuated like any
other capability.

## The signaling capability: the phase-5 wire shape

Phase 5 shipped the signaling object and its offer, answer, and candidate
scenarios. This section records that wire shape. Generic Host adoption and
three-party handoff redemption ship with the standing note's `webrtc-loop` and
`webrtc-bridge-redeem` proofs.

**One authority, exact exchange identity after admission.** The host-facing
signaling authority stays keyed by peer designator: `offer(to, sdp)` resolves
to the answer and `candidate(to, ice)` trickles candidates for that dial. The
rooms carrier turns that stable public shape into a bounded exchange protocol.
A peer registers one signaling inbox under its designator, and an offerer gives
the directory a reply capability with `signalOffer(to, sdp, reply)`.

After admitting the row, the directory mints an exchange id and sends
`accepted(id)` to `reply`, then sends `offer(id, sdp)` to the target inbox. Both
sides use that id for `signalCandidate(id, ice)`, the target returns
`signalAnswer(id, sdp)`, and the offerer retires exactly that row with
`signalDone(id)`. The directory authorizes direction from the calling session.
The id is load-bearing: a designator can name a later dial, so a delayed
designator-keyed retirement could close the wrong exchange. Replacement,
eviction, and expiry send `reject(reason)` to the old row's reply capability.

The browser peer treats those strings as hostile signaling input. It snapshots
and validates the standard candidate fields, admits at most 4 Ki text units per
candidate and 256 candidates / 64 Ki text units per pending peer, and bounds
unresolved outbound candidate sends at 256. The rooms carrier allocates one
reply capability per active dial, holds early candidates behind
`accepted(id)`, gives answer waits and directory rows a 30-second deadline, and
retires the exact admitted id when bring-up ends. Replacement, eviction, and
expiry reject the dial rather than orphaning its promise. Overflow refuses or
aborts that bring-up instead of retaining an unbounded promise chain.

The inbox a peer registers is a giftable (ADR-0088): it answers `offer` by
producing its SDP answer through its sidecar peer and returning it over the
arriving connection through `currentSession()`, and it applies each `candidate`
to that sidecar peer. The object itself holds no WebRTC state and parses no
payload. It moves opaque strings between two designators, the same
byte-transparency the room and the relay hold.

**Redemption by signaling, then handshake.** A WebRTC handoff redemption
obtains the exporter's designator from the give and the signaling capability
from its own host's configuration. The redeeming recipient acts as the
offerer, establishes the DataChannel through the signaling verbs, adopts the
keyed session, and continues withdrawal there. The rooms app carries the
production form: members file signaling inboxes with the directory
(`offerSignaling`), and the directory routes `signalOffer` / `signalAnswer` /
`signalCandidate` between designators without parsing a payload
(`apps/rooms/server/main.ts`, `apps/rooms/lib/signaling.ts`).

**Where the redeeming host's signaling authority comes from.** The bootstrap
question both proposals above leave open is settled by the same seam ADR-0088
settled it for `keyed-relay`. A recipient holding only a give whose exporter
locator names a `webrtc` designator has no signaling capability in hand, and
the locator deliberately carries none. So the authority is deployment
configuration of the dialing host, the sibling of `Host.setRendezvousUrl`:
`Host.setSignaling` takes the language-level face of whatever signaling
capability the application holds (`SignalingAuthority`: deliver an offer and
resolve its answer, trickle candidates both ways). When a dial plan classifies
as `signaling`, the dial executor drives the exchange through that authority,
adopts the DataChannel, and runs the keyed handshake over it — connect and
handoff-redeem share the path. Shipped and proven by
`zig build webrtc-browser-to-browser`, whose offerer dials the bare locator. A
locator that names its own signaling route (a `?signaling=` hint) is
deliberately not part of this step. A route-bearing hint is new wire surface,
and the hints extension shape is in the upstream conversation ADR-0097 opened;
configured authority needs no new wire bytes, so it shipped first, exactly as
the configured rendezvous relay shipped before a self-describing locator.

**The `webrtc` locator and the dial classifier.** A `webrtc` locator carries a
designator, not a dialable address or an embedded capability. `planDial`
therefore classifies it as the third shape, `signaling`, rather than
`host_port` or `peer_id`. The dial executor answers that shape with the
configured authority's exchange, opens the channel, and adopts the keyed
session; a host with no configured authority refuses instead of pretending it
can dial, and a relay classifying targets refuses the shape outright.

## STUN/TURN posture: direct where possible, relayed only when it cannot be

ICE gathers three kinds of candidate, and the posture mirrors iroh's explicit
reachability choice: nothing infrastructural is on by default, and a relay is a
fallback, never the steady path.

- **Host candidates** are a peer's own interface addresses. On loopback and on a
  LAN, two peers reach each other on host candidates alone, with no STUN and no
  TURN. In-tree tests need no signaling infrastructure at all.
- **Server-reflexive (srflx) candidates** are a peer's public address as seen
  through NAT, discovered with a STUN server. STUN only observes an address; it
  never carries session bytes. A deployment that must traverse NAT configures a
  STUN server the same way an iroh deployment opts into discovery: explicitly, in
  the open.
- **Relayed candidates** route bytes through a TURN server when ICE finds no
  direct path (symmetric NAT on both ends). This is the one case where an
  intermediary sits on the byte path, and it is a fallback: ICE prefers a direct
  candidate pair whenever one works and falls back to TURN only when none does.

"Relay-less where possible" is therefore a property of ICE, not a pancake
policy: the DataChannel is direct (host or srflx pair) whenever connectivity
allows, and relayed (TURN) only when the network blocks every direct path. A
TURN relay, when it is used, is a byte relay under the DTLS channel; like the
ADR-0086 relay it never holds a capability and cannot read the keyed session,
because the DTLS encryption and the keyed handshake both run end to end above it.

## The DataChannel configuration for CapTP

The channel is created ordered and reliable: `ordered: true`, with neither
`maxRetransmits` nor `maxPacketLifeTime` set. Each DataChannel message carries
one complete bare codec frame, and the receiver hands that frame to the
whole-frame API. SCTP may fragment a message internally, but the DataChannel
reassembles it before delivery. An unordered or lossy channel would violate
CapTP's reliable ordering even though message boundaries remain intact.

## Native sidecar 0.20 mechanics

The sidecar pins `webrtc` `=0.20.0`. That crate line is a re-architecture
rather than a bump from 0.14: it is a thin async layer over the sans-io `rtc`
protocol core, driven by a background `PeerConnectionDriver` behind a
runtime-agnostic `Runtime` trait. The `api`, `interceptor`, `ice_transport`,
`configuration`, and `sdp` modules are gone. The new shape matters because the
data channel offers `poll() -> Option<DataChannelEvent>` alongside `writable()`,
`try_send()`, `outstanding_bytes()`, and buffered-amount thresholds.

The sidecar keeps the C ABI synchronous without letting nonblocking calls enter
the async runtime. Non-blocking writes hand a bounded prefix to a sidecar
staging buffer and report `WOULD_BLOCK` when that buffer is full; an async drain
task sends bounded chunks through `DataChannel::send`, where the crate's
configured send buffer applies its own backpressure. The matching inbound
staging deque exists because the synchronous C read surface needs contiguous
bytes while the data channel yields whole polled messages. The poller admits a
whole incoming message only when it fits under the inbound staging budget, and a
single message larger than that budget closes the peer instead of growing memory
without bound.

The port is contained below the C ABI. All eighteen `extern "C"` functions keep
their signatures, so the Zig resident, the companion archive, and every proof
keep the same integration point. Six of the live proofs need only cargo, among
them `webrtc-interop`, `webrtc-loop`, and `webrtc-bridge-redeem`, so most of the
evidence does not wait on a browser; the four Chromium proofs cover the
browser-facing arm.

## Limits

Three limits follow from the design above and from ADR-0088: a browser is
reachable only while its tab is open, the DataChannel's DTLS fingerprint is
trusted to introduce but not to impersonate (it cannot complete the keyed
handshake), and a TURN fallback is a byte relay that sees timing and volume but
not the encrypted session. One limit is specific to signaling:

- **Signaling requires a mutually reachable capability.** Two peers can be
  introduced over `webrtc` only if some capability can carry signaling between
  them. A room, a relay-reached peer, or an iroh-reached peer can host it. Two
  peers with no common reachable object cannot bootstrap a `webrtc` session,
  because there is nowhere to exchange the offer.

## Phased build plan

Each phase names the proof that lands it. A production WebRTC netlayer is a
subsystem on the scale of the iroh integration, so it is built in order, each
phase gated before the next.

- **Phase 1 — de-risk the transport.** A headless Chromium
  `RTCDataChannel` carries raw bytes both directions to a native Rust `webrtc`
  peer on loopback, with signaling done out of band over stdio (a direct
  SDP/ICE exchange, not yet the OCapN capability). This proves the `webrtc`
  crate, the browser API, ICE on loopback in a headless container, and the DTLS
  channel all work in this environment before any engine integration. **Gate:**
  `zig build webrtc-datachannel-test` (needs cargo + deno + a Playwright
  Chromium). It builds the probe binary `transports/webrtc/` and runs the
  Deno/Playwright harness that drives the browser peer and asserts the byte
  round-trip.

- **Phase 2 — the Zig resident over the sidecar.** Grow the phase-1
  probe into the sidecar C ABI (endpoint/peer/readiness, mirroring
  `pancake_iroh_sidecar_*`), and write `src/net/transport/webrtc.zig` over it to
  the established-peer byte contract. Signaling stays out of band at this phase (a test
  harness carries SDP/ICE), so the proof is transport-shaped, not yet
  capability-routed. **Gate:** a `webrtc-interop` step — two native pancake
  peers hold a keyed OCapN session over a real DataChannel, plus the hermetic
  resident type-check that rides `check`.

- **Phase 3 — the C ABI companion archive.** Add
  `src/c_abi/net_transport/webrtc/` exporting its own pancake_webrtc_* family,
  its header generator, and its TS FFI mirror, so the bindings can drive the
  transport. **Gate:** a `webrtc-abi` step plus its
  gen-header-net-transport-webrtc-check and the FFI-layout checks folded into
  `check`.

- **Phase 4 — classify signaling without faking an address dial.** The dial
  classifier (`pancake_host_plan_dial`) recognizes `webrtc` and returns the
  signaling shape. The resident has no address `Netlayer`, because a locator
  alone cannot open a channel. The signaling-aware completion adapter under
  `driver.Bridge` (`webrtc.Backend` plus configured `SignalingAuthority`) is
  the Host path that executes that plan; the standing note names its proofs.

- **Phase 5 — OCapN signaling via a capability.** Define the signaling
  capability shape as an in-tree object and route the offer/answer/candidate
  exchange through it. **Gate:** `webrtc-signaling-captp` proves the signaling
  object over CapTP, and `webrtc-mesh` proves capability-routed signaling brings
  up a direct DataChannel carrying a keyed session. Generic Host adoption and
  redemption compose on that foundation; the standing note names the checks.

- **Phase 6 — the browser arm and browser-to-browser.** Ship `@pancake/webrtc`
  and prove the two end states: a browser and a native peer over a DataChannel,
  then two browsers introduced by a room speaking directly with the room out of
  the byte path. **Gate:** a `webrtc-browser-peer` step and a
  `webrtc-browser-to-browser` step (each needs deno + a Playwright Chromium; the
  browser-to-browser step runs two browser contexts).

## Scope (what this does not decide)

- **STUN/TURN server operation.** pancake defines the posture (direct where
  possible, STUN for srflx, TURN as fallback) but ships no STUN or TURN server
  and hard-codes no public one. A deployment configures its own, the same way an
  iroh deployment opts into discovery.
- **Signaling capability wire details.** The verb names, promise-based answer,
  and candidate-trickle framing in "The signaling capability: the phase-5 wire
  shape" are exercised by the in-tree signaling and mesh scenarios. Host
  adoption and redeem over configured signaling are proved separately
  (`webrtc-loop`, `webrtc-bridge-redeem`).
- **A signaling-aware generic dial completion.** The shared classifier can name
  the `signaling` shape without linking WebRTC. Executing that plan still
  requires a separately supplied signaling capability and an optional WebRTC
  companion; this ADR does not make a bare locator sufficient.
- **Driving `rtc` directly from Zig.** The `webrtc` 0.20 crate sits over the
  sans-io `rtc` core, so a future resident could drive WebRTC packets, timers,
  ICE/STUN/TURN work, and data-channel events from pancake's own loop instead of
  letting the Rust sidecar own the runtime and sockets. That is possible, but it
  is a different boundary. The current C ABI hands Zig an established
  DataChannel-like byte peer plus signaling operations; a direct `rtc` resident
  would expose a packet-and-timer protocol driver, not the same transport
  archive. It should be a new ADR or amendment with scale and browser evidence,
  not a hidden dependency-upgrade side effect.

## Alternatives Considered

- **Relay rendezvous for the whole session (ADR-0086 only).** Keep every
  browser byte on a forwarding server. Rejected as the *complete* answer: it
  keeps an intermediary on the byte path for the session's life and cannot make
  two browsers direct peers. The relay remains the path to a native server and
  the TURN-shaped fallback; WebRTC complements it, and ADR-0086 already says so.
- **WebTransport.** Rejected: client-only, so it solves neither cold-dial nor
  browser-to-browser. It may later serve as a second relay browser-leg adapter,
  which needs no contract change because the relay's byte duplex is already
  abstract.
- **A bespoke signaling server.** Rejected: it would be a second authentication
  and authorization surface outside the capability model, exactly the coupling
  the relay ADR refuses. Signaling is an introduction, and introductions are
  capabilities.
- **An unreliable or unordered DataChannel.** Rejected: CapTP frames need
  in-order reliable delivery, and a lossy channel would break codec framing.

## Consequences

- The native resident, C companion, OCapN signaling scenarios, browser arms,
  generic Host completion adapter, and three-party redeem over configured
  signaling are live. A bare locator without signaling authority remains an
  explicit refusal rather than fake locator dialing.
- `arch-check` claims the new sidecar and archive directories the same way it
  claims the iroh ones: out of the layer DAG, still covered for file hygiene and
  the I/O bans.
- The signaling capability adds no CapTP semantics the engine lacks; it is an
  ordinary object routed like a room. The netlayer stays transport-agnostic and
  CapTP never names `webrtc`.
- The phase-1 probe remains a focused Deno/Playwright transport check behind
  `zig build webrtc-datachannel-test`; the resident and C ABI have their own
  later-phase gates.

## References

- **Phase-1 proof:** `transports/webrtc/` (the Rust probe) and its harness
  `transports/webrtc/test/datachannel_roundtrip_test.ts`, run by
  `zig build webrtc-datachannel-test`.
- **Template it mirrors:** the iroh netlayer sidecar (ADR-0055),
  `transports/iroh/`, `src/net/transport/iroh.zig`,
  `src/c_abi/net_transport/iroh/`.
- **Archive split:** ADR-0059.
- **Browser binding and this milestone:** ADR-0070 (Milestone 2).
- **Byte-transparent relay and the byte-channel contract:** ADR-0086.
- **Fully-functioning browser peer and the cold-dial gap this closes:**
  ADR-0088.
- **Remaining work:** the browser item in [`docs/roadmap.md`](../../roadmap.md).
