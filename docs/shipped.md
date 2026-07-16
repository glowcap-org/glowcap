# What ships today

This is the inventory of implemented behavior. Every claim here is held by a
check step, a scenario, or a live interop run, and it moves with the code: a claim
that stops matching the tree is drift. Its complement is
[boundaries.md](boundaries.md), which names where the implemented surface
ends. For how the pieces fit together, read [architecture.md](architecture.md);
for where this is all going, read [vision.md](vision.md).

## Frames and model

- **Frames.** A `Frame` has one visible owner, `FrameView` borrows bytes, and
  `FrameShape` carries byte- versus word-aligned frame metadata explicitly.
- **Model.** The CapTP message model is codec-neutral: its types exist
  independently of whichever wire encoding carried them.
- **Distributed equality.** `model.referencesEqual` is the codec-neutral
  structural-equality predicate that gives OCapN Pass Invariant Equality
  (ADR-0012) an in-memory home: two references naming the same target compare
  equal no matter which codec or profile carried them. Same-session equality
  is on `(import_position, kind)`; the sturdyref dedup cache supplies the
  sturdyref-versus-handoff collapse. Session-pair uniqueness is Host
  enrollment posture (ADR-0012), not CapTP wire law and not a `FeatureSet`
  bit: a second dial to a partner that already has a live dialed CapTP
  session enrolled refuses `HostError.SessionPairExists`
  (`test/driver/core_host_test.zig`). Crossed hellos may still race an
  accept beside a dial — see [boundaries.md](boundaries.md).

## Codecs

- **Syrup.** The Syrup codec encodes the message model against
  pancake-authored byte vectors cross-checked against the upstream Syrup
  encoders, not Goblins captures. It decodes borrowed views for the supported
  operations and materializes owned messages where the engine needs them,
  such as start-session and handoff. Non-empty locator hints on start-session
  and sturdyrefs project through a lazy `PeerLocator.hint_list` (same shape as
  Cap'n Proto); `toOwned` materializes entries, and start-session keeps
  `acceptable_location_raw` for the signing domain. Encoding is
  measure-then-fill: a non-allocating length pass computes the exact byte
  count, then one exact-sized allocation is filled, so every encode makes one
  allocation and zero reallocs at any payload size, pinned by
  `test/codec/encode_budget_test.zig`.
- **Cap'n Proto.** The hand-rolled Cap'n Proto codec (ADR-0026) is
  engine-integrated and selectable on a live session. Golden frames under
  `test/codec/capnp_fixtures/` lock encode bytes and decode acceptance
  (`zig build gen-capnp-fixtures` regenerates; `test/codec/capnp_golden_test.zig`
  checks). It is a pancake-to-pancake codec, not a Goblins parity claim.
- **Pluggable codecs.** Codecs resolve through an open comptime registry keyed
  by a non-exhaustive `model.CodecId`; the built-ins are `syrup` and `capnp`.
  A Zig consumer adds another codec by declaring `pub const pancake_codecs` in
  its root source file, and dispatch still unrolls at comptime, so the open
  registry costs nothing over the built-in set (ADR-0026).

## Session and engine

- **Session and engine.** Sessions own profile and feature negotiation,
  lifecycle, import/export/answer/release authority, validate-then-apply, and
  feature gates. The caller-owned `Peer` drives outbound profile-aware
  encoding, V1.0 resolve-me-desc synthesis, borrowed inbound dispatch, owned
  queued inbound frames, outbound drains, and application-visible events for
  the supported operations.
- **Promise pipelining.** Sessions own the inbound-answer table, listeners,
  and stored resolutions; `engine.pipeline` carries the pure transforms. A
  pipelined `op:deliver` against an unresolved answer queues and drains to
  the resolution, whether local delivery, requeue, or far-forward, once
  `op:resolve` settles. A multi-hop call decomposes at the sender into
  chained single-hop frames, so every `desc:answer` on the wire stays flat.
  The questioner side ships across the whole surface (ADR-0065): the driver's
  `send`/`sendToAnswer`/`settleVow`, the C session's non-blocking send, and a
  vow-as-send-target in every binding, so a dependent chain costs one round
  trip. TCP disables Nagle on every socket so a batched send is not held for
  a delayed-ACK timer; the `bench-langs` throughput unit runs the taskboard
  script pipelined.
- **Field, index, and tag projections.** A caller pipelines `op:get`,
  `op:index`, or `op:untag` against a pending answer to reach a field,
  element, or tag before it settles (ADR-0050, ADR-0052). The engine anchors
  the projection on the receiver and resolves it when the source settles or
  breaks; `test/engine/projection_test.zig` and `abort_projection_test.zig`
  pin both paths. The binding surface exposes `index` and `untag` (Rust
  `RemotePromise::index`/`untag`, Python `RemotePromise.index`/`untag`,
  Racket `conn-index`/`conn-untag`, TypeScript `RemotePromise.index`/`untag`);
  `op:get` still rides the peer waist and Goblins wire paths, not a binding
  `RemotePromise.get`.
- **Relayed-resolution forwarding.** An `op:listen` on a handoff-imported
  promise installs against the third-party-hosted import; when the
  introducing session forwards the host's resolution,
  `engine.cross_peer.drainRelayedResolutions` fires the listeners and stores
  the resolution so a late listener fires immediately (ADR-0009). A relayed
  promise resolves once: `recordRelayedResolution` refuses a second relay for
  the same import.
- **Bootstrap fetch.** `engine.fetch` builds the canonical bootstrap-fetch
  `op:deliver` and matches either kind of partner settlement, an
  `op:resolve` or a resolver-callback `op:deliver`, into one owned outcome;
  the adapter drives the wire loop while the core stays no-I/O. On the
  responder side, `Peer.registerBootstrapCap(swissnum)` exposes a local
  capability behind a swiss number, and an inbound `'fetch` to the bootstrap
  export is recognized and answered automatically, with
  `break "unknown swissnum"` for an unregistered one (ADR-0006).
- **Sturdyref enliven.** `engine.sturdyref` turns a persistent
  `(peer, swissnum)` sturdyref into a live `Reference` over that same
  bootstrap-fetch: a precondition check (feature negotiated and session open), a
  session dedup cache mapping a swiss number to its `(import_position, kind)`
  that short-circuits a repeat enliven with no wire traffic, and an in-flight
  marker that collapses a concurrent enliven onto the outstanding answer. The
  `pancake_peer_prepare_enliven` / `pancake_peer_record_enlivenment` C ABI
  seam exposes the cache, and every binding ships a one-call `enliven()`
  convenience over it. Native `zig build goblins-interop` proves enliven +
  dedup against a live Goblins-published cap. Binding `enliven()` / dedup
  against Goblins is not a live gate today — bindings prove the seam in-process
  and via C ABI dogfoods.
- **Distributed GC, opt-in.** The engine sends and accounts the wire-delta GC
  messages: `op:gc-exports` / `op:gc-answers` decrement the matching table
  rows, balanced inbound. Every binding can drive a release from a dropped
  handle behind an opt-in, off by default (ADR-0063). A connection in GC mode
  (`with_gc` / `withGc` / `with-gc!`) registers a language finalizer (Rust
  `Drop`, JS `FinalizationRegistry`, Python `weakref.finalize`, Racket
  `register-finalizer`) on each far reference `fetch` returns; when the
  collector reclaims it, the finalizer parks one `op:gc-exports` delta of 1
  that the connection's loop drains on its next operation. Scope is just
  `fetch` results, uniform across the four bindings; near refs, promises,
  sturdyrefs, bootstrap, and redeemed handoff tokens are excluded.
  `test/engine/gc_churn_test.zig` proves flat import-row reclamation under
  churn, and each language's binding check watches the wire for the release frame
  after a dropped fetched cap.
- **Handshake and feature negotiation.** `engine.negotiation.negotiate` is the
  pure, symmetric pick of the most-preferred shared CapTP version and codec,
  plus the intersected `model.FeatureSet` (`pipelining`, `handoff`,
  `wire_delta`, `sturdyref`; every bit checked in `session.validate`), over two
  `Offer`s. Named constructors `Offer.goblins()` and `Offer.native()` are the
  two real jobs. In-process `pairing.paired` settles `Offer.native()`;
  `pairing.pairedGoblins` / `pairedWithKeys` settle `Offer.goblins()`.
  `op:start-session` carries only the selected captp-version string. It carries
  no codec or feature operand, so both ends must already share the same offers
  (pairing, shared config, or a locator hint). Goblins interop targets
  authenticated `v1_0` / `"1.0"` over Syrup (`pancake_peer_new`). Native
  pancake-to-pancake prefers `next` / `"pancake-next"` and Cap'n Proto via
  `Offer.native()`, with Syrup / `"1.0"` as fallback. Binding ABI constants
  expose `CAPTP_VERSION_V1_0` / `CAPTP_VERSION_NEXT` (and the TS/Racket
  spellings) for the raw `pancake_peer_new_negotiated` path; Host
  `connect` / `listen` stay on Goblins `"1.0"`.
- **Fail-loud aborts.** When an inbound frame is rejected, whether the codec
  cannot decode it or the session state machine refuses it, the error is
  projected through `engine.abort_projection`: the peer commits a typed
  outbound `op:abort` (via `Peer.commitAbortOutbound`) before the error reaches
  the caller, and closes the CapTP session when the projection requires it —
  including after an app-queued abort once `Peer.step` has put the frame on
  outbound ([ADR-0083](decisions/adr/ADR-0083-outbound-abort-closes-session.md)).
  Handshake refusals queue an abort without leaving `negotiating`. Both inbound
  entry points share the same commit path as `pancake_peer_send_abort`, so a
  partner is never left waiting on a bare host error while an open CapTP
  session should already be closed.
- **Resource caps.** `SessionLimits` bounds the partner-driven tables
  (imports, the seen-handoff replay set, deposited gifts) alongside the
  pipelining caps; any overflow is a loud `*CapExceeded` error that projects
  to a `ResourceExhausted` abort, never a silent drop (ADR-0025).
  `Peer.limits()` reads the effective caps back. The Cap'n Proto decoder adds
  a per-frame traversal budget against pointer aliasing, refusing a
  `TraversalBudgetExceeded` before handing out any lazy view, the same
  defense upstream Cap'n Proto calls `traversalLimitInWords`; Syrup needs no
  counterpart because each collection body is a contiguous sub-slice.
  Hostile-bytes coverage, exhaustive single-byte corruption plus
  `std.testing.fuzz` entry points over both codecs' decode-reencode round
  trips, runs in `test/codec/`.

## Third-party handoff

- **Handoff basics.** Give and receive work end to end, and the Syrup codec
  round-trips the handoff fixtures. The vat-scoped
  `engine.bootstrap.GiftRegistry` is the single gift authority: deposit and
  withdraw bookkeeping, recipient match, and handoff-count replay rejection
  (ADR-0056). Withdrawals are authorized under Ed25519, each certificate
  verified against the key it must be signed by, and
  `engine.handoff_gifter.buildSignedGive` ships the gifter's side of the same
  signing (ADR-0009). The host holding the peers routes the flow from gifter
  to exporter to recipient; the in-repo harness for that routing is
  `test/support/cross_peer.zig`.
- **Crossed hellos collapse to one session.** When two peers dial each other
  at once, the pair keeps the session the higher-keyed peer opened
  (ADR-0030): the sans-io host core (`driver_core.Host`) owns the tiebreak
  registry, and every I/O surface that rides it (`BlockingSession`,
  `driver.Bridge`) answers from that same table. A dial registers its
  outbound before bytes move, an accepted session compares inbound
  start-sessions against the registry, and a listening host signs its bound
  designator into every dial so the comparison keys on a real address. A
  deterministic driver scenario stages the collision and pins the verdict to
  the byte order of the two public identifiers.
- **Transparent handoff, every binding and natively.** Each binding redeems a
  received `desc:handoff-give` through the same `connect` / `fetch` / `send`
  surface, with no handoff choreography in application code; natively,
  `driver.Bridge` + `driver.core.Host` speak both halves (ADR-0076) over the
  same sans-io host core every binding rides through `libpancake_driver`
  (ADR-0072), so an introduction settles as the introduced capability itself
  (the live `goblins-handoff` driver is a consumer). Adapter continuity
  (ADR-0082) ships beside that path: `driver.ResilientClient` classifies dial
  errors and retries under one discovery budget shared with binding iroh
  loops; each successful dial is a new CapTP session, not a Session facade.
  `Host.Options.limits` projects full `SessionLimits`. The completion loop
  offers opt-in fan-in throttle (N→1 proof in
  `test/net/completion_loop_test.zig`), park-kill (`CloseReason.park_kill`),
  and `on_park` metrics. `pancake_host_set_session_limits` exposes selective
  C knobs. `durable_bootstrap` is named on Host Options; `Host.init` refuses
  it until an embedder store lands. Origination is the core's resolve
  interceptor: a published actor that returns a foreign-homed capability
  answers with a signed give. The in-tree three-host scenario
  (`test/driver/core_host_test.zig` byte-fed; `test/driver/bridge_test.zig`
  over a real completion loop) runs originate, give, auto-redeem, and the
  direct call. Underneath both is a connection router, the engine's sans-io
  `Node` (ADR-0066), the router-tables half of Goblins `mycapn` (ADR-0079,
  ADR-0009/ADR-0056). It
  retains the connection's keyed identity, dials the named exporter with that
  identity, signs the `desc:handoff-receive`, withdraws the gift, and hands
  back an ordinary capability, routing later sends to the exporter that hosts
  it. Redeem and origination sequencing is owned once too, as a sans-io serve
  step on the same `engine.Node` (ADR-0067), holding the exporter cache,
  pending dial, withdraw, and gift rows, and per-exporter give-location
  overrides; it consumes what the host feeds it and emits actions the host
  executes (`dial`, `flush`, `settle`, `fail`, `need_gift_id`), with entropy
  always a requested host effect, never generated internally. Each binding
  drives that serve step through the byte-fed host (`pancake_host_*`); the
  native `goblins-handoff` driver answers the same action queue with real
  I/O. No consumer holds redeem or origination orchestration of its own, and
  a claim is offered only on node-dialed exporter connections, so an ordinary
  connection's reply path pays nothing for handoffs. Refs stay bare in all
  four bindings, routed through the node's reserved-id token. This is proven
  against a live Goblins introducer for native Zig (`zig build goblins-handoff`)
  and for all four bindings: `deno-goblins-handoff`, `python-goblins-handoff`,
  `rust-goblins-handoff`, and `racket-goblins-handoff`.
- **Transparent handoff, gifter side, native Zig and all four bindings.** When
  a published actor returns a `Ref` homed on a different connection than the
  one asking, the host's serve step claims the reply, requests gift-id
  entropy, deposits the gift on the home connection, and answers the caller
  with a signed `desc:handoff-give`. The recipe lives in the sans-io
  `engine.Node`, with no application-code choreography. This rests on one
  identity and one gift registry per Host: a Host's `Server`, `connect`, and
  redeem sessions share that Host and its `engine.Node`, so a gift deposited
  on one session is withdrawable on another, the give's signer equals the
  deposit provenance, and a pancake Host serves direct redeems as the
  exporter, engine swiss re-resolution (ADR-0056). Proven end to end by
  `zig build goblins-gift` (native Zig gifter vs live Goblins exporter and
  recipient); `zig build deno-gifter-handoff` (pancake as gifter, exporter,
  and recipient over loopback TCP, broker out of the path); the per-binding
  `deno-goblins-gift`, `python-goblins-gift`, `rust-goblins-gift`, and
  `racket-goblins-gift` check steps; and `zig build demo-rooms-dm` (the rooms
  app introduces two members who then DM directly). The host holds each
  fetched capability under a node-unique foreign-home token, every binding
  reaching enrollment through `pancake_host_*` (ADR-0069), so two imports
  sharing a wire position never collide and each introduction re-gifts the
  right home. A multi-member broker routes each introduction correctly in any
  of the four bindings.

  Cross-process redeem over iroh ships in every binding in both dial
  postures, chosen by what the gift's exporter location names. When it
  carries the exporter's `direct-addresses` as signed hints, the recipient
  dials directly, the relay-less `Direct` posture with no discovery service;
  `zig build demo-rooms-dm-iroh` proves it in-tree across three iroh
  endpoints over encrypted QUIC. When it names the exporter by node id alone,
  the recipient resolves that id under its machine's configured redeem
  posture, `Discovery` (n0 relays plus DNS/pkarr) by default, lowerable to
  `DiscoveryNoRelay` via each binding's `set_redeem_reachability` knob.
  `zig build bindings-iroh-redeem-posture` proves each binding honors its
  configured posture by lowering to `local_discovery` and redeeming a
  hint-less give against an in-process book. The dial retries in every
  binding while the exporter's pkarr record propagates, one settle/retry
  budget mirrored across the four `connect(locator)` dialers.
  `zig build demo-rooms-dm-iroh-discovery` proves the full
  handoff-over-discovery live, and the per-binding
  `zig build bindings-iroh-reachability` check steps prove dial-by-id reach itself,
  two `Discovery`-posture endpoints meeting by node id alone over n0 relays
  and DNS/pkarr. These stay opt-in and outside `check` because
  publish-propagation timing is not self-contained; the offline, deterministic
  counterpart is `local_discovery` in the `*-iroh-loop` check steps.
  `zig build bindings-iroh-handoff` runs the in-tree `Direct`-posture
  handoff checks together, standing up exporter, gifter, and recipient across
  three iroh endpoints in one process, and `zig build bindings-iroh-loop`
  holds every binding to the same scale bar.

## Actors and object capabilities

- **Actors.** `actors.Vat` is a Goblins-shaped layer above the engine: spawn
  local objects, call them synchronously with `near` (`$`), and eventual-send
  with `<-` to get a `Vow` back; an object "becomes" by mutating its own
  state. When a vat is bound to a peer, the same `<-` reaches local or far
  references, a local target running a turn in the vat and a far target
  going out as an `op:deliver`. `bindExport` and `serve` host a local object
  at an export so an inbound deliver runs its turn and resolves the answer.
  The layer is synchronous and owns no I/O (ADR-0036). A vat also offers
  opt-in local time-travel: `snapshot` shares the local actor heap behind
  refcounted state boxes (O(objects), no byte copy) and `restore` rewinds to
  it, with copy-on-write for mutable actors and functional `become` for
  persistent ones backed by a refcounted-HAMT `PersistentMap` (ADR-0060,
  ADR-0061). Time-travel is local-only; it never touches session state or a
  peer. Every binding mirrors the same local-or-far reference model in its
  own idiom, Racket staying Goblins-faithful while Rust, Python, and Deno use
  native language shapes; each proves a far-send round trip in its binding check
  (ADR-0039).
- **Object-capability forwarding proxies.** `Turn.forward` lets an actor
  defer its answer onto an eventual-send to another reference (ADR-0064): the
  turn returns without resolving, and a listener on the forwarded send
  resolves the original answer once it settles, local or far alike.
  `actors.caretaker`, a revocable forwarder, and `actors.attenuate`, a verb
  allow-list forwarder, wrap any `Ref`, near or far, so the proxy is
  wire-transparent and, being a plain actor, answers a near-call exactly as
  it answers a partner's delivery. `test/actors/ocap_test.zig` pins
  forwarding, revocation, attenuation, caretaker-over-attenuator composition,
  and a far caller reaching a hosted caretaker proxy. Every binding ships the
  same `Turn.forward` primitive over its own serve loop (`caretaker` /
  `attenuate`, and Racket's `session-caretaker` / `session-attenuate` /
  `session-revoke!`); each binding check exercises revoke and attenuate over a far
  reference plus a local near-call against both a local and a far target.

## Netlayers and transports

- **Pluggable transports.** A netlayer is a runtime contract the driver
  dispatches against, not a privileged built-in (ADR-0043).
  `net.netlayer.Netlayer` dials a locator to a `Connection` and binds a
  listener; `driver.connectVia` / `acceptVia` resolve the locator's transport
  symbol against a caller-owned slice through `net.netlayer.resolve`, so a
  transport the core never names can plug in by joining that slice, with no
  driver or core edit. Four residents prove the contract is
  transport-general: `net.tcp` (sockets), `net.tcp_keyed`
  ([ADR-0075](decisions/adr/ADR-0075-keyed-tcp-designator.md), same sockets,
  keyed locator grammar), `net.inproc`
  ([ADR-0047](decisions/adr/ADR-0047-in-memory-netlayer.md), an in-process
  switchboard with no sockets, for full in-process OCapN conversations in
  tests), and the sidecar `iroh` resident (ADR-0055, encrypted QUIC, dialed
  by Ed25519 endpoint id, carried by the `transports/iroh` Rust sidecar so
  the pure-Zig archives stay pure Zig).

  The `iroh-interop` check step proves iroh's capstones live: a configurable,
  no-default `Reachability` (`direct`/`discovery`/`discovery_no_relay`/
  `local_discovery`) that dials by node id alone through an address book with
  no hints; the opt-in `iroh-reachability` step proves the same dial-by-id
  live over the public internet, kept out of `check` since publish-propagation
  timing is not self-contained, and each binding has the same proof through
  `bindings-iroh-reachability`. One Ed25519 key per peer is at once the iroh
  node id, the OCapN locator designator, and the session signing key,
  verified on both handshake halves. A sturdyref, node id plus swiss-number,
  outlives an endpoint restart. The handoff substrate reaches over iroh too:
  `zig build iroh-mesh` proves three iroh endpoints where A introduces B to
  C and B reaches C by the gifted node id, withdraws the capability through
  C's bootstrap, and calls it, with B's one key at once its node id, session
  key, and the gift's recipient key.

  iroh serves at scale: the event-driven completion loop of ADR-0057
  (`completion.Loop(iroh.Backend, iroh.DialResolver)` over the sidecar's
  readiness fd, a drained ready-queue, and non-blocking frame I/O) feeds the
  same `driver.Bridge` + `driver_core.Host` spine as TCP (ADR-0076) and
  serves many QUIC connections from one loop thread, proven by
  `zig build iroh-loop`. The TCP scale path is `net.TcpLoop` +
  `driver.Bridge` + `driver_core.Host`: adoption, per-event serve,
  cross-connection `armOutbound`, loop-side redeem dial, and a budgeted drive
  that condemns a flooded connection, proven by `zig build tcp-loop` and both
  theorems in `test/driver/bridge_test.zig`. `zig build iroh-bridge-redeem`
  proves the same bridge for iroh accept, serve, flush, and redeem dial.
  `bench-peer-scaling`'s `served` row extrapolates per-connection core state
  to roughly 1.1 GiB at 500k connections, an in-process projection; its
  opt-in `--live` leg measures TCP loopback under the same stack at stepped
  N. Five hundred thousand remains a budget, not an achievement, until a
  printed `--live`, `tcp-loop`, or `iroh-loop` run updates
  [ladder.md](ladder.md) and this inventory with the step name and measured
  figures in the same diff. The public iroh netlayer C ABI is loop-only, a
  single readiness fd
  (`pancake_iroh_netlayer_readiness_fd`) plus a non-blocking
  `pancake_iroh_netlayer_drain_ready`, and every binding parks on it
  natively: Deno's `IrohLoop`, Python's `_IrohLoop`, Rust's `AsyncFd` task,
  and Racket's `unsafe-file-descriptor->semaphore`, each proven by
  `bindings-iroh-loop`. All four residents dial and host through the same
  `connectVia` / `acceptVia` path with the same verified handshake, and
  adding each one edited no driver, core, or contract file. Stream
  transports expose a `*std.Io.Reader`/`Writer` pair that `net.pumpOver`
  drives; a non-stream transport instead drives the peer directly through
  `Peer.recvStreamPrefix` and `takeOutbound`, the same API a language binding
  uses over the C ABI (ADR-0030).
- **Keyed TCP designator.** `net.tcp_keyed` (`keyed-tcp`, ADR-0075) binds the
  listener's Ed25519 key as the locator designator with the socket address
  riding in `direct-addresses`, verified fail-closed by
  `engine.Peer.expectPartnerKey` (the same pin iroh inherits), checked by
  `test/driver/keyed_tcp_restart_test.zig`. Binding-level dial and host
  surfaces (`listen_keyed_tcp` / `keyed_tcp_locator` / `connect` on a
  `keyed-tcp` URI) and per-binding restart check steps
  (`zig build bindings-keyed-tcp-restart`) ship. The C ABI partner-key pin is
  `pancake_peer_expect_partner_key`; `pancake_host_session_open_accepted`
  carries the direct-addresses hint for a keyed accept. The byte-fed host
  pins iroh dials the same way, and every binding's `listen_iroh` shares one
  seed between the endpoint and the `Host`, proven in
  `test/driver/core_host_test.zig`.
- **OCapN locator URIs.** `model.uri` parses and emits the out-of-band
  bootstrap form, `ocapn://<designator>.<transport>?hints` for a peer and
  `.../s/<swiss-num>` for a sturdyref, against owned `model.PeerLocator` /
  `model.SturdyRef`. Hints are RFC 3986 query parameters, percent-encoding is
  `%XX`-only so a base64 designator round-trips byte-for-byte, and this is
  the format any netlayer address is shared in. The same grammar is core C
  ABI vocabulary: `pancake_uri_parse_peer` / `pancake_uri_parse_sturdyref` and
  the matching `pancake_uri_format_*` convert to and from one opaque
  `PancakeLocator`, so every binding parses and formats through one
  definition instead of a hand-rolled percent codec. The `host:port`
  designator grammar gets the same single-source treatment:
  `model.uri.splitHostPort` is the one split (bracketed IPv6 unwrap
  included), the native TCP netlayer parses through it, and
  `pancake_designator_host_port` / `pancake_locator_host_port` hand the same
  verdict to a consumer dialing with its own sockets. Natively,
  `driver.connect` dials a locator through the netlayer slice the caller
  passes, failing closed when no resident hosts the transport, and signs
  with an explicit `Identity`, never a defaulted key; `driver.connectUriOwned`
  parses a published URI string the same way. `driver.listen` is the
  symmetric host side, binding any netlayer per a `ListenConfig` and handing
  back an owning `driver.Server`. The bindings dial through one
  `connect(locator)` taking an `ocapn://` URI string; there is no `host:port`
  dial (ADR-0062). Over the optional iroh ABI companion, each binding also
  exposes `listen_iroh`, and an iroh partner dials through the same `connect`
  on a node-id locator with an explicit, no-default reachability, proven
  cross-language by `zig build iroh-interop` and exercised by
  `zig build demo-rooms-iroh`.

## C ABI and bindings

- **C ABI and adapters.** The C ABI frame vocabulary is fixed-width and
  release-explicit: borrowed frames dispatch synchronously, managed frames
  transfer ownership without copying, and events return the originating
  frame in the negotiated codec with explicit release and no re-encode.
  Bindings resolve the à-la-carte archives through a publishable cascade
  ([ADR-0077](decisions/adr/ADR-0077-publishable-c-abi-resolve.md)): each
  package ships `c-abi-resolve.json` and downloads language-natively from
  the versioned GitHub release when published, falling through to
  `zig-out` or a bare name otherwise; hygiene and security refusals hard-fail,
  pinned across the ports by `zig build c-abi-extract-check`.
  `pancake_peer_next_event` is the one call a consumer's event loop needs: it
  drives the engine to idle and hands back the next event fully projected, a
  deliver or resolve as structured values (a handoff give included) and
  everything else as its originating wire frame, so the pump-then-poll rule
  and the queue-always-advances rule live in the waist rather than in each
  consumer. CapTP `PANCAKE_EVENT_*` kinds pair with a peer send constructor
  (`pancake_peer_send_*`, `pancake_peer_start_session`, or the handoff deposit /
  withdraw / resolve-give verbs), except `PANCAKE_EVENT_LISTEN`, which is
  engine-synthesized for V1.0 projections and installed on inbound — held by
  `zig build meta-check`. `pancake_peer_send_abort` queues a typed abort;
  after `pancake_peer_step` the CapTP session is closed. `std.Io` appears at
  the adapter boundary, never the core.
  Allocation policy is a `PancakeContext`: the `*_in` constructors allocate a
  whole handle family through a caller-supplied context and free it back
  through the same context (ADR-0031). The authenticated `op:start-session`
  handshake is the default: `pancake_peer_new` opens a negotiating
  authenticated v1.0 peer, and `pancake_peer_start_session` signs the
  canonical location bytes from a caller-supplied 32-byte seed, since the
  library never generates entropy; already-open peers exist only behind
  explicit `*_raw_open` fixture constructors for tests that inject frames
  directly. The ABI ships as composable per-family archives linked à la
  carte, not one umbrella library: `libpancake_ocapn` (the sans-io peer and
  shared vocabulary), `libpancake_net` (the net-core base), one archive per
  transport (`libpancake_net_transport_tcp` / `_inproc` / `_iroh`), and
  `libpancake_driver` (the byte-fed multi-session CapTP host wrapping
  `driver_core.Host`, ADR-0072), covering keyed handshakes, publish and spawn
  (per-session and host-wide giftable), fetch and enliven, send and tell,
  vows and pipelined projections, turn-time forwarding, and the full
  three-party handoff through one action queue the embedder answers.
  `pancake_host_new` / `_new_in` take a `local_turn_budget` (0 means
  unbounded; nonzero caps local-turn amplification per drive, ADR-0076). A
  published object is a foreign behavior the host runs through the vat's
  `spawnHosted` contract, which is why no separate bare-vat archive ships
  (ADR-0072, superseding ADR-0071); host-supplied netlayers and a blocking
  delegated-loop mode are not exported. Every binding rides this one shared
  archive (ADR-0072). Each binding keeps a named `pump` module for the conn
  byte path, a named `action` module for host-action decode and execute, a
  named `promise` module for `RemotePromise` / `session-vow` plus projection
  and the shared fetch/enliven path (a far-send promise factory —
  `promiseFor` / `sendFar` and each language's equivalent), a named `gc`
  module for ADR-0063 distributed GC, a named `dial` module for the unified
  dial executor, and a named `listen` module for `Server` / `listen` /
  keyed-tcp hosting. The embedder-spine module split is complete, including a
  named trampoline module per binding (wire callback, Forward chase, local
  and far send/tell dispatch, ADR-0064 caretaker/attenuate factories, and
  spawn/publish hosting including actor registration — `registerActor` /
  `_register_actor` / `register-hosted-actor!`; Rust keeps spawn/publish on
  `SessionShared`) and Rust's own named `session_shared` module (`Ref` /
  `Caretaker` / `SessionShared`). A Zig-facing `embedder_pump` helper and the
  opt-in `pancake_host_pump_drain` export drain the action queue through
  `pancake_host_next_action` (ADR-0072's fifth amendment keeps the pull-queue
  normative); `PANCAKE_MAX_LOCAL_FORWARD_HOPS` pins the local Forward-chase
  bound every trampoline mirrors. Each archive exports only its own
  `pancake_<family>_*` symbols and shares core types by header layout
  ([ADR-0059](decisions/adr/ADR-0059-composable-c-abi-archives.md)).
  `examples/c/host_embedder_pump.c` is the compiled choreography checklist.
  Above the frame boundary, `libpancake_net_transport_tcp` also ships the
  owning `PancakeTcpSession`, the C spelling of `driver.Session`
  (`pancake_tcp_session_connect` dials, `_fetch` returns a
  `PancakeReference`, `_call` settles into the archive's own
  `PancakeSettled`), proven against a `driver.Server` host in
  `test/c_abi/tcp_session_test.zig`. [`consuming-from-c.md`](consuming-from-c.md)
  is the consumer's route in.
- **One application surface, every binding.** Each binding exposes the same
  small surface in its own idiom, the verbs the
  [bindings contract](../bindings/README.md) enumerates. Every binding hosts
  as well as dials, and `connect` / `listen` complete the keyed, mutually
  verified `op:start-session` handshake before returning, an established
  OCapN session rather than a pre-opened shortcut, with the per-connection
  seed drawn at the I/O boundary. A returned `Ref` marshals as a capability
  argument, so application code never manages export positions, flushes
  frames, or hand-writes a receive loop. In native Zig the surface is one
  owning `driver.Session` (`connect`, `listen`/`accept`, blocking `call`,
  `step`, `serve`); when a connection closes, the driver breaks every
  pending `send` so an outstanding call settles broken instead of hanging,
  and the raw `Peer` and `Vat` stay reachable through `conn.peer` and
  `conn.cv.vat`. The Deno, Python, and Rust `Session`s break pending sends
  the same way when their serve loop ends.
- **Rust C ABI binding check.** A Rust crate links the pancake archives through the
  C ABI and drives a peer smoke test through the public host boundary.

## Applications and demos

- **Three real cross-language applications.** The
  [example applications](../examples/README.md) — rooms, tasks, and tools —
  each run a server and one client per language over one OCapN wire and
  assert the result. Those demos are pancake-to-pancake (and need only `deno`;
  other languages join when present). Live Goblins proof for the binding
  surface is separate and client-direction only: `zig build deno-goblins-interop`,
  `python-goblins-interop`, `rust-goblins-interop`, and `racket-goblins-interop`
  each drive keyed handshake, bootstrap fetch, and one echo call over the C ABI
  — not the demo apps, not binding listen/hosting, and not the native
  projection / enliven / break legs (`goblins-interop` owns those). All run as
  siblings of the in-tree `check`.
- **Accountability application on pancake.** `zig build accountability` runs
  the first real application on pancake's own runtime: KERI-anchored
  identity, a signed Episode per capability invocation, a Merkle
  transparency log, and a host that refuses to account for a caller it
  cannot verify, the refusal path the Syrup codec's exhaustive `.error`
  argument arm makes representable on the wire. Two native pancake peers
  complete an OCapN handshake over a real loopback TCP socket, and every
  invocation produces a verifiable Episode attributing the verified caller.
  The same Affordance is reachable from Deno and Python callers over the C
  ABI (`zig build demo-accountability`): same application, three languages,
  one keyed OCapN session each. A three-party handoff test
  (`zig build accountability-three-party`) proves that after A introduces B
  to C, C attributes B, the true caller, not A. Identity, Episodes, and the
  transparency log stay entirely above pancake. See
  [`examples/apps/accountability-on-pancake/`](../examples/apps/accountability-on-pancake/).
- **Installable CapTP CLI.** `zig build` installs `zig-out/bin/pancake` from
  repo-root `cli/`
  ([ADR-0084](decisions/adr/ADR-0084-pancake-cli-product-boundary.md)). It
  ships progressive everyday `ocapn` (listen, dial, probe, call, tell, fetch,
  and related), `repl` as an alias of `ocapn dial --repl`, curated stdio `mcp`
  (`--tools default|full|readonly`, idle/max-session caps), and `app bot`
  (rooms presence). The `rooms-bot` install name is a thin shim to
  `pancake app bot`. Operability covers identity files, exit codes (including
  `busy` for state-dir lock contention), stderr logs, SIGTERM/SIGINT drain on
  `ocapn listen` / `mcp`, and an exclusive advisory lock on the CapTP state
  directory. Process context uses an explicit front/sink (argv, repl, mcp);
  MCP policy is data on the registry (`mcp: never` for `listen`). Spec B
  (timeline and OTEL) and Spec D (A2A-on-CapTP) are deferred plans under
  [`docs/planning/`](planning/). Example MCP client
  config: [`docs/examples/pancake-mcp.json`](examples/pancake-mcp.json).

## Interop and verification

- **Live Goblins interop, both directions.** `zig build goblins-interop`
  proves a real Spritely Goblins conversation each way (ADR-0035; Goblins as
  installed in the devcontainer / on PATH — not a runtime-pinned version
  string). As a client, pancake spawns a Goblins vat, dials it over `net.tcp`,
  completes the keyed `op:start-session` handshake while verifying Goblins'
  own Ed25519 signature, bootstrap-fetches its echo capability, and calls it
  to a fulfilled resolution. The same client bracket pipelines `op:index` /
  `op:get` against Goblins answers, then enlivens the echo swiss-num through
  the ADR-0012 dedup cache and proves a repeat enliven hits the cache with
  no wire traffic. As a listener, pancake binds a TCP listener and publishes
  a vat actor behind a swiss number; a real Goblins client dials in for a
  settled call, a reverse-pipelined enliven-and-call, and a break path where
  an unknown swiss breaks the fetch vow with pancake's reason. That live
  settlement path is V1.0 answer/bootstrap listen and resolver-callback break.
  Live object-export `op:listen` (immediate fulfill) ships in-tree; listen on
  an unresolved promise export without an answer row remains the ADR-0007
  refuse-loud boundary. It needs `racket` plus the `goblins` collection on
  PATH, so it runs as a sibling of `check`, not inside it. Binding
  `*-goblins-interop` steps prove
  the client direction only over the C ABI (`deno-goblins-interop`,
  `python-goblins-interop`, `rust-goblins-interop`, `racket-goblins-interop`):
  keyed handshake, bootstrap-fetch, and one echo call — not the Zig listener /
  projection / enliven-dedup / break legs, and not binding `enliven()` against
  Goblins.
- **Protocol reference bridge.** `zig build oracle-check` (protocol reference
  fixtures) enumerates shipped message arms, checks pancake-authored Syrup
  fixture parity against the upstream Syrup encoders, and runs engine scenarios
  including the multi-peer third-party handoff. It also drives a
  deliver-then-resolve round trip, a handshake that auto-serves a bootstrap
  fetch, and a cross-mode parity check proving the borrowed (`recvBorrowed`)
  and owned (`feedOwned` + `step`) inbound entry points run one dispatcher with
  byte-identical observable output.
- **Wall-clock performance tripwire.** `zig build perf-check`, a member of
  `check`, runs the hot-path benches in ReleaseFast and holds the ladder step
  2 ceilings for warm inbound dispatch, answered outbound send, and the
  `op:gc-answers` release-storm growth ratio (ADR-0073).
- **Architecture check.** The layer DAG is compiler-enforced: each `src/`
  layer is an internal build.zig module with a one-way import table
  (ADR-0040), and each sibling wire codec is its own module below the codec
  layer (ADR-0048), so a cross-layer or cross-codec reach fails to compile.
  `zig build arch-check` verifies the same `layer_table` declaration against
  the tree and holds the content bans a module graph cannot express: no
  `std.Io` or threading in the core, and no platform syscall namespaces in
  portable code.
- **Meta scaffolding check.** `zig build meta-check` verifies canonical
  `.agents` guidance, thin Cursor/Claude overlays, hook and Serena MCP
  wiring, ignored generated state, documented build-step names, and the
  doc-drift registry of docs that must match today's code.
