---
id: ADR-0089
status: accepted
date: 2026-07-21
tags: [transport, webrtc, browser, signaling, sidecar, handoff]
decision: "glowcap gains a `webrtc` transport: a reliable, ordered WebRTC DataChannel that carries one bare OCapN codec frame per DataChannel message between two peers, at least one of which is a browser. The transport is a native Rust sidecar over the `webrtc` crate (the same shape as the iroh sidecar, ADR-0055), a Zig netlayer resident over its C ABI, a companion archive `libglowcap_net_transport_webrtc` (ADR-0059), and a browser `RTCPeerConnection`/`RTCDataChannel` arm. The signaling that WebRTC needs, the SDP offer/answer and ICE candidates, is exchanged through an OCapN capability rather than a bespoke signaling server."
supersedes: []
superseded_by: []
amends: []
amended_by: [ADR-0110]
---

# ADR-0089 WebRTC DataChannel netlayer

> **Framing amendment (ADR-0110).** Each reliable, ordered DataChannel message
> carries one bare codec frame. The outer Syrup byte-string envelope is only
> for byte-stream transports.

> **Shipped state.** The standalone dial
> ships in the TypeScript stack: a host configured with signaling authority
> (`Host.setSignaling`) dials a bare `webrtc` locator through the one dial path,
> proven by `zig build webrtc-browser-to-browser`. Handoff redemption over it is
> proven live by `zig build rooms-web-dm-webrtc`, with the room directory
> carrying the signaling. The native completion tier ships too:
> `completion.Loop(webrtc.Backend)` adopts signaled peers and dials through a
> configured `SignalingAuthority` under `driver.Bridge` and the generic Host,
> proven by `zig build webrtc-loop`, and the native three-party redeem over a
> bare `webrtc` give is proven by `zig build webrtc-redeem`.

## Decision

glowcap has a `webrtc` transport: a reliable, ordered WebRTC DataChannel that
carries one bare OCapN codec frame per message between two peers, at least one
of which is a browser. The transport is a native Rust sidecar over the `webrtc`
crate (the shape of the iroh sidecar, ADR-0055), a Zig netlayer resident over
its C ABI, a companion archive `libglowcap_net_transport_webrtc` (ADR-0059), and
a browser `RTCPeerConnection`/`RTCDataChannel` arm. The signaling WebRTC needs,
the SDP offer/answer and ICE candidates, is exchanged through an OCapN
capability instead of a bespoke signaling server. In the TypeScript stack the
dial executor composes the whole bring-up: a host configured with signaling
authority dials a bare `webrtc` locator, and connect and handoff-redeem share
that path. The native completion tier has the same shape, with `webrtc.Backend`
adopting signaled peers and dialing through a configured authority under the
generic Host. The shipped-state note above names the check for each half.

This ADR builds on the iroh netlayer sidecar
([ADR-0055](ADR-0055-iroh-netlayer-sidecar.md)), the à-la-carte transport
archive split ([ADR-0059](ADR-0059-composable-c-abi-archives.md)), the browser
binding ([ADR-0070](ADR-0070-browser-binding-via-wasm.md), whose Milestone 2
this is), the byte-transparent relay
([ADR-0086](ADR-0086-byte-transparent-relay.md)), and the fully functioning
browser peer ([ADR-0088](ADR-0088-fully-functioning-browser-peer.md)).

## Problem

A browser cannot open a listening socket, so ADR-0088 left a browser reachable
only two ways: over a session the browser itself dialed, or through a relay
rendezvous that forwards its bytes. Both route the byte path through an
intermediary for the browser's whole conversation. Two browsers talking to each
other therefore run every frame through a server that sits on the wire for the
life of the session.

WebRTC removes the intermediary from the byte path. Two peers exchange an SDP
offer and answer plus a handful of ICE candidates, and from then on the
DTLS-encrypted DataChannel runs peer to peer. An intermediary is touched during
signaling, and as a byte relay only when ICE finds no direct path through NAT.
This is the one transport that makes a browser cold-dialable and two browsers
direct peers, and it keeps the steady-state byte path off any server glowcap
runs. WebTransport is client-only, so it does neither.

## The transport stack, layer by layer

The `webrtc` netlayer reuses the iroh netlayer's decomposition.

- **Native Rust sidecar (`transports/webrtc/`).** A separate crate wraps the
  `webrtc` crate behind a narrow C ABI, as `transports/iroh/` wraps iroh
  (ADR-0055). `libglowcap` and the core stay pure Zig. Only the `webrtc-*` build
  steps need cargo on PATH. One endpoint owns a two-worker Tokio runtime and
  readiness fd shared by all of its peers. Peer creation and signaling
  submissions are synchronous control operations. Once submitted, channel
  establishment, candidates, packet I/O, and closure surface as stable peer-id
  readiness events with non-blocking try-I/O, so one reactor can serve many
  DataChannels. Readiness uses a coalescing self-pipe: `WouldBlock` is success
  because a full pipe is already poll-readable. Every other write or drain fault
  is retained and terminalizes the backend rather than disappearing. That one
  `nudge` operation serves both event publication and the re-wake after a short
  record drain, and the fd exposed to callers has its write direction shut down.
  Its `Cargo.lock` is committed, like iroh's, because the `webrtc` crate pulls a
  large transitive tree (DTLS, SCTP, ICE, STUN, SDP) that must resolve
  identically on every machine.

- **Zig resident (`src/net/transport/webrtc.zig`).** One resident owns the
  sidecar endpoint and presents established peers through readiness-driven
  packet I/O. It is compiled as its own
  module outside the `glowcap` root namespace, so its externs resolve only when
  the staticlib links, and a plain `zig build check` type-checks it as an
  object without cargo. Its completion backend accepts answers, candidates, and
  adopted peers from foreign signaling threads through a bounded wake-driven
  inbox. Signaling bytes copy into a fixed 4 MiB endpoint-level transfer pool
  allocated during backend initialization. Foreign threads never enter the
  caller's potentially single-threaded allocator, and a full inbox reports
  `WouldBlock` instead of growing behind the reactor.

- **C ABI companion archive (`libglowcap_net_transport_webrtc`).** The public
  frame-level ABI ships as its own archive under
  `src/c_abi/net_transport/webrtc/`, exporting only its own glowcap_webrtc_*
  symbol family and reusing `c_abi/shared` by layout (ADR-0059). It links the
  Rust sidecar, so it sits outside the layer DAG (`.graph = false`) like the
  iroh companion, and its header is reflected from its own root by a
  gen-header-net-transport-webrtc generator mirroring the iroh one.

- **Browser arm (`bindings/ts/webrtc`).** The `@glowcap/webrtc` package holds
  the browser's `RTCPeerConnection`/`RTCDataChannel` half, the peer of the
  native sidecar. It composes with the browser binding (ADR-0070): the wasm Host
  runs the keyed session, and this arm provides the packet channel the session
  runs over, the same Host seam `@glowcap/web`'s WebSocket channel fills for
  the relay path. Two browsers each run this arm and speak directly. A browser
  and a native peer each run their own half.

The DataChannel never parses a frame. The keyed CapTP session runs end to end on
top of it, as over ADR-0086's relay leg. It is the same byte-transparency
contract over a peer-to-peer channel.

## The `webrtc` locator and peer identity

`webrtc` is a netlayer transport symbol, alongside `tcp`, `keyed-tcp`,
`inproc`, and `iroh`. CapTP itself never names a transport (architecture rule).
The symbol lives only in locators and in the netlayer dispatch.

A peer is named by its Ed25519 designator, the same posture keyed-tcp and iroh
already hold. The DataChannel's DTLS layer authenticates the channel against a
self-signed certificate fingerprint carried in the SDP. The OCapN keyed
handshake then runs over the open channel and is the authority for peer
identity, as over iroh's QUIC. The DTLS fingerprint binds the two ends of this
channel together so signaling cannot be man-in-the-middled into a different
channel. The keyed handshake binds the channel to the designator. DTLS secures
the pipe, and the keyed handshake proves who is on the far end of it.

A bare `webrtc` locator names the designator but carries no authority through
which to signal it. The application supplies that authority on the dialing host
(`Host.setSignaling`), and the dial executor performs the composition: the dial
classifier's `signaling` shape routes to the exchange rather than a socket, and
the resident exposes no address-based `dial` or `listen` method. A host with no
configured authority refuses the dial.

## OCapN-native signaling

WebRTC needs a signaling channel to exchange the offer, the answer, and ICE
candidates before the DataChannel opens. glowcap already has a signaling
channel: the capability graph. Introductions flow through it as the three-party
handoff, and the browser cold-dial rendezvous (ADR-0088) routes a browser's
reachability through a room. Signaling is the same shape and uses the same
mechanism.

**The signaling capability.** A peer that wants to be reached over `webrtc`
holds, or is introduced to, a signaling object. It is a small, sync capability
with two directions of message:

- `offer(designator, sdp)` delivers the initiator's SDP offer to the target and
  returns (as a promise, or via a paired `answer` call back) the target's SDP
  answer.
- `candidate(designator, ice)` delivers one trickled ICE candidate to the peer,
  in either direction, for as long as gathering continues.

The object is a plain OCapN capability: the messages are ordinary `op:deliver`s
carrying byte strings (the SDP and the JSON-serialized ICE candidate). It holds
no WebRTC state and parses none of the payloads. It only routes them between the
two designators it introduces, the same way a room routes a chat line. A room is
the natural host for it (members already meet there), but any peer both parties
can reach can carry the exchange, including a peer reached over iroh or a relay.

**Composition with the three-party handoff.** WebRTC redemption is two
movements instead of one. The existing handoff delivers a `desc:handoff-give`
that names an exporter and a way to reach it. The recipient dials that way and
then runs the keyed handshake. For `webrtc`, the dial executor pairs the
exporter's designator with the dialing host's configured signaling authority,
runs the offer, answer, and candidate exchange, adopts the resulting
DataChannel, and continues withdrawal over its keyed session. The rooms app
proves the whole path live (`zig build rooms-web-dm-webrtc`): the give's
exporter locator names a bare `webrtc` designator and the room directory
carries the exchange as ordinary OCapN messages.

Signaling stays inside the object-capability model. There is no signaling
server to run, authenticate, or secure separately: the right to signal a peer is
the capability to reach its signaling object, granted and attenuated like any
other capability.

## The signaling wire shape

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
A designator can name a later dial, so a delayed designator-keyed retirement
could close the wrong exchange. Replacement,
eviction, and expiry send `reject(reason)` to the old row's reply capability.

The browser peer treats those strings as untrusted signaling input. It snapshots
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
to that sidecar peer. The object holds no WebRTC state and parses no payload.

**Redemption by signaling, then handshake.** A WebRTC handoff redemption
obtains the exporter's designator from the give and the signaling capability
from its own host's configuration. The redeeming recipient acts as the
offerer, establishes the DataChannel through the signaling verbs, adopts the
keyed session, and continues withdrawal there. The rooms app carries the
production form: members file signaling inboxes with the directory
(`offerSignaling`), and the directory routes `signalOffer` / `signalAnswer` /
`signalCandidate` between designators without parsing a payload
(`apps/rooms/rust/services/src/server/signaling.rs`, `bindings/ts/runtime/signaling.ts`).

**Where the redeeming host's signaling authority comes from.** The seam is the
one ADR-0088 uses for `keyed-relay`. A recipient holding only a give whose
exporter locator names a `webrtc` designator has no signaling capability in
hand, and the locator carries none. So the authority is deployment configuration
of the dialing host, the sibling of `Host.setRendezvousUrl`: `Host.setSignaling`
takes the language-level face of whatever signaling capability the application
holds (`SignalingAuthority`: deliver an offer and resolve its answer, trickle
candidates both ways). When a dial plan classifies as `signaling`, the dial
executor drives the exchange through that authority, adopts the DataChannel, and
runs the keyed handshake over it. Connect and handoff-redeem share the path.
Proven by `zig build webrtc-browser-to-browser`, whose offerer dials the bare
locator. A locator that names its own signaling route (a `?signaling=` hint) is
not part of this decision. A route-bearing hint is new wire surface, and the
hints extension shape is in the upstream conversation ADR-0097 opened.
Configured authority needs no new wire bytes.

**The `webrtc` locator and the dial classifier.** A `webrtc` locator carries a
designator, not a dialable address or an embedded capability. `planDial`
therefore classifies it as the third shape, `signaling`, rather than
`host_port` or `peer_id`. The dial executor answers that shape with the
configured authority's exchange, opens the channel, and adopts the keyed
session. A host with no configured authority refuses instead of pretending it
can dial, and a relay classifying targets refuses the shape outright.

## STUN/TURN posture

ICE gathers three kinds of candidate. As with iroh's reachability choice, the
`@glowcap/webrtc` connector adds no infrastructure unless its embedding names
some, and a relay is a fallback. The Rooms application is an embedding with a public
reachability goal: its server publishes Cloudflare STUN by default, while an
explicit empty `GLOWCAP_ROOMS_ICE_SERVERS` restores host candidates alone and a
deployment-owned list replaces the default. A deployment may additionally keep
an HTTPS TURN-credential issuer token on the Rooms server. `/ice` then mints
bounded short-lived credentials for each browser connection without exposing
that long-lived token. The native companion projects the same provider-neutral
ICE facts through fixed C records: URLs plus optional username/password
credentials. Credential APIs, expiry, and refresh remain embedding policy.

- **Host candidates** are a peer's own interface addresses. On loopback and on a
  LAN, two peers reach each other on host candidates alone, with no STUN and no
  TURN. In-tree tests need no signaling infrastructure at all.
- **Server-reflexive (srflx) candidates** are a peer's public address as seen
  through NAT, discovered with a STUN server. STUN only observes an address and
  never carries session bytes. A deployment that must traverse NAT configures a
  STUN server explicitly, as an iroh deployment opts into discovery.
- **Relayed candidates** route bytes through a TURN server when ICE finds no
  direct path (symmetric NAT on both ends). This is the one case where an
  intermediary sits on the byte path. ICE prefers a direct candidate pair
  whenever one works.

Directness is a property of ICE: the DataChannel is direct (host or srflx pair)
whenever connectivity allows, and relayed (TURN) only when the network blocks
every direct path. A TURN relay is a byte relay under the DTLS channel. Like the
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

The sidecar pins `webrtc` `=0.20.0`. That crate line is a thin async layer over
the sans-io `rtc` protocol core, driven by a background `PeerConnectionDriver`
behind a runtime-agnostic `Runtime` trait. The `api`, `interceptor`,
`ice_transport`, `configuration`, and `sdp` modules are gone. The data channel
offers `poll() -> Option<DataChannelEvent>` alongside `writable()`,
`try_send()`, `outstanding_bytes()`, and buffered-amount thresholds.

The sidecar keeps the C ABI synchronous without letting nonblocking calls enter
the async runtime. Non-blocking writes hand a bounded prefix to a sidecar
staging buffer and report `WOULD_BLOCK` when that buffer is full. An async drain
task sends bounded chunks through `DataChannel::send`, where the crate's
configured send buffer applies its own backpressure. The matching inbound
staging deque exists because the synchronous C read surface needs contiguous
bytes while the data channel yields whole polled messages. The poller admits a
whole incoming message only when it fits under the inbound staging budget, and a
single message larger than that budget closes the peer instead of growing memory
without bound.

The sidecar sits below the C ABI, so the Zig resident, the companion archive,
and every proof share one integration point. Six of the live proofs need only
cargo, among them `webrtc-interop`, `webrtc-loop`, and `webrtc-redeem`. The four
Chromium proofs cover the browser-facing arm.

## Limits

Three limits follow from the design and from ADR-0088: a browser is reachable
only while its tab is open, the DTLS fingerprint introduces a peer but cannot
impersonate it (it cannot complete the keyed handshake), and a TURN fallback is
a byte relay that sees timing and volume but not the encrypted session. One
limit is specific to signaling:

- **Signaling requires a mutually reachable capability.** Two peers can be
  introduced over `webrtc` only if some capability can carry signaling between
  them. A room, a relay-reached peer, or an iroh-reached peer can host it. Two
  peers with no common reachable object cannot bootstrap a `webrtc` session.

## Proofs

- `zig build webrtc-datachannel-test` (cargo, deno, Playwright Chromium): a
  headless `RTCDataChannel` carries raw bytes both directions to a native Rust
  `webrtc` peer on loopback, with signaling out of band over stdio.
- `webrtc-interop`: two native glowcap peers hold a keyed OCapN session over a
  real DataChannel. The hermetic resident type-check rides `check`.
- `webrtc-abi` and `gen-header-net-transport-webrtc-check`: the companion
  archive and its FFI layout.
- `webrtc-signaling-captp`: the signaling object over CapTP. `webrtc-mesh`:
  capability-routed signaling brings up a direct DataChannel carrying a keyed
  session. `webrtc-loop` and `webrtc-redeem`: generic Host adoption and
  redemption.
- `webrtc-browser-peer` (browser and native peer) and
  `webrtc-browser-to-browser` (two browsers introduced by a room, with the room
  out of the byte path). Each needs deno and a Playwright Chromium.

## Scope (what this does not decide)

- **STUN/TURN server operation.** The transport core defines the posture
  (direct where possible, STUN for srflx, TURN as fallback) but ships no STUN or
  TURN server. Rooms is an embedding with a public STUN default and an optional
  deployment-owned TURN credential issuer. Another embedding configures its
  own, the same way an iroh deployment opts into discovery.
- **Signaling capability wire details.** The verb names, promise-based answer,
  and candidate-trickle framing in "The signaling wire shape" are exercised by
  the in-tree signaling and mesh scenarios. Host adoption and redeem over
  configured signaling are proved separately (`webrtc-loop`, `webrtc-redeem`).
- **A signaling-aware generic dial completion.** The shared classifier can name
  the `signaling` shape without linking WebRTC. Executing that plan still
  requires a separately supplied signaling capability and an optional WebRTC
  companion. This ADR does not make a bare locator sufficient.
- **Driving `rtc` directly from Zig.** The `webrtc` 0.20 crate sits over the
  sans-io `rtc` core, so a future resident could drive WebRTC packets, timers,
  ICE/STUN/TURN work, and data-channel events from glowcap's own loop instead of
  letting the Rust sidecar own the runtime and sockets. That is possible, but it
  is a different boundary. The C ABI hands Zig an established
  DataChannel-like packet peer plus signaling operations. A direct `rtc` resident
  would expose a packet-and-timer protocol driver, a different transport archive,
  and needs its own ADR with scale and browser evidence.

## Alternatives Considered

- **Relay rendezvous for the whole session (ADR-0086 only).** Keep every
  browser byte on a forwarding server. Rejected as the complete answer: it
  keeps an intermediary on the byte path for the session's life and cannot make
  two browsers direct peers. The relay remains the path to a native server.
  WebRTC complements it, as ADR-0086 says.
- **WebTransport.** Rejected: client-only, so it solves neither cold-dial nor
  browser-to-browser. It may later serve as a second relay browser-leg adapter,
  which needs no contract change because the relay's byte duplex is already
  abstract.
- **A bespoke signaling server.** Rejected: it would be a second authentication
  and authorization surface outside the capability model. Signaling is an
  introduction, and introductions are capabilities.
- **An unreliable or unordered DataChannel.** Rejected: CapTP frames need
  in-order reliable delivery, and a lossy channel would break codec framing.

## Consequences

- A bare locator without signaling authority is refused.
- `arch-check` claims the sidecar and archive directories as it claims the iroh
  ones: out of the layer DAG, still covered for file hygiene and the I/O bans.
- The signaling capability adds no CapTP semantics. It is an ordinary object
  routed like a room. CapTP never names `webrtc`.
- `zig build webrtc-datachannel-test` is a focused Deno/Playwright transport
  check (see Proofs).

## References

- **Transport probe:** `transports/webrtc/` (the Rust probe) and its harness
  `transports/webrtc/test/datachannel_roundtrip_test.ts`, run by
  `zig build webrtc-datachannel-test`.
- **Template:** the iroh netlayer sidecar (ADR-0055),
  `transports/iroh/`, `src/net/transport/iroh.zig`,
  `src/c_abi/net_transport/iroh/`.
- **Archive split:** ADR-0059.
- **Browser binding:** ADR-0070 (Milestone 2).
- **Byte-transparent relay and the byte-channel contract:** ADR-0086.
- **Fully functioning browser peer and the cold-dial gap this closes:**
  ADR-0088.
- **Remaining work:** the browser item in [`docs/roadmap.md`](../../roadmap.md).
