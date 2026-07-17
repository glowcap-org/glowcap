# What ships today

Inventory of implemented behavior, held by a check, scenario, or live interop
run. Complement: [boundaries](boundaries.md). Fit: [architecture](architecture.md).
Destination: [vision](vision.md).

## Frames

- **Frame ownership.** A `Frame` has one visible owner, `FrameView` borrows
  bytes, and `FrameShape` carries byte- versus word-aligned metadata
  explicitly.
- **Codec-neutral model.** CapTP message types exist independently of the wire
  encoding that carried them.
- **Distributed equality.** `model.referencesEqual` is the codec-neutral
  structural-equality predicate for OCapN Pass Invariant Equality
  ([ADR-0012](decisions/adr/ADR-0012-sturdyref-shape-and-enliven.md)):
  same-session equality is on `(import_position, kind)`; the sturdyref dedup
  cache collapses sturdyref versus handoff. Session-pair uniqueness is Host
  enrollment posture, not CapTP wire law: a second dial to a live partner
  session or keyed dial to a verified partner key refuses
  `HostError.SessionPairExists` (`test/driver/core_host_test.zig`). An accepted
  tcp session's declared designator does not squat dial availability.
  Crossed-hello races beside a dial are edged in [boundaries](boundaries.md).

## Codecs

- **Syrup.** Encodes the message model against pancake-authored byte vectors
  cross-checked with upstream Syrup encoders (`zig build oracle-check`). Decodes
  borrowed views for supported operations and materializes owned messages where
  the engine needs them (start-session, handoff). Locator hints ride
  `view.BorrowedHints` (`.empty` / `.projected` / `.lazy`; Cap'n Proto and
  Syrup share the lazy arm). Encoding is measure-then-fill: one exact-sized
  allocation and zero reallocs, pinned by `test/codec/encode_budget_test.zig`.
- **Cap'n Proto.** Hand-rolled codec is engine-integrated and selectable on a
  live session
  ([ADR-0026](decisions/adr/ADR-0026-hand-rolled-capnp-codec.md)). Golden frames
  under `test/codec/capnp_fixtures/` lock encode bytes and decode acceptance
  (`zig build gen-capnp-fixtures`; `test/codec/capnp_golden_test.zig`). This is
  a pancake-to-pancake codec, not a Goblins parity claim.
- **Pluggable codecs.** Codecs resolve through an open comptime registry keyed
  by non-exhaustive `model.CodecId`; built-ins are `syrup` and `capnp`. A Zig
  consumer adds another by declaring `pub const pancake_codecs` in its root;
  the open registry costs nothing over the built-in set (ADR-0026).

## Session

- **Session and engine.** Sessions own profile and feature negotiation,
  lifecycle, import/export/answer/release authority, validate-then-apply, and
  feature gates. The caller-owned `Peer` drives outbound profile-aware encoding,
  V1.0 resolve-me-desc synthesis, borrowed inbound dispatch, owned queued
  inbound frames, outbound drains, and application-visible events.
- **Promise pipelining.** Sessions own the inbound-answer table, listeners, and
  stored resolutions; `engine.pipeline` carries the pure transforms. A pipelined
  `op:deliver` against an unresolved answer queues and drains once
  `op:resolve` settles. Multi-hop calls decompose into chained single-hop
  frames so every `desc:answer` on the wire stays flat. The questioner side
  ships across driver `send` / `sendToAnswer` / `settleVow`, the C session's
  non-blocking send, and a vow-as-send-target in every binding
  ([ADR-0065](decisions/adr/ADR-0065-questioner-side-promise-pipelining.md)).
  TCP disables Nagle so a batched send is not held for delayed ACK;
  `bench-langs` runs the taskboard script pipelined.
- **Field, index, and tag projections.** A caller pipelines `op:get`,
  `op:index`, or `op:untag` against a pending answer before it settles
  ([ADR-0050](decisions/adr/ADR-0050-get-index-responder.md),
  [ADR-0052](decisions/adr/ADR-0052-untag-responder.md)). Evidence:
  `test/engine/projection_test.zig`, `abort_projection_test.zig`. Bindings
  expose `index` / `untag` / `get` over `pancake_host_vow_*`.
- **Relayed-resolution forwarding.** When a Host answer fulfills with a foreign
  promise token, `Node.proxyForeignPromiseFulfill` (from
  `Host.interceptFulfilled`) preserves `RefKind`, arms home `op:listen`, mints
  a third-party import-promise, and relays settlement once via
  `Peer.applyRelayedResolution`
  ([ADR-0009](decisions/adr/ADR-0009-three-party-handoff-substrate.md)).
  Hermetic evidence: `test/engine/node_test.zig`,
  `test/engine/relay_resolution_test.zig`. Object foreign fulfills remain
  gift-redeem (`goblins-handoff` / `goblins-gift`). Foreign promise as
  send/tell args is a permanent refuse (`ForeignArgument`;
  [boundaries](boundaries.md)).
- **Bootstrap fetch.** `engine.fetch` builds the canonical bootstrap-fetch
  `op:deliver` and matches either partner settlement kind into one owned
  outcome; the adapter drives the wire loop while the core stays no-I/O.
  `Peer.registerBootstrapCap(swissnum)` exposes a local capability; inbound
  `'fetch` is answered automatically, with `break "unknown swissnum"` for an
  unregistered one
  ([ADR-0006](decisions/adr/ADR-0006-handshake-substrate-and-bootstrap-fetch.md)).
- **Sturdyref enliven.** `engine.sturdyref` turns a persistent
  `(peer, swissnum)` into a live `Reference` over bootstrap-fetch, with a
  session dedup cache and in-flight collapse. The
  `pancake_peer_prepare_enliven` / `pancake_peer_record_enlivenment` C ABI seam
  exposes the cache; every binding ships `enliven()`. Native
  `zig build goblins-interop` and each `*-goblins-interop` step prove enliven
  plus dedup against a live Goblins-published cap.
- **Distributed GC, opt-in.** The engine sends and accounts `op:gc-exports` /
  `op:gc-answers`. Every binding can drive a release from a dropped handle
  behind an opt-in, off by default
  ([ADR-0063](decisions/adr/ADR-0063-finalizer-driven-distributed-gc.md));
  scope is `fetch` results only. `test/engine/gc_churn_test.zig` proves flat
  import-row reclamation; each binding check watches the release frame. Live
  Goblins proof covers inbound `op:gc-exports` only (`zig build goblins-gc`).
  Outbound release, `op:gc-answers`, and binding finalizer GC are covered
  in-tree and by ADR-0063, not that live step.
- **Handshake and feature negotiation.** `engine.negotiation.negotiate` is the
  pure, symmetric pick of CapTP version, codec, and intersected
  `model.FeatureSet` (`pipelining`, `handoff`, `wire_delta`, `sturdyref`) over
  two `Offer`s. `Offer.goblins()` and `Offer.native()` are the two real jobs.
  `op:start-session` carries only the selected captp-version string, so both
  ends must already share offers. Goblins interop targets authenticated
  `"1.0"` / Syrup; native pancake-to-pancake prefers `"pancake-next"` / Cap'n
  Proto via `Offer.native()`, with Syrup / `"1.0"` as fallback. Host
  `connect` / `listen` stay on Goblins `"1.0"`.
- **Fail-loud aborts.** A rejected inbound frame projects through
  `engine.abort_projection`: the peer commits a typed outbound `op:abort`
  before the error reaches the caller and closes the CapTP session when
  required
  ([ADR-0083](decisions/adr/ADR-0083-outbound-abort-closes-session.md)). Both
  inbound entry points share the same commit path as `pancake_peer_send_abort`.
- **Resource caps.** `SessionLimits` bounds partner-driven tables alongside
  pipelining caps; overflow is a loud `*CapExceeded` that projects to
  `ResourceExhausted`, never a silent drop
  ([ADR-0025](decisions/adr/ADR-0025-session-table-cap-policy.md)). The Cap'n
  Proto decoder adds a per-frame traversal budget. Hostile-bytes coverage runs
  in `test/codec/`.

## Handoff

- **Handoff basics.** Give and receive work end to end; Syrup round-trips the
  handoff fixtures. Vat-scoped `engine.bootstrap.GiftRegistry` is the single
  gift authority
  ([ADR-0056](decisions/adr/ADR-0056-vat-scoped-gift-registry.md)).
  Withdrawals are Ed25519-authorized;
  `engine.handoff_gifter.buildSignedGive` ships the gifter side (ADR-0009).
  Routing harness: `test/support/cross_peer.zig`.
- **Crossed hellos.** When two peers dial each other at once, the pair keeps
  the session the higher-keyed peer opened
  ([ADR-0030](decisions/adr/ADR-0030-netlayer-connection-and-memory-posture.md)):
  `driver_core.Host` owns the tiebreak registry; `BlockingSession` and
  `driver.Bridge` answer from that same table. A deterministic driver scenario
  pins the verdict to the byte order of the two public identifiers.
- **Transparent handoff.** Redeem and originate go through Host /
  `connect` / `fetch` / `send` with no application choreography, native Zig and
  every binding
  ([ADR-0072](decisions/adr/ADR-0072-driver-tier-over-c-abi.md),
  [ADR-0076](decisions/adr/ADR-0076-loop-fed-host-bridge.md)). Evidence:
  `goblins-handoff`, `goblins-gift`, `bindings-*-handoff` / `*-gift`,
  `deno-gifter-handoff`, `demo-rooms-dm`, plus iroh Direct and Discovery
  (`demo-rooms-dm-iroh`, `demo-rooms-dm-iroh-discovery`,
  `bindings-iroh-handoff`, `bindings-iroh-redeem-posture`,
  `bindings-iroh-reachability`). Mechanics: [architecture](architecture.md).

## Actors

- **Actors.** `actors.Vat` is a Goblins-shaped layer above the engine: spawn,
  synchronous `near` (`$`), eventual-send `<-` returning a `Vow`, and
  become-by-mutation. Bound to a peer, the same `<-` reaches local or far
  references. `bindExport` and `serve` host a local object at an export. The
  layer is synchronous and owns no I/O
  ([ADR-0036](decisions/adr/ADR-0036-actor-layer.md)). Opt-in local time-travel
  (`snapshot` / `restore`, copy-on-write, functional `become` over
  `PersistentMap`) never touches session state
  ([ADR-0060](decisions/adr/ADR-0060-vat-local-time-travel.md),
  [ADR-0061](decisions/adr/ADR-0061-persistent-collections-module.md)).
  Every binding mirrors the local-or-far model and proves a far-send round trip
  in its binding check
  ([ADR-0039](decisions/adr/ADR-0039-binding-actor-idioms.md)).
- **Object-capability proxies.** `Turn.forward` defers an answer onto an
  eventual-send to another reference
  ([ADR-0064](decisions/adr/ADR-0064-answer-forwarding-and-ocap-proxies.md)).
  `actors.caretaker` and `actors.attenuate` wrap any `Ref`, near or far.
  Evidence: `test/actors/ocap_test.zig`. Every binding ships the same
  primitives; each binding check exercises revoke and attenuate over a far
  reference plus a local near-call against local and far targets.

## Netlayers

- **Pluggable transports.** A netlayer is a runtime contract the driver
  dispatches against, not a privileged built-in
  ([ADR-0043](decisions/adr/ADR-0043-netlayer-contract.md)).
  `net.netlayer.Netlayer` dials a locator to a `Connection` and binds a
  listener; `driver.connectVia` / `acceptVia` resolve the locator's transport
  symbol against a caller-owned slice. Four residents prove the contract:
  `net.tcp`, `net.tcp_keyed`
  ([ADR-0075](decisions/adr/ADR-0075-keyed-tcp-designator.md)), `net.inproc`
  ([ADR-0047](decisions/adr/ADR-0047-in-memory-netlayer.md)), and the `iroh`
  sidecar ([ADR-0055](decisions/adr/ADR-0055-iroh-netlayer-sidecar.md)).
- **iroh.** `zig build iroh-interop` proves configurable `Reachability`
  (`direct` / `discovery` / `discovery_no_relay` / `local_discovery`) that
  dials by node id alone; opt-in `iroh-reachability` and
  `bindings-iroh-reachability` prove dial-by-id over the public internet. One
  Ed25519 key is at once the iroh node id, the OCapN locator designator, and
  the session signing key. Binding `listen_iroh` mints that one seed for the
  endpoint and the `Host` (`driver.core.vocab`; ADR-0075). A sturdyref
  outlives an endpoint restart. `zig build iroh-mesh` proves three-party
  handoff by gifted node id.
- **Scale loops.** iroh's event-driven completion loop
  ([ADR-0057](decisions/adr/ADR-0057-iroh-completion-loop-bridge.md)) feeds
  the same `driver.Bridge` + `driver_core.Host` spine as TCP (ADR-0076) and
  serves many QUIC connections from one loop thread (`zig build iroh-loop`).
  TCP scale is `net.TcpLoop` + Bridge + Host (`zig build tcp-loop`;
  `test/driver/bridge_test.zig`). `zig build iroh-bridge-redeem` proves iroh
  accept, serve, flush, and redeem dial. `bench-peer-scaling`'s `served` row
  extrapolates per-connection core state; five hundred thousand remains a
  budget until a printed `--live`, `tcp-loop`, or `iroh-loop` run updates
  [ladder](ladder.md) with measured figures. The public iroh netlayer C ABI is
  loop-only (`pancake_iroh_netlayer_readiness_fd` +
  `pancake_iroh_netlayer_drain_ready`); every binding parks on it
  (`bindings-iroh-loop`). Stream transports use `net.pumpOver`; non-stream
  transports drive the peer through `Peer.recvStreamPrefix` and
  `takeOutbound` (ADR-0030).
- **Keyed TCP designator.** `net.tcp_keyed` binds the listener's Ed25519 key as
  the locator designator with the socket address in `direct-addresses`,
  verified fail-closed by `engine.Peer.expectPartnerKey` (ADR-0075;
  `test/driver/keyed_tcp_restart_test.zig`). Binding surfaces
  (`listen_keyed_tcp` / `keyed_tcp_locator`) and
  `zig build bindings-keyed-tcp-restart` ship. C ABI:
  `pancake_peer_expect_partner_key`; `pancake_host_session_open_accepted`
  carries the direct-addresses hint. The byte-fed host pins iroh dials the
  same way (`test/driver/core_host_test.zig`).
- **OCapN locator URIs.** `model.uri` parses and emits
  `ocapn://<designator>.<transport>?hints` and `.../s/<swiss-num>` against
  owned `model.PeerLocator` / `model.SturdyRef`. Core C ABI:
  `pancake_uri_parse_*` / `pancake_uri_format_*` through one opaque
  `PancakeLocator`. `model.uri.splitHostPort` is the single `host:port` split;
  `pancake_designator_host_port` / `pancake_locator_host_port` hand the same
  verdict to a consumer with its own sockets. `driver.connect` /
  `driver.connectUriOwned` / `driver.listen` dial and host through the
  caller-owned netlayer slice with an explicit `Identity`
  ([ADR-0062](decisions/adr/ADR-0062-one-connect-over-a-netlayer-slice.md)).
  Bindings dial through one `connect(locator)` on an `ocapn://` URI.
  Cross-language iroh: `zig build iroh-interop`, `zig build demo-rooms-iroh`.

## C ABI

- **C ABI and adapters.** Fixed-width, release-explicit frame vocabulary:
  borrowed frames dispatch synchronously, managed frames transfer ownership
  without copying, and events return the originating frame with explicit
  release. Bindings resolve à-la-carte archives through a publishable cascade
  ([ADR-0077](decisions/adr/ADR-0077-publishable-c-abi-resolve.md)); hygiene
  refusals hard-fail (`zig build c-abi-extract-check`).
  `pancake_peer_next_event` drives the engine to idle and returns the next
  fully projected event. CapTP `PANCAKE_EVENT_*` kinds pair with peer send
  constructors except `PANCAKE_EVENT_LISTEN` (engine-synthesized; held by
  `zig build meta-check`). `std.Io` appears at the adapter boundary, never the
  core. Allocation policy is a `PancakeContext`
  ([ADR-0031](decisions/adr/ADR-0031-c-abi-allocation-context.md)).
  `pancake_peer_new` opens a negotiating authenticated v1.0 peer;
  `pancake_peer_start_session` signs from a caller-supplied seed. Archives
  link à la carte: `libpancake_ocapn`, `libpancake_net`, one per transport, and
  `libpancake_driver` over `driver_core.Host`
  ([ADR-0059](decisions/adr/ADR-0059-composable-c-abi-archives.md), ADR-0072).
  `pancake_host_new` / `_new_in` take a `local_turn_budget` (ADR-0076). Every
  binding rides this one shared archive (ADR-0072) with a named `pump` module
  (conn bytes), named `action` (host-action decode/execute), named `promise`
  (`RemotePromise` / session-vow, projections, fetch/enliven, far-send
  factories `promiseFor` / `sendFar`), named `gc` (ADR-0063), named `dial`,
  named `listen` (`Server` / keyed-tcp host). The embedder-spine module split is complete,
  including a named trampoline per binding (wire callback, Forward chase,
  send/tell, ADR-0064 caretaker/attenuate, spawn/publish,
  `registerActor` / `_register_actor` / `register-hosted-actor!`; Rust keeps
  spawn/publish on `SessionShared`) plus Rust's named `session_shared`
  (`Ref` / `Caretaker` / `SessionShared`). Zig `embedder_pump` and opt-in
  `pancake_host_pump_drain` drain the action queue through
  `pancake_host_next_action`; `PANCAKE_MAX_LOCAL_FORWARD_HOPS` pins the
  trampoline Forward-chase bound. Handshake completes before `connect` /
  `listen` return. `examples/c/host_embedder_pump.c` is the choreography
  checklist. `libpancake_net_transport_tcp` also ships owning
  `PancakeTcpSession` (`test/c_abi/tcp_session_test.zig`). Consumer route:
  [consuming-from-c](consuming-from-c.md).
- **One application surface, every binding.** Each binding exposes the same
  small surface in its own idiom
  ([bindings contract](../bindings/README.md)). Every binding hosts as well as
  dials; `connect` / `listen` complete the keyed, mutually verified
  `op:start-session` handshake before returning. A returned `Ref` marshals as
  a capability argument. Native Zig surface is owning `driver.Session`; when a
  connection closes, pending `send`s settle broken. Deno, Python, and Rust
  `Session`s break pending sends the same way when their serve loop ends.
- **Rust C ABI binding check.** A Rust crate links the pancake archives through
  the C ABI and drives a peer smoke test through the public host boundary.

## Apps/CLI

- **Cross-language applications.** The
  [example applications](../examples/README.md): rooms, tasks, and tools,
  each run a server and one client per language over one OCapN wire and assert
  the result (pancake-to-pancake; need only `deno`; other languages join when
  present). Live Goblins proof for the binding surface is separate and
  client-direction only: `zig build deno-goblins-interop`,
  `python-goblins-interop`, `rust-goblins-interop`, and
  `racket-goblins-interop` (keyed handshake, `enliven` + dedup, echo
  deliver/resolve, not demo apps, not binding listen/hosting, and not the
  native projection / break legs that `goblins-interop` owns). All run as
  siblings of in-tree `check`.
- **Accountability.** `zig build accountability` runs KERI-anchored identity,
  a signed Episode per capability invocation, a Merkle transparency log, and a
  host that refuses an unverified caller, over real loopback TCP. Deno and
  Python callers reach the same Affordance over the C ABI
  (`zig build demo-accountability`). `zig build accountability-three-party`
  proves that after A introduces B to C, C attributes B, not A. Application
  code stays entirely above pancake:
  [`examples/apps/accountability-on-pancake/`](../examples/apps/accountability-on-pancake/).
- **Installable CapTP CLI.** `zig build` installs `pancake` from `cli/`
  ([ADR-0084](decisions/adr/ADR-0084-pancake-cli-product-boundary.md)).
  Recipes: [cli](cli.md). Everyday `ocapn`, CapTP lab `repl`, curated stdio
  `mcp`, and `app rooms-peer`. Demo actors: `greeter`, `echo`. Unbuilt product
  work lives in [roadmap](roadmap.md) and [boundaries](boundaries.md).

## Interop

- **Live Goblins interop, both directions.** `zig build goblins-interop` proves
  a real Spritely Goblins conversation each way
  ([ADR-0035](decisions/adr/ADR-0035-live-goblins-interop.md)). As client:
  keyed `op:start-session`, bootstrap-fetch echo, pipelined `op:index` /
  `op:get`, and enliven with ADR-0012 dedup (repeat hits cache, no second
  wire). As listener: swiss-hosted vat actor, settled call,
  reverse-pipelined enliven-and-call, and unknown-swiss break. In-tree, live
  object-export `op:listen` fires fulfill immediately; unresolved
  promise-export listen installs on the export-keyed store and fires on settle
  ([ADR-0007](decisions/adr/ADR-0007-promise-pipelining-substrate.md)).
  `zig build goblins-gc` proves inbound `op:gc-exports` after echo consumes a
  near export. Binding `*-goblins-interop` steps prove the client direction
  only over the C ABI.
- **Protocol reference bridge.** `zig build oracle-check` enumerates shipped
  message arms, checks pancake-authored Syrup fixture parity against upstream
  Syrup encoders, and runs engine scenarios including multi-peer third-party
  handoff, deliver-then-resolve, handshake auto-serve of bootstrap fetch, and
  borrowed-versus-owned inbound entry-point parity.
- **Wall-clock performance tripwire.** `zig build perf-check` (member of
  `check`) holds ladder step 2 ceilings for warm inbound dispatch, answered
  outbound send, and the `op:gc-answers` release-storm growth ratio
  ([ADR-0073](decisions/adr/ADR-0073-wall-clock-tripwire-gate.md)).
- **Architecture check.** Each `src/` layer is an internal build.zig module
  with a one-way import table
  ([ADR-0040](decisions/adr/ADR-0040-layer-modules-as-import-law.md)); sibling
  wire codecs are their own modules below the codec layer
  ([ADR-0048](decisions/adr/ADR-0048-codec-sibling-isolation.md)).
  `zig build arch-check` verifies `layer_table` against the tree and holds
  content bans a module graph cannot express (no `std.Io` or threading in the
  core; no platform syscall namespaces in portable code).
- **Repository hygiene check.** `zig build meta-check` verifies documented
  build-step names, overlay wiring, ignored generated state, and the registry
  of docs that must match today's code.
