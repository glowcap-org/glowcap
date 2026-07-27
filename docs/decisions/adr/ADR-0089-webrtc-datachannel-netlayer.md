# ADR-0089: WebRTC DataChannel Netlayer

**Status:** Decided (built in phases; live phase status in [docs/roadmap.md](../../roadmap.md))
**Date:** 2026-07-21
**Decision:** pancake gains a `webrtc` netlayer: a reliable, ordered WebRTC
DataChannel that carries a keyed OCapN session byte-for-byte between two peers,
at least one of which is a browser. The transport is a native Rust sidecar over
the `webrtc` crate (the same shape as the iroh sidecar, ADR-0055), a Zig
netlayer resident over its C ABI, a companion archive
`libpancake_net_transport_webrtc` (ADR-0059), and a browser
`RTCPeerConnection`/`RTCDataChannel` arm. The signaling that WebRTC needs — the
SDP offer/answer and ICE candidates — is exchanged through an OCapN capability,
not a bespoke signaling server: a room or a giftable signaling object carries
the exchange, so a `webrtc` handoff is the existing three-party handoff with a
signaling round added before the direct dial. This closes the two gaps ADR-0088
left open: a browser being cold-dialed, and two browsers as direct peers.

This ADR builds on the iroh netlayer sidecar (ADR-0055), the à-la-carte
transport archive split (ADR-0059), the browser binding (ADR-0070, whose
Milestone 2 this is), the byte-transparent relay (ADR-0086), and the
fully-functioning browser peer (ADR-0088).

---

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
  dogfood. The sidecar owns its own tokio runtime behind an opaque handle and
  blocks the calling thread per call, and it exposes the same readiness surface
  the iroh sidecar does (ADR-0057) so one loop thread can serve many
  DataChannels. Its `Cargo.lock` is committed, like iroh's, because the
  `webrtc` crate pulls a large transitive tree (DTLS, SCTP, ICE, STUN, SDP) that
  must resolve identically on every machine.

- **Zig netlayer resident (`src/net/transport/webrtc.zig`).** One resident
  implements the `net.netlayer` contract (ADR-0043) over the sidecar's C ABI,
  the same way `src/net/transport/iroh.zig` does. It is compiled as its own
  module outside the `pancake` root namespace, so its externs resolve only when
  the staticlib links, and a plain `zig build check` type-checks it as an
  object without cargo.

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

A `webrtc` locator therefore names the designator and enough to start signaling.
Because signaling is carried by a capability (below), the locator minted for a
handoff does not carry a dialable address the way an iroh locator carries node
id plus direct-address hints; it carries the designator and a reference to the
signaling capability through which the offer/answer exchange runs.

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

**Composition with the three-party handoff.** A `webrtc` give is redeemed in two
movements instead of one. The existing handoff delivers a `desc:handoff-give`
that names an exporter and a way to reach it; the recipient dials that way and
then runs the keyed handshake. For `webrtc`, "the way to reach it" is the
signaling capability plus the exporter's designator. Redeeming the give runs the
signaling exchange first (offer out, answer back, candidates both ways) to bring
up the DataChannel, and then runs the keyed handshake over the open channel.
The handshake, the session, and the capability graph are unchanged; only the
transport establishment gains a signaling round. Two browsers introduced by a
room is precisely this: the room is the introducer and the signaling host, the
`desc:handoff-give` names the peer designator and the room's signaling
capability, and the redeemed session runs directly over the DataChannel with the
room out of the byte path.

This keeps signaling inside the object-capability model. There is no signaling
server to run, authenticate, or secure separately: the right to signal a peer is
the capability to reach its signaling object, granted and attenuated like any
other capability.

## The signaling capability: the phase-5 wire shape

Phase 5 builds the signaling object. This section decides its wire shape so the
build has a concrete target; the shape is ratified when the in-tree object and
its scenario land, and this section moves with them if they diverge.

**One object, two verbs, keyed by designator.** The signaling object is a
rendezvous keyed by peer designator, the same shape ADR-0088's cold-dial relay
rendezvous holds. A peer that wants to be reached over `webrtc` registers a
signaling inbox with the object under its own designator, and the object routes
messages addressed to that designator to that inbox.

- `offer(to, sdp)` routes the initiator's SDP offer to `to`'s inbox and returns
  a promise that resolves to `to`'s SDP answer. The answer rides the promise
  rather than a paired callback object, because that composes with pancake's
  promise pipelining and needs no second capability to carry the reply.
- `candidate(to, ice)` routes one trickled ICE candidate to `to`'s inbox as a
  fire-and-forget `tell`, in either direction. It carries one candidate per
  call, the JSON-serialized `RTCIceCandidateInit` the sidecar's
  `next_local_candidate` produces, and a null candidate marks end of gathering.

The inbox a peer registers is a giftable (ADR-0088): it answers `offer` by
producing its SDP answer through its sidecar peer and returning it over the
arriving connection through `currentSession()`, and it applies each `candidate`
to that sidecar peer. The object itself holds no WebRTC state and parses no
payload. It moves opaque strings between two designators, the same
byte-transparency the room and the relay hold.

**Redeem by signaling, then handshake.** A `webrtc` `desc:handoff-give` names
the exporter's designator and the signaling object. The redeeming recipient is
the offerer: it registers its own signaling inbox, creates an offerer sidecar
peer, and calls `offer(exporter, offer_sdp)`, whose promise resolves to the
exporter's answer. Both sides then trickle candidates to each other's inbox with
`candidate`, the channel opens, and the keyed handshake runs over it exactly as
in phase 2. `Session.sendRedeeming` (ADR-0088) surfaces the direct session so
the recipient hosts its reply inbox on the connection the redeemed token routes
to. Two browsers introduced by a room is this same flow with the room as the
signaling host and both peers running the browser arm.

**The `webrtc` locator and the dial classifier.** A `webrtc` locator carries the
designator and a reference to the signaling object, not a dialable address. This
is why `planDial` resolves a `webrtc` locator to neither a `host_port` nor a
`peer_id` plan, but to a third shape, `signaling`, carrying the designator and
the signaling reference: the redeem opens the channel through the exchange above
before the keyed handshake runs. A `webrtc` locator is therefore reached through
a redeemed give, never a bare `connect`.

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
`maxRetransmits` nor `maxPacketLifeTime` set, so SCTP delivers every byte in
order. CapTP is a byte stream with in-order framing; an unordered or lossy
channel would break the codec's frame delimiting. This matches every other
pancake transport, which are all reliable ordered streams. Message boundaries on
the DataChannel are not frame boundaries: the session's codec owns framing, and
the transport concatenates and re-splits bytes freely, exactly as TCP and QUIC
do.

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

- **Phase 2 — the Zig netlayer resident over the sidecar.** Grow the phase-1
  probe into the sidecar C ABI (endpoint/conn/readiness, mirroring
  `pancake_iroh_sidecar_*`), and write `src/net/transport/webrtc.zig` over it to
  the `net.netlayer` contract. Signaling stays out of band at this phase (a test
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

- **Phase 4 — engine transport dispatch for `webrtc`.** Teach the netlayer
  dispatch and the dial classifier (`pancake_host_plan_dial`) to sort a `webrtc`
  locator and open the matching channel, so a `webrtc` locator dials like any
  other. **Gate:** a dispatch scenario that routes a `webrtc` locator to the
  resident, alongside the existing per-transport classification tests.

- **Phase 5 — OCapN signaling via a capability.** Define the signaling
  capability shape as an in-tree object, route the offer/answer/candidate
  exchange through it, and redeem a `webrtc` give by signaling-then-handshake.
  **Gate:** a `webrtc-mesh` step — a three-party handoff where the introducer
  hosts signaling and the recipient reaches the exporter over a direct
  DataChannel.

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
- **Signaling capability wire details.** The verb names, the promise-based
  answer, and the candidate-trickle framing are decided in "The signaling
  capability: the phase-5 wire shape" above. That shape is ratified when the
  in-tree object and its `webrtc-mesh` scenario land, and it moves with them if
  the implementation finds a better one.
- **A cross-transport dial entry point.** As with the relay (ADR-0086), there is
  no single symbol that dials every transport; `webrtc` composes into the
  per-transport open behind the shared classifier, so a TCP-only or iroh-only
  build never links the WebRTC sidecar.

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

- The artifacts named in the layer section land across phases 2 through 6, each
  behind its own gate.
- `arch-check` claims the new sidecar and archive directories the same way it
  claims the iroh ones: out of the layer DAG, still covered for file hygiene and
  the I/O bans.
- The signaling capability adds no CapTP semantics the engine lacks; it is an
  ordinary object routed like a room. The netlayer stays transport-agnostic and
  CapTP never names `webrtc`.
- Phase 1 leaves one self-contained artifact in the tree: the probe crate and
  its Deno/Playwright harness behind `zig build webrtc-datachannel-test`. No Zig
  or C ABI integration is committed until phase 2 makes it compile clean under
  `zig build check`.

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
