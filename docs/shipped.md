# What ships today

This is the inventory of implemented behavior. Every claim on it is held by a
gate, a scenario, or a live interop run, and moves with the code: one that
stops matching the tree is drift. Its complement is the
[boundaries page](boundaries.md), which names where the implemented surface ends.
For how the pieces fit together, read the [architecture](architecture.md); for
where this is all going, the [vision](vision.md).

**CapTP sticky note (ADR-0079).** `Host` / `PancakeHost` / binding `Host` is the
multi-session CapTP product (owns `engine.Node`). `engine.Node` is the sans-io
handoff router. Binding `Session` is the one-partner app object
(`driver.Session` / `PancakeTcpSession`). `BlockingSession` is `Served` +
`net.Connection` with a blocking pump. `HostedActor` / `spawnHosted` is
embedder-hosted behavior. `DialResolver` is transport dial resolve. Goblins
`mycapn` is two roles — endpoint ≈ Host, router tables ≈ `engine.Node`. Binding
`Node` and binding `Connection` are deleted; `net.Connection` remains the
framed byte stream.

Implemented Zig behavior includes:

- **Frames.** `Frame` has one visible owner, `FrameView` borrows bytes, and
  `FrameShape` carries explicit byte vs word-aligned frame metadata.
- **Model.** Codec-neutral CapTP model types exist independently of the wire
  encoding that carried them.
- **Syrup.** The Syrup codec encodes the current message model against
  pancake-authored Syrup byte vectors (cross-checked through the upstream Syrup
  encoders, not Goblins captures), decodes borrowed views for the supported
  operation set, and materializes owned messages for engine-surfaced operations
  including start-session and handoff. Encoding is measure-then-fill. A
  non-allocating length pass computes the exact byte count, then one
  exact-sized allocation is filled. So there is one allocation per encode and
  zero reallocs at any payload size, pinned by `test/codec/encode_budget_test.zig`.
- **Session/engine.** Sessions own profile/features, lifecycle,
  import/export/answer/release authority, validate-then-apply, and feature
  gates. `Peer` remains caller-owned and drives outbound profile-aware encoding,
  V1.0 resolve-me-desc synthesis, borrowed inbound dispatch, owned queued
  inbound frames, outbound drains, and application-visible events for the
  supported decoded operations.
- **Third-party handoff.** Give and receive work end to end, and the Syrup codec
  round-trips the handoff fixtures. The vat-scoped
  `engine.bootstrap.GiftRegistry` is the single gift authority: deposit and
  withdraw bookkeeping, recipient match, and handoff-count replay rejection
  (ADR-0056). Withdrawals are authorized under Ed25519: each certificate is
  verified against the key it must be signed by, so a give signed by any other
  key is refused, and `engine.handoff_gifter.buildSignedGive` ships the
  gifter's side of the same signing (ADR-0009). The host that holds the peers
  routes the flow from gifter to exporter to recipient; the in-repo harness for
  that routing lives in `test/support/cross_peer.zig`.
- **Promise pipelining.** Sessions own the inbound-answer table, listeners, and
  stored resolutions; `engine.pipeline` carries the pure transforms. A pipelined
  `op:deliver` against an unresolved answer queues and drains to the resolution
  (local delivery, requeue, or far-forward) when `op:resolve` settles. A
  multi-hop call path decomposes at the sender into chained single-hop frames,
  so every `desc:answer` on the Syrup wire stays flat. The questioner side ships
  across the surface (ADR-0065): the driver's `send`/`sendToAnswer`/
  `settleVow`, the C session's non-blocking send, and a vow-as-send-target in
  every binding, so a dependent chain costs one round trip. The TCP transport
  disables Nagle on every socket so a batched send is not held for a delayed-ACK
  timer; the `bench-langs` throughput unit runs the taskboard script pipelined.
- **Field, index, and tag projections.** A caller pipelines `op:get`,
  `op:index`, or `op:untag` against a pending answer to reach a field, element,
  or tag of the eventual value without waiting for it to settle (ADR-0050,
  ADR-0052). The engine opens the projected answer, anchors the projection on
  the receiver, and resolves it when the source settles or breaks;
  `test/engine/projection_test.zig` and `abort_projection_test.zig` pin the
  fulfilled and broken paths. Every binding exposes the surface, the Rust
  `RemotePromise::get`/ `index`/`untag`, the Python
  `RemotePromise.get`/`index`/`untag`, the Racket `conn-index`/`conn-untag`,
  and the TypeScript `RemotePromise.index`/`untag`.
- **Relayed-resolution forwarding.** An `op:listen` on a handoff-imported
  promise installs against the third-party-hosted import; when the introducing
  session forwards the host's resolution,
  `engine.cross_peer.drainRelayedResolutions` fires the listeners and stores the
  resolution so a late listener fires immediately (ADR-0009). A relayed
  promise resolves once: `recordRelayedResolution` refuses a second relay for
  the same import, so every listener observes the same settled value.
- **Bootstrap fetch (initiator).** `engine.fetch` builds the canonical
  bootstrap-fetch `op:deliver`. It matches either kind of partner settlement, an
  `op:resolve` or a resolver-callback `op:deliver`, into an owned outcome. The
  adapter drives the wire loop between those two halves; the core stays no-I/O.
- **Bootstrap fetch (responder).** `Peer.registerBootstrapCap(swissnum)` exposes
  a local capability behind a swiss number; an inbound `'fetch` to the bootstrap
  export is then recognized and answered automatically by the dispatcher
  (`engine.bootstrap` synthesizes the `Resolve`; the V1.0 path renders it as a
  resolver-callback), with `break "unknown swissnum"` for an unregistered swiss
  number (ADR-0006 responder half).
- **Sturdyref enliven (initiator).** `engine.sturdyref` turns a persistent
  `(peer, swissnum)` sturdyref into a live `Reference` over the existing
  bootstrap-fetch: a feature-negotiated + open precondition gate, a session
  dedup cache that maps a swiss number to its `(import_position, kind)` (the
  kind is preserved) and short-circuits a repeat enliven with no wire traffic,
  and an in-flight marker that collapses a concurrent enliven onto the
  outstanding answer. The wire loop is adapter-driven, exactly like
  `engine.fetch`. The `pancake_peer_prepare_enliven` /
  `pancake_peer_record_enlivenment` C ABI seam exposes the cache to consumers,
  and every binding ships a one-call `enliven()` convenience over it (parse the
  sturdyref, consult the cache, drive the fetch on a miss). It is proven against
  a live Goblins-published cap (the dedup leg of `zig build goblins-interop`).
- **Distributed equality.** `model.referencesEqual` is the codec-neutral
  structural-equality predicate, the in-memory evidence for OCapN Pass
  Invariant Equality (ADR-0012): two references that name the same target
  compare equal regardless of which codec or profile carried them.
  A host that keeps one session per peer pair (ADR-0012's session-pair
  uniqueness) reduces cross-session equality to same-session equality on
  `(import_position, kind)`; the sturdyref dedup cache supplies the
  sturdyref-vs-handoff collapse.
- **Distributed GC (opt-in finalizers).** The engine sends and accounts the
  wire-delta GC messages (`op:gc-exports` / `op:gc-answers` decrement the matching
  table rows, balanced inbound), and every binding can drive a release from a
  dropped handle behind an opt-in, off by default (ADR-0063). A connection put
  into GC mode (`with_gc` / `withGc` / `with-gc!`) registers a language finalizer
  (Rust `Drop`, JS `FinalizationRegistry`, Python `weakref.finalize`, Racket
  `register-finalizer`) on each far reference returned by `fetch`; when the
  collector reclaims it, the finalizer parks one `op:gc-exports` delta of 1 that
  the connection's loop drains to the wire on its next operation. Scope is just
  `fetch` results (uniform across the four bindings) with near refs, promises,
  sturdyrefs (owned by the enliven dedup cache), bootstrap, and redeemed handoff
  tokens excluded. `test/engine/gc_churn_test.zig` proves flat import-row
  reclamation under churn, and each binding's dogfood watches the wire for the
  release frame after a dropped fetched cap.
- **Object-capability forwarding proxies (answer-forwarding).** `Turn.forward` lets an
  actor defer its answer onto an eventual-send to another reference (ADR-0064):
  the turn returns without resolving, and a listener on the forwarded send
  resolves the original answer once it settles, local delivery or far reply
  alike. On it, `actors.caretaker` (a revocable forwarder) and
  `actors.attenuate` (a verb allow-list forwarder) wrap *any* `Ref`, near or far,
  so the proxy is wire-transparent and, being a plain actor, answers a near-call
  from its own host exactly as it answers a partner's delivery.
  `test/actors/ocap_test.zig` pins forwarding, revocation, attenuation,
  caretaker-over-attenuator composition, and a far caller reaching a hosted
  caretaker proxy. Every binding ships the same `Turn.forward` primitive over its
  own serve loop: a caretaker/attenuator is an ordinary spawned actor whose
  behavior returns the binding's forward value (`caretaker`/`attenuate`, and the
  Racket `session-caretaker`/`session-attenuate`/`session-revoke!`). Each dogfood
  exercises revoke + attenuate over a far reference plus a local near-call to the
  host's own proxy against both a local and a far target.
- **Handshake profile and feature negotiation.** `engine.negotiation.negotiate`
  is the pure, symmetric pick of the most-preferred shared profile and codec,
  plus the intersected `model.FeatureSet`, over two `Offer`s. `op:start-session`
  carries the selected profile version but no feature operand (pancake does not
  add fields to OCapN's wire shapes), so both ends compute the same answer from
  the same offers. Goblins interop is the target policy for authenticated `v1_0`
  over Syrup; pancake-to-pancake negotiation can choose `v1_0` or PreSpec, and
  Syrup or Cap'n Proto where supported.
- **Fail-loud aborts.** When an inbound frame is rejected, whether because the
  codec cannot decode it or because the session state machine refuses it, the
  error is projected through `engine.abort_projection`. The peer sends a typed
  outbound `op:abort` before the error reaches the caller, and closes the
  session when the protocol requires it. Both inbound entry points use the same
  projection, so a partner is never left waiting on a bare host error.
- **Resource caps.** `SessionLimits` bounds the partner-driven tables (imports,
  the seen-handoff-count replay set, and deposited gifts) alongside the
  existing pipelining caps; each overflow is a loud `*CapExceeded` error that
  projects to a `ResourceExhausted` abort (ADR-0025), never a silent drop.
  `Peer.limits()` reads the effective caps back, so an embedder never reaches
  into session state for them. The Cap'n Proto decoder adds a per-frame
  traversal budget, because the pointer format permits aliasing and so a small
  frame can name exponentially many node visits. An eager charge pass over the
  frame refuses a `TraversalBudgetExceeded` before any lazy view is handed out,
  the same defense upstream Cap'n Proto calls `traversalLimitInWords`. Syrup needs
  no counterpart: each collection body is a contiguous sub-slice, so total
  work is bounded by frame length. Hostile-bytes coverage runs in
  `test/codec/`: exhaustive single-byte corruption plus `std.testing.fuzz`
  entrypoints over both codecs' decode-reencode round trips.
- **C ABI and adapters.** The C ABI frame vocabulary is fixed-width and
  release-explicit: borrowed frames dispatch synchronously, managed frames
  transfer ownership without copying, and events return the originating frame in
  the negotiated codec with explicit release and no re-encode.
  Bindings resolve the à-la-carte archives through a publishable cascade
  ([ADR-0077](decisions/adr/ADR-0077-publishable-c-abi-resolve.md)): each
  package ships `c-abi-resolve.json` and downloads language-natively from the
  versioned GitHub release when `releases_published` is true (otherwise the
  cascade falls through to `zig-out` / bare name unless `PANCAKE_DOWNLOAD=1`),
  so a published binding does not need a Zig checkout. Hygiene and security
  refusals hard-fail; `zig build c-abi-extract-check` pins zip-slip/symlink
  refuse across the ports.
  `pancake_peer_next_event` is the one call a consumer's event loop needs: it
  drives the engine to idle and hands back the next event fully projected. A
  deliver or a resolve arrives as structured values, a handoff give included;
  every other kind, and any value the typed surface cannot carry, arrives as
  its originating wire frame. The pump-then-poll rule, the typed-or-opaque
  routing, and the queue-always-advances rule therefore live in the waist, not
  in each consumer. The locator surface carries the `host:port` designator
  grammar the same way: `model.uri.splitHostPort` is the one split (bracketed
  IPv6 unwrap included), the native TCP netlayer parses through it, and
  `pancake_designator_host_port` / `pancake_locator_host_port` hand the same
  verdict to a consumer dialing with its own sockets — the former when the
  designator bytes are already in hand (redeem/DIAL), the latter from a
  parsed locator handle. `std.Io` appears
  at the adapter boundary, not in the core. Allocation policy is a
  `PancakeContext`: the `*_in` constructors allocate a whole handle family
  through a context you supply and free it back through the same context
  (ADR-0031). The authenticated `op:start-session` handshake is the C ABI
  default, `pancake_peer_new` opens a negotiating authenticated v1.0 peer and
  `pancake_peer_start_session` signs the canonical location bytes from a
  caller-supplied 32-byte seed (the library never generates entropy), so a
  binding reaches an open session with a real Goblins vat without
  re-implementing the crypto. Already-open peers exist only behind explicit
  `*_raw_open` fixture constructors for tests that inject frames directly. The
  ABI ships as a set of composable per-family archives linked à la carte, not
  one umbrella library: `libpancake_ocapn` carries the sans-io peer and the
  shared vocabulary (`pancake_ocapn.h`), `libpancake_net` is the
  net-core base,
  and each transport is its own archive, `libpancake_net_transport_tcp`
  (`pancake_net_transport_tcp.h`), `libpancake_net_transport_inproc`
  (`pancake_net_transport_inproc.h`), and `libpancake_net_transport_iroh`
  (`pancake_net_transport_iroh.h`). The byte-fed host tier is its own archive:
  `libpancake_driver` (`pancake_driver.h`) ships the byte-fed
  multi-session CapTP host (`pancake_host_*`) wrapping the sans-io
  `driver_core.Host` — keyed handshakes, publish/spawn (per session and
  host-wide giftable), fetch/enliven, send/tell, vows and pipelined
  projections, turn-time forwarding, and the full three-party handoff driven
  through one action queue (dials, gift-id entropy, flushes) the embedder
  answers (ADR-0072). `pancake_host_new` / `_new_in` take a
  `local_turn_budget` (0 = unbounded; nonzero caps local-turn amplification
  per drive, ADR-0076). A published object is a foreign behavior the host runs
  through the vat's `spawnHosted` contract, which is why no separate bare-vat
  archive ships (ADR-0072, superseding ADR-0071; the Zig `actors` module
  stands unchanged). Host-supplied netlayers and a blocking delegated-loop
  mode are not exported. Every binding rides this archive; it is the one shared
  runtime (ADR-0072). Each binding keeps a named `pump` module for the conn
  byte path (keyed handshake + feed/flush/serve + `last_abort`), a named `action` module for host-action decode+execute (one
  `arms` table in `tools/binding_host_action_gen.zig` drives typed decode for
  all four bindings via `gen-binding-host-action`; Python's `HostAction` is a
  frozen-dataclass union), a named `promise` module for `RemotePromise` /
  `session-vow` + projection and the shared fetch/enliven mint→await→classify
  path (Pass 3a / 4b) plus the far-send promise factory (Pass 4d/4f: `promiseFor` /
  `_promise_for` / `send_promise` / `sendFar` / `_send_far` / `session-far-send`) and the
  `op:index`/`op:untag` projection FFI, a named `gc` module for ADR-0063
  distributed GC (Pass 3b: `withGc` / `trackImport` / `drainGc` live in the
  gc module; Session only binds and opts in), a named `dial` module for the unified dial
  executor (Pass 3c), a named `listen` module for `Server` / `listen` /
  keyed-tcp hosting (Pass 3d), and parks
  mid-turn `pancake_host_session_release` (gated by `meta-check`);
  `examples/c/host_embedder_pump.c` is the compiled choreography
  checklist.   The embedder-spine module split is complete, including a named
  `trampoline` module per binding (wire callback, Forward chase, local
  send/tell plus far-tell mint where the language splits that arm, near/far
  send·tell dispatch, ADR-0064 caretaker/attenuate factories, spawn/publish
  hosting including actor registration — `registerActor` / `_register_actor` /
  `register-hosted-actor!` on Racket; Rust keeps spawn/publish on `ConnShared`) and
  Rust's named `conn` module (`Ref` / `Caretaker` / `ConnShared`). A Zig-facing
  `embedder_pump` helper and
  the opt-in C export `pancake_host_pump_drain` drain the action queue through
  `pancake_host_next_action` (ADR-0072 fifth amendment — pull-queue stays
  normative). `PANCAKE_MAX_LOCAL_FORWARD_HOPS` pins the local Forward chase
  bound every trampoline mirrors. Each archive exports only its own
  `pancake_<family>_*` symbols and shares core types by header layout
  (ADR-0059). Above the frame boundary, `libpancake_net_transport_tcp` also
  ships the owning `PancakeTcpSession`: the C spelling of the Zig
  `driver.Session` (`pancake_tcp_session_connect` dials, `_fetch` returns a
  `PancakeReference`, and `_call` settles into the archive's own
  `PancakeSettled` you free with `_settled_release`), reusing
  `pancake_ocapn.h`'s reference/argument value vocabulary by layout, so a C
  consumer dials, fetches, and calls without hand-running the pump; the archive
  embeds `driver` for it, while the sans-io frame surface stays runtime-free
  (ADR-0062). It is proven against a `driver.Server` host in
  [`test/c_abi/tcp_session_test.zig`](../test/c_abi/tcp_session_test.zig).
  [`consuming-from-c.md`](consuming-from-c.md) is the consumer's route in.
- **Protocol oracle bridge.** `zig build oracle-check` enumerates shipped
  message arms, checks pancake-authored Syrup fixture parity across the upstream
  Syrup encoders, and runs engine scenarios including the multi-peer third-party
  handoff. The oracle also drives a deliver-then-resolve round-trip, a
  handshake that auto-serves a bootstrap fetch (the ADR-0006 responder half),
  and a cross-mode parity check that proves the borrowed (`recvBorrowed`) and
  owned (`feedOwned` + `step`) inbound entry points run one dispatcher
  (byte-identical observable output).
- **Actors.** `actors.Vat` is a Goblins-shaped layer above the engine. You spawn
  local objects, call them synchronously with `near` (`$`), and eventual-send
  to them with `<-` to get a `Vow` back. An object "becomes" by mutating its own
  state. When a vat is bound to a peer, the same `<-` works for local and far
  references. A local target runs a turn in the vat. A far target goes out as an
  `op:deliver` over the peer. `bindExport` and `serve` host a local object at an
  export, so a partner's inbound deliver runs the object's turn and resolves the
  answer. The layer is synchronous and owns no I/O (ADR-0036). A vat also offers
  opt-in local time-travel: `snapshot` shares the local actor heap behind
  refcounted state boxes (O(objects), no byte copy) and `restore` rewinds to it,
  with copy-on-write for mutable actors and functional `become` for persistent
  ones, backed by a refcounted-HAMT `PersistentMap` for cheap incremental
  updates (ADR-0060, ADR-0061). Time-travel is local-only: it never captures
  session state or rewinds a peer. Every binding mirrors the same local or far
  reference model in its own idiom. Racket stays Goblins-faithful; Rust, Python,
  and Deno use native language shapes. Each binding proves a far-send round-trip
  in its dogfood (ADR-0039).
- **One application surface, every binding.** Each binding exposes the same
  small surface in its own idiom, the application verbs the
  [bindings contract](../bindings/README.md) enumerates. Every binding hosts as
  well as dials, and `connect` / `listen` complete the keyed, mutually verified
  `op:start-session` handshake before they return, an established OCapN
  session, not a pre-opened test shortcut, with the per-connection seed drawn at
  the I/O boundary because the sans-io core never generates entropy. A returned
  `Ref` marshals as a capability argument, so application code never manages
  export positions, flushes frames, or hand-writes a receive loop. In native Zig
  the same surface is one owning `driver.Session` (`connect`,
  `listen`/`accept`, blocking `call`, `step`, `serve`), sized by one `frame_cap`
  option; when the connection closes, the driver breaks every pending `send` so
  an outstanding call settles broken instead of hanging, and the raw `Peer` and
  `Vat` stay reachable through `conn.peer` and `conn.cv.vat` for handoff,
  pipelining, and session control. The Deno, Python, and Rust `Session`s
  break pending sends the same way when their serve loop ends.
- **Three real cross-language applications.** The
  [example applications](../examples/README.md) (rooms, tasks, and tools) each
  run a server and one client per language over one OCapN wire and assert the
  result. That the same `connect` / `fetch` / `send` surface is
  OCapN-conformant is proven against a real Goblins vat, not just between
  pancake peers: `zig build deno-goblins-interop`, `python-goblins-interop`,
  `rust-goblins-interop`, and `racket-goblins-interop` each drive their
  binding's application surface through the keyed handshake, fetch, and call
  against live Goblins. The demos need only `deno`; other-language participants
  join when their runtimes are present, and all run as siblings of the hermetic
  `check`.
- **Crossed hellos collapse to one session.** When two peers dial each other
  at once, the pair keeps the session the higher-keyed peer opened (ADR-0030):
  the sans-io host core (`driver_core.Host`) owns the tiebreak registry, and
  the I/O surfaces that ride it (`BlockingSession`, `driver.Bridge`) answer from
  that same table. A dial registers its outbound before bytes move,
  accepted sessions compare inbound start-sessions against the registry, and
  a listening host signs its bound designator into every dial so the comparison
  keys on a real address. A deterministic driver scenario stages the collision
  and pins the verdict to the byte order of the two public identifiers.

- **Transparent three-party handoff in every binding and natively.** Each
  binding redeems a received `desc:handoff-give` through the _same_ `connect`
  / `fetch` / `send` surface, with no handoff choreography in application
  code; a native Zig host speaks both halves through `driver.Bridge` +
  `driver.core.Host` (ADR-0076), the completion-loop embedder over the same
  sans-io host core every binding rides through `libpancake_driver`
  (ADR-0072), so an introduction settles as the introduced capability itself
  (the live `goblins-handoff` driver is its consumer). Origination is the
  core's resolve interceptor: a published actor that returns a foreign-homed
  capability answers with a signed give. The hermetic three-host scenario
  (`test/driver/core_host_test.zig` byte-fed;
  `test/driver/bridge_test.zig` over a real completion loop) runs originate, give,
  auto-redeem, and the direct call.   Underneath both
  is a connection router: the engine's sans-io `Node` (ADR-0066), the
  router-tables half of Goblins `mycapn` (endpoint ≈ `Host`; ADR-0079,
  ADR-0009/ADR-0056). It retains the connection's keyed
  identity, dials the named exporter with that same identity, signs the
  `desc:handoff-receive`, withdraws the gift, and hands back an ordinary
  capability, routing later sends to the exporter that hosts it. The redeem and
  origination *sequencing* is owned once too, as a sans-io serve step on the
  same `engine.Node` (ADR-0067). The node holds the state the sequence needs: the
  exporter cache, the pending dial, withdraw, and gift rows, and the
  per-exporter give-location override. It consumes what the host feeds it and
  emits data actions the host executes: `dial`, `flush`, `settle`, `fail`, and
  `need_gift_id` (entropy is a host effect it requests, never generates). Each
  binding drives the byte-fed host (`pancake_host_*`), which runs that serve
  step internally; the native `goblins-handoff` driver answers the same action
  queue with real I/O. No consumer holds redeem or origination orchestration,
  an exporter cache, or pending bookkeeping of its own, and a claim is offered
  only on node-dialed exporter connections, so an ordinary connection's reply
  path pays nothing for handoffs. The application never sees the give or the
  second connection, and the public ref / send surface is unchanged: every
  binding routes a redeemed capability through the node's reserved-id token (a
  synthetic far id the sans-io `Node` maps to the exporter connection that
  hosts it), so refs stay bare in all four. This is proven against a live
  Goblins introducer for all four: `zig build deno-goblins-handoff`,
  `python-goblins-handoff`, `rust-goblins-handoff`, and `racket-goblins-handoff`
  each redeem Bob's greeter from Alice and then call Bob directly, the binding
  counterpart of the Zig-driver `goblins-handoff`.
- **Transparent three-party handoff, gifter side (all four bindings).** Every
  binding now _originates_ a handoff as transparently as it redeems one: when a
  published actor returns a `Ref` whose home is a different connection than the
  one asking, the host's serve step claims the reply, asks for gift-id entropy,
  deposits the gift on the home connection, and answers the caller with a
  signed `desc:handoff-give`. The gifter recipe lives in the sans-io `engine.Node`,
  with no choreography in application code. This rests on **one identity and
  one gift registry per Host**: a Host's `Server`, `connect`, and redeem
  sessions share that Host (and the `engine.Node` it owns), so a gift deposited on one session is
  withdrawable on another, the give's signer equals the deposit provenance, and
  a **pancake Host serves direct redeems as the exporter** (engine swiss
  re-resolution, ADR-0056). Proven end to end: `zig build deno-gifter-handoff`
  (pancake is gifter, exporter, and recipient over loopback TCP, broker out of
  the path); the per-binding `deno-goblins-gift`, `python-goblins-gift`,
  `rust-goblins-gift`, and `racket-goblins-gift` gates (each binding mints a
  give a _live_ Goblins recipient redeems against a live Goblins exporter); and
  `zig build demo-rooms-dm` (the rooms app introduces two members who then DM
  directly, the room never relays). The host holds each fetched capability
  under a node-unique foreign-home token (every binding reaches enrollment
  through `pancake_host_*`; ADR-0069), so two
  imports that share a wire position never collide and each introduction
  re-gifts the right home (ADR-0069). A multi-member broker routes each
  introduction correctly in any of the four bindings.
  Cross-process redeem over iroh ships in every binding in **both** dial
  postures, chosen by what the gift's exporter location names. When it carries the
  exporter's `direct-addresses` as signed hints (the give codec round-trips them
  through decode/view/owned/encode, and the C ABI redeem projection re-parses them
  into the dial URI), the recipient redeems by dialing the exporter **directly**:
  the relay-less `Direct` posture, no discovery service; `zig build demo-rooms-dm-iroh`
  proves it hermetically across three iroh endpoints over
  encrypted QUIC. When it names the exporter by **node id alone** (no hints), the
  recipient resolves that id under its machine's configured redeem posture,
  `Discovery` (n0 relays + DNS/pkarr) by default, lowerable to `DiscoveryNoRelay`
  for a no-relay policy via each binding's `set_redeem_reachability` knob. That
  the redeem honors the configured posture is proven hermetically per binding by
  `zig build bindings-iroh-redeem-posture`
  (`deno-`/`python-`/`rust-`/`racket-iroh-redeem-posture`): each lowers its recipient
  posture to `local_discovery` and redeems a hint-less give by resolving the
  exporter's id through an in-process book, discriminating, since the default
  `Discovery` would need the network. The
  dial retries in **every** binding while the exporter's pkarr record propagates
  (one settle/retry budget mirrored across the four `connect(locator)` dialers,
  covering both the `Discovery` and `DiscoveryNoRelay` postures). `zig build demo-rooms-dm-iroh-discovery`
  proves the full handoff-over-discovery live, and the per-binding
  `zig build bindings-iroh-reachability` gates
  (`python-`/`rust-`/`racket-iroh-reachability`)
  prove the dial-by-id reach itself, two `Discovery`-posture endpoints meeting by
  node id alone over n0 relays + DNS/pkarr. These are opt-in and kept out of
  `check` because publish-propagation timing is not hermetic (the same posture
  `iroh-reachability` gates); the offline, deterministic dial-by-id counterpart is
  `local_discovery` in the `*-iroh-loop` gates. Both halves of an iroh handoff
  (minting a give whose exporter location names an iroh endpoint and redeeming it
  transparently) thus ship in **every** binding (Rust, Python, Racket, and
  TypeScript/Deno), in both reachability postures. `zig build bindings-iroh-handoff`
  runs the hermetic `Direct`-posture handoff gates together, standing up exporter,
  gifter, and recipient across three iroh endpoints in one process.
- **Accountability application on pancake.** `zig build accountability` runs the
  first real application on pancake's own runtime: KERI-anchored identity, a
  signed Episode per capability invocation, a Merkle transparency log, and a
  host that refuses to account for a caller it cannot verify, the refusal path
  the Syrup codec's exhaustive `.error` argument arm makes representable on the
  wire. Two native pancake peers complete an OCapN handshake over a real
  loopback TCP socket, and every invocation produces a verifiable Episode
  attributing the verified caller. The same Affordance is reachable from Deno
  and Python callers over the C ABI (the `libpancake_ocapn` + transport
  archives, `zig build demo-accountability`): same application, three languages,
  one keyed OCapN session each. A three-party handoff test
  (`zig build accountability-three-party`) proves that after A introduces B to
  C, C attributes B (the true caller), not A. Identity, Episodes, and the
  transparency log stay entirely above pancake. See
  [`examples/apps/accountability-on-pancake/`](../examples/apps/accountability-on-pancake/).
- **Pluggable codecs.** Codecs resolve through an open comptime registry keyed
  by a non-exhaustive `model.CodecId`. The built-ins are `syrup` and `capnp`. A
  Zig consumer adds another codec by declaring `pub const pancake_codecs` in the
  root source file. Dispatch still unrolls at comptime, so the open registry
  keeps the same direct calls as the built-in set (ADR-0026).
- **Pluggable transports.** A netlayer is a runtime contract the driver
  dispatches against, not a privileged built-in (ADR-0043). A
  `net.netlayer.Netlayer` dials a locator to a `Connection` and binds a
  listener. `driver.connectVia` and `acceptVia` resolve the locator's transport
  symbol against a caller-owned `[]const net.netlayer.Netlayer` slice through
  `net.netlayer.resolve`. A transport the core never names can plug in by
  joining that slice, with no driver or core edit.

  The contract has four residents, which is what proves it is
  transport-general rather than socket-shaped. `net.tcp` is the socket
  transport. `net.tcp_keyed` ([ADR-0075](decisions/adr/ADR-0075-keyed-tcp-designator.md))
  reuses those sockets and owns only the keyed locator grammar. `net.inproc`
  ([ADR-0047](decisions/adr/ADR-0047-in-memory-netlayer.md)) is a genuinely
  different one: an in-process switchboard that wires a dialer and a listener
  through two in-process byte pipes, with no sockets and no file descriptors,
  for full in-process OCapN conversations in tests and mocks. The sidecar
  `iroh` resident (ADR-0055), registered like any other, not a `net` export, is
  the encrypted one: each connection is one bidirectional QUIC stream from a
  real iroh endpoint, dialed by Ed25519 endpoint id, carried by the
  `transports/iroh` Rust sidecar staticlib so it stays outside the pure-Zig
  archives; it links into the `iroh-interop` gate and into
  `libpancake_net_transport_iroh`, the separate optional public C ABI companion
  that carries iroh to the bindings, exporting only `pancake_iroh_*` and sharing
  the core types with `libpancake_ocapn` by layout through the
  `src/c_abi/shared/` vocabulary leaf, so a consumer links both libraries
  ([ADR-0059](decisions/adr/ADR-0059-composable-c-abi-archives.md)). The
  `iroh-interop` gate proves the cluster's iroh capstones live: the netlayer
  takes a configurable, no-default `Reachability`
  (`direct`/`discovery`/`discovery_no_relay`/`local_discovery`) and **dials by
  node id alone** through an address book (no direct-address hints), and the
  opt-in `iroh-reachability` step proves that same dial-by-id **live over the
  public internet**, two `discovery`-posture peers reaching each other through
  n0's relays and DNS/pkarr with no hints (kept out of `check` because
  publish-propagation timing is not hermetic); each binding has the same live proof
  through its own `connect(locator)` (`zig build bindings-iroh-reachability`); **one
  Ed25519 key** per peer is
  at once the iroh node id, the OCapN locator designator, and the session
  signing key, verified on both handshake halves (`driver.connectVia` /
  `acceptVia` with a `.keyed` `Identity`); and a **sturdyref** (node id plus
  swiss-number) **outlives an endpoint restart**. The handoff substrate reaches
  over iroh too: `zig build iroh-mesh` proves the **mesh**: three iroh
  endpoints where A introduces B to C, and B reaches C **by the gifted node
  id**, withdraws the gifted capability through C's bootstrap (C's engine
  verifying both certificates), and calls it; B's one key is its node id, its
  session key, and the gift's named recipient at once, so the introduced
  recipient and the dialed endpoint are provably the same key. iroh serves at
  scale: the event-driven completion loop of ADR-0057
  (`completion.Loop(iroh.Backend, iroh.DialResolver)` over the sidecar's readiness fd + drained
  ready-queue + non-blocking frame I/O) feeds the same `driver.Bridge` +
  `driver_core.Host` spine as TCP (ADR-0076) and serves many QUIC connections
  from **one loop thread**, proven by `zig build iroh-loop`. The TCP scale path
  is `net.TcpLoop` + `driver.Bridge` + `driver_core.Host`: adoption (accepted
  and dialed), per-event serve, cross-connection `armOutbound`, loop-side redeem
  dial (`Loop.dialLocator` → `openDialedOver` → `exporterDialed`), and a budgeted drive
  that condemns a flooded connection — proven by `zig build tcp-loop` and both
  theorems in `test/driver/bridge_test.zig` (gifter deposit via
  `armOutbound`, recipient redeem on one loop thread). Iroh accept/serve/flush
  and redeem dial (`Loop.dialLocator` → `DialResolver.resolve` / `startDial` by node id) share that
  bridge, proven by `zig build iroh-bridge-redeem`. The Zig resident also keeps a
  blocking single-connection shape for `BlockingSession`; the public C ABI is
  loop-only. `bench-peer-scaling`'s `served` row
  measures the per-connection core state of a loop-hosted, vat-carrying
  connection and extrapolates it straight-line to ~1.1 GiB at 500k connections,
an in-process projection. Opt-in Phase 2 (`zig build bench-peer-scaling -- --live`)
measures TCP loopback under `completion.Loop` + `driver.Bridge` at stepped N
(RSS, connect success, ns/turn); smoke mode skips that live leg. The
public iroh netlayer C ABI is loop-only: a single readiness fd
(`pancake_iroh_netlayer_readiness_fd`) plus a non-blocking
`pancake_iroh_netlayer_drain_ready`, armed at construction, and it reaches
every binding, not only Zig: each parks on that fd natively, Deno (`IrohLoop`
over a `node:net` socket), Python (`_IrohLoop` over asyncio `add_reader`),
  Rust (an `AsyncFd` task), and Racket (`unsafe-file-descriptor->semaphore`).
  Python, Rust, and Racket are each proven by a many-connection gate under
  `bindings-iroh-loop`; Deno implements the same loop surface but is not part of
  that aggregate step. The vision
  holds every binding to the same scale bar, not a tier of "small consumers"
  ([boundaries](boundaries.md)). All four residents (`tcp`, `keyed-tcp`,
  `inproc`, iroh) dial and host through the
  same `connectVia` / `acceptVia` path with the same verified handshake, and
  adding each one edited no driver, core, or contract file. A caller's own
  transport slots in the same way. Stream transports expose a `*std.Io.Reader`
  and `*std.Io.Writer`; `net.pumpOver` drives a peer over that pair. A
  non-stream transport can instead drive the peer directly through
  `Peer.recvStreamPrefix` and `takeOutbound`, the same API a language binding
  uses over the C ABI (ADR-0030).
- **OCapN locator URIs.** `model.uri` parses and emits the out-of-band bootstrap
  form (`ocapn://<designator>.<transport>?hints` for a peer,
  `ocapn://<designator>.<transport>/s/<swiss-num>` for a sturdyref) against
  owned `model.PeerLocator` / `model.SturdyRef`. The transport is the suffix
  after the last `.`, hints are RFC 3986 query parameters, percent-encoding is
  `%XX`-only so a base64 designator round-trips byte-for-byte, and the
  conformance peer's own URI parses back to its parts. This is the format any
  netlayer address is shared in. The same grammar is core C ABI vocabulary:
  `pancake_uri_parse_peer` / `pancake_uri_parse_sturdyref` and the matching
  `pancake_uri_format_*` convert a URI to and from one opaque `PancakeLocator`
  read through the `pancake_locator_*` accessors, so every binding parses and
  formats through one definition instead of a hand-rolled percent codec.
  Natively, `driver.connect` dials a `model.PeerLocator` through the netlayer
  slice the caller passes (tcp and the in-process `inproc` resident ship with
  pancake; the iroh resident lives in the sidecar, so a host that links it
  registers it beside them), failing closed when no registered resident hosts
  the transport, and signs with an explicit `Identity` (`.ephemeral` or
  `.keyed`), never a defaulted key; `driver.connectUriOwned` parses a published
  `ocapn://` URI string into a locator and dials it the same way. A literal
  address becomes a typed locator through the transport that owns its spelling
  (`net.tcp.at(designator)` for a `host:port` string), so a caller holding a
  literal address need not hand-write the `PeerLocator`. Hosting is the symmetric twin: `driver.listen`
  binds any `net.netlayer.Netlayer` per a `ListenConfig`, signs each accepted
  session with the same explicit `Identity`, and hands back an owning
  `driver.Server` (whose `localDesignator` reports the bound address to dial)
  and whose `accept` returns a `driver.Session`, so a host serves over
  whatever transport it binds, never a privileged built-in. The bindings dial
  through one `connect(locator)` that takes an `ocapn://` URI string. There is
  no `host:port` dial; `tcp_locator(host, port)` builds a `tcp` locator for a
  literal address (ADR-0062). Locator grammar helpers (`socket_addr_designator`
  and siblings) own host:port/IPv6 bracketing; binding dials mint through
  `open_dialed_locator` / `dial_parsed_locator` after `parse_locator`, and
  `TRANSPORT_*` vocabulary is meta-gated per binding. Over the optional iroh ABI companion library each
  also exposes `listen_iroh` for hosting, and an iroh partner is dialed through
  the same `connect` on an `ocapn://<nodeid>.iroh?direct-addresses=…` locator.
  An iroh dial takes an explicit, no-default reachability (the `Reachability`
  enum / `IROH-REACH-*` constants), so the relay/discovery posture is a visible
  choice at every call, never a hidden default, proven cross-language by
  `zig build iroh-interop` (deterministic) and exercised by the illustrative
  `zig build demo-rooms-iroh`.
- **Live Goblins interop, both directions.** `zig build goblins-interop` proves
  a real Spritely Goblins v0.18.0 conversation each way. As a client, pancake
  spawns a Goblins vat, dials it over `net.tcp`, completes the keyed
  `op:start-session` handshake while verifying Goblins' own Ed25519 signature,
  bootstrap-fetches Goblins' echo capability, and calls it to a fulfilled
  resolution (ADR-0035). As a listener, pancake binds a TCP listener and
  publishes a vat actor behind a swiss number; a real Goblins client dials in,
  enlivens the actor, and calls it, and the actor's turn resolves the answer
  Goblins reads back (ADR-0035). It needs `racket` plus the `goblins` collection
  on PATH, so it runs as a sibling of the hermetic `check`, not inside it. Every
  binding reaches the same live conversation over the C ABI:
  `zig build deno-goblins-interop`, `python-goblins-interop`,
  `rust-goblins-interop`, and `racket-goblins-interop` each drive their binding
  through the keyed handshake with a real Goblins vat, then bootstrap-fetch its
  echo cap and call it. The keyed exchange runs from every binding, not only
  from native Zig.
- **Wall-clock performance tripwire.** `zig build perf-check` (a member of
  `check`) runs the hot-path benches in ReleaseFast and holds the ladder rung 2
  ceilings: warm inbound dispatch, answered outbound send, and the
  `op:gc-answers` release-storm growth ratio (ADR-0073).
- **Keyed TCP designator.** `net.tcp_keyed` (`keyed-tcp`, ADR-0075) binds the
  listener's Ed25519 key as the locator designator with the socket address in
  `direct-addresses`, verified fail-closed by `engine.Peer.expectPartnerKey`
  (the same pin iroh inherits). Gated by `test/driver/keyed_tcp_restart_test.zig`.
  Binding-level dial/host surfaces (`listen_keyed_tcp` / `keyed_tcp_locator` /
  `connect` on a `keyed-tcp` URI) and per-binding restart gates
  (`zig build bindings-keyed-tcp-restart`) are shipped. The C ABI partner-key
  pin is `pancake_peer_expect_partner_key`; `pancake_host_session_open_accepted`
  carries the direct-addresses hint for a keyed accept. The byte-fed host pins
  iroh dials the same way (`designatorSchemeForTransport("iroh")` → `.key`);
  every binding's `listen_iroh` shares one seed between the endpoint and the
  `Host`, proven hermetically in `test/driver/core_host_test.zig`.
- **Architecture gate.** The layer DAG is compiler-enforced: each `src/` layer
  is an internal build.zig module with a one-way import table (ADR-0040), and
  each sibling wire codec is its own module below the codec layer (ADR-0048), so
  a cross-layer or cross-codec reach fails to compile. The DAG is one
  declaration (`layer_table` in build.zig) that generates every build graph;
  `zig build arch-check` verifies the same table against the tree (a granted
  edge no file imports fails, an unclaimed source file fails) and holds the
  content bans a module graph cannot express: no `std.Io` or threading in the
  core, and no platform syscall namespaces in portable code.
- **Meta scaffolding gate.** `zig build meta-check` verifies canonical `.agents`
  guidance, thin Cursor/Claude overlays, hook and Serena MCP wiring, ignored
  generated state, documented build-step names, and the doc-drift living-state
  registry.
- **Rust C ABI dogfood.** A Rust crate links the pancake archives through the C
  ABI and drives a peer smoke test through the public host boundary.
