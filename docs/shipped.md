# What ships today

This page is the inventory of implemented behavior — the specific claims, each
held by a gate, a scenario, or a live interop run. It moves with the code: a
claim here that stops matching the tree is drift, and the
[boundaries page](boundaries.md) is its complement, naming where the
implemented surface ends. For how the pieces fit together, read the
[architecture](architecture.md); for where this is all going, the
[vision](vision.md).

Implemented Zig behavior includes:

- **Frames.** `Frame` has one visible owner, `FrameView` borrows bytes, and
  `FrameShape` carries explicit byte vs word-aligned frame metadata.
- **Model.** Codec-neutral CapTP model types exist independently of the wire
  encoding that carried them.
- **Syrup.** The Syrup codec encodes the current message model against
  pancake-authored Syrup byte vectors (cross-checked through the upstream Syrup
  encoders, not Goblins captures), decodes borrowed views for the supported
  operation set, and materializes owned messages for engine-surfaced operations
  including start-session and handoff.
- **Session/engine.** Sessions own profile/features, lifecycle,
  import/export/answer/release authority, validate-then-apply, and feature
  gates. `Peer` remains caller-owned and drives outbound profile-aware encoding,
  V1.0 resolve-me-desc synthesis, borrowed inbound dispatch, owned queued
  inbound frames, outbound drains, and application-visible events for the
  supported decoded operations.
- **Third-party handoff.** Give and receive work end to end, and the Syrup codec
  round-trips the handoff fixtures. The vat-scoped `engine.bootstrap.GiftRegistry`
  is the single gift authority: deposit and withdraw bookkeeping, recipient
  match, and handoff-count replay rejection (ADR-0056). Withdrawals are
  authorized under Ed25519 — each certificate is verified against the key it
  must be signed by, so a give signed by any other key is refused — and
  `engine.handoff_gifter.buildSignedGive` ships the gifter's side of the same
  signing (ADR-0009). The host that holds the peers routes the flow from gifter
  to exporter to recipient; the in-repo harness for that routing lives in
  `test/support/cross_peer.zig`.
- **Promise pipelining.** Sessions own the inbound-answer table, listeners, and
  stored resolutions; `engine.pipeline` carries the pure transforms. A pipelined
  `op:deliver` against an unresolved answer queues and drains to the resolution
  (local delivery, requeue, or far-forward) when `op:resolve` settles. A
  multi-hop call path decomposes at the sender into chained single-hop frames,
  so every `desc:answer` on the Syrup wire stays flat.
- **Relayed-resolution forwarding.** An `op:listen` on a handoff-imported promise
  installs against the third-party-hosted import; when the introducing session
  forwards the host's resolution, `engine.cross_peer.drainRelayedResolutions`
  fires the listeners and stores the resolution so a late listener fires
  immediately (ADR-0009).
- **Bootstrap fetch (initiator).** `engine.fetch` builds the canonical
  bootstrap-fetch `op:deliver`. It matches either kind of partner settlement, an
  `op:resolve` or a resolver-callback `op:deliver`, into an owned outcome. The
  adapter drives the wire loop between those two halves; the core stays no-I/O.
- **Bootstrap fetch (responder).** `Peer.registerBootstrapCap(swissnum)` exposes
  a local capability behind a swiss number; an inbound `'fetch` to the bootstrap
  export is then recognized and answered automatically by the dispatcher
  (`engine.bootstrap` synthesizes the `Resolve`; the V1.0 path renders it as a
  resolver-callback), with `break "unknown swissnum"` for an unregistered
  swiss number (ADR-0006 responder half).
- **Sturdyref enliven (initiator).** `engine.sturdyref` turns a persistent
  `(peer, swissnum)` sturdyref into a live `Reference` over the existing
  bootstrap-fetch: a feature-negotiated + open precondition gate, a session dedup
  cache that maps a swiss number to its `(import_position, kind)` (the kind is
  preserved) and short-circuits a repeat enliven with no wire traffic, and an
  in-flight marker that collapses a concurrent enliven onto the outstanding
  answer. The wire loop is adapter-driven, exactly like `engine.fetch`.
- **Distributed equality.** `model.referencesEqual` is the codec-neutral
  structural-equality predicate — the in-memory evidence for OCapN Pass Invariant
  Equality (ADR-0012): two references that name the same target compare equal
  regardless of which codec or profile carried them. `engine.SessionRegistry`
  enforces one session per `PeerId` (`PeerAlreadyOpen` on a duplicate open), so
  cross-session equality reduces to same-session equality on
  `(import_position, kind)`; the sturdyref dedup cache supplies the
  sturdyref-vs-handoff collapse.
- **Handshake profile and feature negotiation.** `engine.negotiation.negotiate`
  is the pure, symmetric pick of the most-preferred shared profile and codec,
  plus the intersected `model.FeatureSet`, over two `Offer`s. `op:start-session`
  carries the selected profile version but no feature operand (pancake does not
  add fields to OCapN's wire shapes), so both ends compute the same answer from
  the same offers. Goblins interop is the target policy for authenticated
  `v1_0` over Syrup; pancake-to-pancake negotiation can choose `v1_0` or
  PreSpec, and Syrup or Cap'n Proto where supported.
- **Fail-loud aborts.** When an inbound frame is rejected, either because the
  codec cannot decode it or because the session state machine refuses it, the
  error is projected through `engine.abort_projection`. The peer sends a typed
  outbound `op:abort` before the error reaches the caller, and closes the session
  when the protocol requires it. Both inbound entry points use the same
  projection, so a partner is not left waiting on a bare host error.
- **Resource caps.** `SessionLimits` bounds the partner-driven tables — imports,
  the seen-handoff-count replay set, and deposited gifts — alongside the existing
  pipelining caps; each overflow is a loud `*CapExceeded` error that projects to
  a `ResourceExhausted` abort (ADR-0025), never a silent drop.
- **C ABI and adapters.** The C ABI frame vocabulary is fixed-width and
  release-explicit: borrowed frames dispatch synchronously, managed frames
  transfer ownership without copying, and events return the originating frame
  in the negotiated codec with explicit release and no re-encode. `std.Io`
  appears at the adapter boundary, not in the core. Allocation policy is a
  `PancakeContext`: the `*_in` constructors allocate a whole handle family
  through a context you supply and free it back through the same context
  (ADR-0031). The authenticated `op:start-session` handshake is the C ABI
  default — `pancake_peer_new` opens a negotiating authenticated v1.0 peer and
  `pancake_peer_start_session` signs the canonical location bytes from a
  caller-supplied 32-byte seed (the library never generates entropy) — so a
  binding reaches an open session with a real Goblins vat without
  re-implementing the crypto. Already-open peers exist only behind explicit
  `*_raw_open` fixture constructors for tests that inject frames directly.
  [`consuming-from-c.md`](consuming-from-c.md) is the consumer's route in.
- **Protocol oracle bridge.** `zig build oracle-check` enumerates shipped
  message arms, checks pancake-authored Syrup fixture parity across the upstream
  Syrup encoders, and runs engine scenarios
  including the multi-peer third-party handoff. `conformance` also drives a
  deliver-then-resolve round-trip, a handshake that auto-serves a bootstrap fetch
  (the ADR-0006 responder half), and a cross-mode parity check that proves the
  borrowed (`recvBorrowed`) and owned (`feedInbound` + `step`) inbound entry
  points run one dispatcher (byte-identical observable output).
- **Actors.** `actors.Vat` is a Goblins-shaped layer above the engine. You spawn
  local objects, call them synchronously with `$`, and eventual-send to them with
  `<-` to get a `Promise` back. An object "becomes" by mutating its own state.
  When a vat is bound to a peer, the same `<-` works for local and far
  references. A local target runs a turn in the vat. A far target goes out as an
  `op:deliver` over the peer. `publish` and `serve` host a local object at an
  export, so a partner's inbound deliver runs the object's turn and resolves the
  answer. The layer is synchronous and owns no I/O (ADR-0036). Every binding
  mirrors the same local or far reference model in its own idiom. Racket stays
  Goblins-faithful; Rust, Python, and Deno use native language shapes. Each
  binding proves a far-send round-trip in its dogfood (ADR-0039).
- **One application surface, every binding.** Each binding exposes the same
  small surface in its own idiom — the nine verbs the
  [bindings contract](../bindings/README.md) enumerates. Every binding hosts as
  well as dials, and `connect` / `listen` complete the keyed, mutually verified
  `op:start-session` handshake before they return — an established OCapN
  session, not a pre-opened test shortcut, with the per-connection seed drawn
  at the I/O boundary because the sans-io core never generates entropy. A
  returned `Ref` marshals as a capability argument, so application code never
  manages export positions, flushes frames, or hand-writes a receive loop. In
  native Zig the same surface is one owning `driver.Connection` (`connect`,
  `listen`/`accept`, blocking `call`, `step`, `serve`), sized by one
  `frame_cap` option; when the connection closes, the driver breaks every
  pending `send` so an outstanding call settles broken instead of hanging, and
  the raw `Peer` and `Vat` stay reachable through `conn.peer` and
  `conn.cv.vat` for handoff, pipelining, and session control. The Deno, Python,
  and Rust `Connection`s break pending sends the same way when their serve
  loop ends.
- **Three real cross-language applications.** The
  [example applications](../examples/README.md) — rooms, tasks, and tools —
  each run a server and one client per language over one OCapN wire and assert
  the result. Every connection is a keyed-handshake-established session: the
  client `connect` and the server's accept both complete the
  `op:start-session` exchange. That the same `connect` / `fetch` / `send`
  surface is OCapN-conformant is proven against a real Goblins vat, not just
  between pancake peers: `zig build deno-goblins-interop`,
  `python-goblins-interop`, `rust-goblins-interop`, and
  `racket-goblins-interop` each drive their binding's application surface
  through the keyed handshake, fetch, and call against live Goblins. The demos
  need only `deno`; other-language participants join when their runtimes are
  present, and all run as siblings of the hermetic `check`.
- **Accountability application on pancake.** `zig build accountability` runs the
  first real application on pancake's own runtime: KERI-anchored identity, a
  signed Episode per capability invocation, a Merkle transparency log, and a
  host that refuses to account for a caller it cannot verify — the refusal path
  the Syrup codec's exhaustive `.error` argument arm makes representable on the
  wire. Two native pancake peers complete an OCapN handshake over a real
  loopback TCP socket, and every invocation produces a verifiable Episode
  attributing the verified caller. The same Affordance is reachable from Deno
  and Python callers over the C ABI (`libpancake.so`,
  `zig build demo-accountability`): same application, three languages, each on
  a keyed-handshake-established OCapN session — the host completes the
  responder half and the foreign callers `connect` through the keyed
  `op:start-session` exchange, the same handshake the application surface and a
  live Goblins peer use. A three-party handoff test
  (`zig build accountability-three-party`) proves that after A introduces B to
  C, C attributes B (the true caller), not A. Identity, Episodes, and the
  transparency log stay entirely above pancake. See
  [`conformance/accountability-on-pancake/`](../conformance/accountability-on-pancake/).
- **Pluggable codecs.** Codecs resolve through an open comptime registry keyed by
  a non-exhaustive `model.CodecId`. The built-ins are `syrup` and `capnp`. A Zig
  consumer adds another codec by declaring `pub const pancake_codecs` in the root
  source file. Dispatch still unrolls at comptime, so the open registry keeps the
  same direct calls as the built-in set (ADR-0026).
- **Pluggable transports.** A netlayer is a runtime contract the driver dispatches
  against, not a privileged built-in (ADR-0043). A `net_adapter.Netlayer` dials a
  locator to a `Connection` and binds a listener. `driver.connectVia` and
  `acceptVia` resolve the locator's transport symbol against a
  `net_adapter.NetlayerRegistry`. A transport the core never names can plug in by
  registering itself, with no driver or core edit.

  The contract has three real residents, which is what proves it is
  transport-general rather than socket-shaped. `net_adapter.tcp` is the socket
  transport. `net_adapter.inproc`
  ([ADR-0047](decisions/adr/ADR-0047-in-memory-netlayer.md)) is a second,
  genuinely different one: an in-process switchboard that wires a dialer and a
  listener through two in-process byte pipes, with no sockets and no file
  descriptors, for full in-process OCapN conversations in tests and mocks.
  `net_adapter.iroh` (ADR-0055) is the third and the encrypted one: each
  connection is one bidirectional QUIC stream from a real iroh endpoint, dialed
  by Ed25519 endpoint id, carried by the `transports/iroh` Rust sidecar
  staticlib so it stays outside `libpancake`; it links into the `iroh-interop`
  gate and into `libpancake_iroh`, the separate optional public C ABI
  superset that carries iroh to the bindings (ADR-0055 2026-06-12 amendment).
  The `iroh-interop` gate now proves the cluster's three capstones live: the
  netlayer takes a configurable, no-default `Reachability`
  (`direct`/`discovery`/`discovery_no_relay`/`local_discovery`) and **dials by
  node id alone** through an address book (no direct-address hints); **one
  Ed25519 key** per peer is at once the iroh node id, the OCapN locator
  designator, and the session signing key, verified on both handshake halves
  (`driver.connectViaWithSecret` / `acceptViaWithSecret`); and a **sturdyref**
  (node id plus swiss-number) **outlives an endpoint restart**. Serving iroh at
  pancake's ~500k-connection scale is the event-driven completion-loop bridge of
  ADR-0057 (designed, not built); today's concurrency is thread-per-connection.
  All three residents dial and host through the same `connectVia` /
  `acceptVia` path with the same verified handshake, and adding each one edited
  no driver, core, or contract file — a caller's own transport slots in the
  same way. Stream transports expose a `*std.Io.Reader` and `*std.Io.Writer`;
  `net_adapter.pumpOver` drives a peer over that pair. A non-stream transport
  can instead drive the peer directly through `Peer.recvStreamPrefix` and
  `takeOutbound`, the same API a language binding uses over the C ABI
  (ADR-0030).
- **OCapN locator URIs.** `model.uri` parses and emits the out-of-band bootstrap
  form — `ocapn://<designator>.<transport>?hints` for a peer,
  `ocapn://<designator>.<transport>/s/<swiss-num>` for a sturdyref — against
  owned `model.PeerLocator` / `model.SturdyRef`. The transport is the suffix
  after the last `.`, hints are RFC 3986 query parameters, percent-encoding is
  `%XX`-only so a base64 designator round-trips byte-for-byte, and the
  conformance peer's own URI parses back to its parts. This is the format any
  netlayer address is shared in. The same grammar is core C ABI vocabulary:
  `pancake_uri_parse_peer` / `pancake_uri_parse_sturdyref` and the matching
  `pancake_uri_format_*` convert a URI to and from one opaque `PancakeLocator`
  read through the `pancake_locator_*` accessors, so every binding parses and
  formats through one definition instead of a hand-rolled percent codec.
  Natively, `driver.connectUri` turns such a URI into a live connection in one
  call: it parses the URI and dials it through the netlayer registry the caller
  passes (tcp and the in-process `inproc` resident ship in `libpancake`; the
  iroh resident lives in the sidecar, so a host that links it registers it
  beside them), failing closed when no registered resident hosts the transport.
  The bindings' TCP `connect`/`listen` take a host and port; over the optional
  iroh ABI superset each also exposes `connect_iroh` / `connect_iroh_uri` /
  `listen_iroh`, which dial and bind an `ocapn://<nodeid>.iroh?direct-addresses=…`
  URI. Each takes an explicit, no-default reachability (the `Reachability` enum /
  `IROH-REACH-*` constants), so the relay/discovery posture is a visible choice
  at every call, never a hidden default — proven cross-language by
  `zig build iroh-interop` (deterministic) and exercised by the illustrative
  `zig build demo-rooms-iroh`.
- **Live Goblins interop, both directions.** `zig build goblins-interop` proves a
  real Spritely Goblins v0.18.0 conversation each way. As a client, pancake
  spawns a Goblins vat, dials it over `net_adapter.tcp`, completes the keyed
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
- **Architecture gate.** The layer DAG is compiler-enforced: each `src/` layer
  is an internal build.zig module with a one-way import table (ADR-0040), and
  each sibling wire codec is its own module below the codec layer (ADR-0048),
  so a cross-layer or cross-codec reach fails to compile. The DAG is one
  declaration (`layer_table` in build.zig) that generates every build graph;
  `zig build arch-check` verifies the same table against the tree — a granted
  edge no file imports fails, an unclaimed source file fails — and holds the
  content bans a module graph cannot express: no `std.Io` or threading in the
  core, and no platform syscall namespaces in portable code.
- **Meta scaffolding gate.** `zig build meta-check` verifies canonical `.agents`
  guidance, thin Cursor/Claude overlays, hook and Serena MCP wiring, ignored
  generated state, documented build-step names, and the doc-drift living-state
  registry.
- **Rust C ABI dogfood.** A Rust crate links `libpancake` through the C ABI and
  drives a peer smoke test through the public host boundary.
