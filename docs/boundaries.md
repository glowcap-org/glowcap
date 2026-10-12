# Known limitations

These are the limits that can change a deployment or API choice. [What ships](shipped.md)
is the feature inventory. [Stability](stability.md) says how each surface is
tested. The [roadmap](roadmap.md) lists future work.

## Transports and peer identity

- **Plain `tcp` is a testing transport.** Its designator is an address, so the
  peer claims no identity and proves none, and the channel is cleartext. Use
  `tcp` to reach a peer that speaks nothing else, not to deploy.
- **`keyed-tcp` and `keyed-relay` are cleartext and unauthenticated.** Their key
  designator is a stable dial target, but the channel proves no possession of
  it. Anyone on the path reads and can alter every frame. On `keyed-relay` that
  includes the relay operator even when the carrier leg itself uses WSS. A
  fresh session key limits honest reconnects but does not stop a captured hello
  from being replayed. Prefer `noise-tcp` or `noise-relay` between glowcap
  peers, iroh when you need discovery or NAT traversal, and WebRTC for a direct
  browser channel. An embedder with its own authenticated channel records the
  proof through `glowcap_host_session_bind_verified_channel_key`.
- **A TCP locator names a socket.** On plain TCP, the crossed-connection
  tiebreak trusts the location each peer declares. A peer that can connect and
  claim an address you are dialing can make your outgoing session lose that
  tiebreak. Only a channel-authenticated key designator can collapse a session.
- **Two sessions to one peer stay open on an address transport.** `127.0.0.1`
  and `[::1]` are different designators, and neither is an identity glowcap
  acts on. A key-designator transport with channel proof recognizes the peer
  by its durable name and keeps one session.
- **`inproc` is a test transport.** Its unbounded pipes block the reading
  thread, so it is not a production or load-test substitute.
- **`onion` has no scale evidence.** Live checks need `tor` and network access,
  so they run apart from `zig build check`. Native Zig `Session` and `Server`
  reach Tor at TCP addresses only. A Unix-socket SOCKS or control endpoint
  needs a binding or the blocking resident.
- **Over onion, glowcap offers more than `1.0` only to a peer it knows is
  glowcap.** That means a peer that handed out the glowcap-hinted address, or
  one whose hello stated a preference. Pinned Goblins refuses a hinted onion
  locator, so every onion locator on the wire stays bare. Goblins sessions and
  hosts on the default profile settle `1.0`
  ([ADR-0108](decisions/adr/ADR-0108-onion-netlayer.md),
  [ADR-0118](decisions/adr/ADR-0118-onion-profile-by-knowledge.md)).
- **CI does not test iroh hole-punching between separate NATs.** Opt-in checks
  cover discovery and relay use from one host. `discovery_no_relay` has no
  check because it needs a publishable direct address.
- **A `webrtc` dial needs configured signaling.** On TypeScript, compose the
  runtime with `webrtc.connector(signaling)`. Native Zig sets it on the WebRTC
  backend. Without it the dial refuses.
- **glowcap has no Zig QUIC or WebRTC stack.** iroh and WebRTC run through
  their own Rust libraries.
- **iroh notices a peer that died without closing only after an idle
  timeout.** A killed TCP peer sends a FIN at once. UDP has no equivalent. The
  default is fifteen seconds. Set `GlowcapIrohConfig.idle_timeout_ms` on any
  binding when a live session means presence (Rooms uses eight). A shorter
  timeout costs more idle traffic, charged against the per-connection budget in
  the [ladder](ladder.md).

## Runtime and scale

- **TypeScript on Bun cannot host the native driver loop.** Bun runs native
  calls on its JavaScript thread, so a listener could park it. Those APIs
  refuse before allocating. The synchronous Host, locators, and the byte-fed
  client still work. Use Deno for the full native loop.
- **A Host's Vat is single-threaded and non-preemptive.** A behavior runs to
  the end of its turn, so a slow handler stalls every session on that Host.
  Keep handlers bounded. Separate Hosts isolate scheduling but also separate
  identity and actor graphs. To keep them shared, move blocking work out of
  the callback:
  - A Zig behavior defers its answer with a resolver vow
    ([ADR-0102](decisions/adr/ADR-0102-off-turn-settlement.md)) and settles it
    later through `Vat.fulfillVow` or `Vat.breakVow` on the owning thread.
  - A byte-fed C embedder uses `glowcap_host_turn_defer` and its settle verbs.
  - A TypeScript or Python behavior that returns a promise defers
    automatically. Rust and Racket expose the resolver pair.
  - A worker thread posts its result to `driver.SettleMailbox`, which wakes the
    owning thread. Only plain data crosses threads, never a capability.
- **`BlockingSession` serves one connection on one fiber.** Use `Session` or
  `Server` for a partner that streams while waiting for you to drain output.
- **`driver.HostRuntime` does not report which Linux backend it selected.** A
  completion loop reports io_uring or epoll, with the reason, through
  `net.tcpBackendStatus`.
- **`libglowcap_driver` has a readiness descriptor only on Linux and Darwin.**
  Elsewhere `glowcap_driver_readiness_fd` returns a typed failure, and the
  stepping verbs still work.
- **Connections still opening are capped.** `max_pending_opens` defaults to 256
  per driver Host, across dials, accepts, external adoption, and redeems. A
  stream accept over the limit waits in the kernel backlog. A multiplexed
  accept over the limit is closed without a session.
- **A driver loop allows one listener per provider profile.** Closing the
  selected listener leaves no acceptable route until you select another. The
  relay package dials both `keyed-relay` and `noise-relay` but hosts only one
  at a time, because the rendezvous protocol queues inbound legs by designator
  alone. Providers that cannot host refuse listener start.
- **Callers can still choose an infinite wait.** Zig requires an explicit
  handshake and settle budget, but `.unbounded` is allowed.
- **A durable sturdyref survives a restart only if you keep its entropy.** The
  library keeps no registry across processes. A durable name depends only on
  the 16 entropy bytes you pass to `publishDurable`. Republish with the same
  bytes at startup and old sturdyrefs reach the new actor. Lose them and the
  name is gone. `Host.Options.bootstrap_durability` refuses
  `.durable_bootstrap`.
- **Some binding pumps copy outbound frames.** TypeScript, Python, and Racket
  copy bytes before an asynchronous write. Rust retains the frame.
- **Only Zig can register a new codec.** The C ABI and the bindings select the
  built-in Syrup and Cap'n Proto codecs.
- **macOS runs the native suite, and Windows is not implemented.** `zig build check`
  and the external-runtime matrix are Linux-only.

## API gaps

### Loam storage

[Loam](loam.md) stores records and runs sleepy actors. Recursive room and
directory resources are not built yet ([Rooms plan](planning/rooms.md)).

- **Disk format.** LMDB stores need the LMDB 1.x format. A store from an older
  prerelease needs a fresh directory.
- **What is not durable.** Pending messages are not durable, and a lost reply
  does not mean the change was aborted. Behaviors perform no outside effects.
- **Collection.** Tracing needs spare storage for its queue and marks, and a
  full journal can refuse new custody. A retired name keeps its index
  reservation after its descriptor is collected.
- **Locking and growth.** LMDB holds an advisory `flock` lock and grows its
  memory map only within an explicit budget.
- **Testing.** Crash and copy-space tests run on Linux. macOS runs are still
  required. Nothing tests hardware power loss.
- **Measurement.** Open-loop arrival rates, maximum throughput, and real
  transport latency are not measured.
- **C, Rust, and IndexedDB.** These cover the fixed-resource lifecycle and
  strong saved-reference fields. General graph editing, collection cursors,
  and privileged owner lifecycle are Zig-only. C and Rust receipt handles do
  not persist themselves. The application owns durable effect receipts and
  restart recovery.

### Managed access

The [managed access guide](loam/access.md) gives the full memory and lifetime
contract.

- **No distributed transaction.** A remote publication's lifetime belongs to
  its remote owner.
- **Receipts.** Derivation keeps eight retry receipts per source endpoint, and
  other mutations share a separate window of eight. An expired receipt fails
  rather than issuing again. Receipt codecs accept only durable capabilities
  from the same attachment.
- **Authorization does not carry over.** An evaluation result cannot authorize
  a later effect.
- **Fixed capacity.** The graph and grant ledger reserve their full capacity in
  memory and cannot grow or be restored. A fresh store needs fresh identities.
  A revoked record keeps its capacity until the ledger is destroyed. The
  stored profile never reuses committed resource or grant slots.
- **History.** An owner keeps 32 committed change batches of up to 16 effects
  each. Observation resynchronizes explicitly when visible changes expired.
- **Policy schema.** At most 64 Boolean permissions, 16 lower or upper bounds,
  and 16 kind declarations. Applications declare every fact an effect needs.
  Fact relations, alternatives, projections, and remote dependencies are not
  implemented.
- **Access descriptions.** `describe-access` returns a snapshot. It delivers no
  events and lists no controls.
- **Live fields.** An explicit live field holds a capability for one hosting
  lifetime. After a restart it refuses.
- **Reads and closing.** A Store read expires after any commit and refuses
  during an unknown outcome. Close refuses while reads are submitted or
  references are live. Under a tight cache, release finished operations before
  admitting new work. A descriptor survives final native release only when a
  root or containing edge retains it.
- **Cost.** A permanent name reservation costs 58 logical bytes before backend
  overhead. Directory traversal takes up to four page reads plus the target.
  Each cache slot reserves the configured maximum record size. Selected scopes
  copy on issuance and editing, and reparenting costs one ancestry walk and two
  subtree traversals. No managed-owner throughput or 500k-scale figure exists.

### Rooms

Limits that belong to the Rooms application, rather than to the library, are
listed in [operating Rooms](../apps/rooms/operating.md#known-limitations).

### Host and ABI

- **The public API and ABI are not stable.** There are no release tags or
  compatibility guarantees. Pin a commit.
- **Rust finalizer recovery belongs to the owning thread.** If that thread
  exits with refused native releases pending, their callbacks and Rust owners
  stay allocated for the process lifetime. Finish close and recovery before
  the thread exits.
- **Enlivening a sturdyref refuses an accepted plain-TCP session.** Only the
  native `assertion_only` opt-in proceeds, and it reports the peer as asserted
  rather than proved. Enlivening does not prove that a sturdyref names some
  capability you already hold.

Archive discovery and packaging are in the
[packaging guide](../bindings/PACKAGING.md#finding-the-archives). Windows release
assets are not published.

## Protocol and interop

- **A locator holds at most 32 hint entries.** This is glowcap's resource
  bound, not an OCapN maximum. Unknown names within it are kept and ignored.
- **OCapN Null is absent.** Unknown Syrup records stay tagged values
  ([watch](upstream-watch.md#ocapn-null)).
- **Only the negotiated features are accepted.** glowcap supports
  `pipelining`, `handoff`, `wire_delta`, `sturdyref`, `untag`, and
  `multi_location`. An `id` locator is refused unless the session settled
  `glowcap-next` with `multi_location`, and a Host-level `id` sturdyref needs
  the Host to opt in too.
- **Only the Node chooses among a route bundle's routes**
  ([multi-home peers](https://jimisaacs.github.io/glowcap/multihome/),
  ADR-0125). The single-path dial planner and Host open refuse a bundle as a
  physical session. A give keeps its route list only when both sessions
  negotiated it. Otherwise it falls back to the exporter's claimed location.
  New route advice reaches later gives only after one withdrawal succeeds.
- **Handoff signatures always use Syrup**, even on a Cap'n Proto session.
- **Pinned Goblins can reject handoffs from independent receivers.** Goblins
  keeps the `handoff-count` on the wrong session, so a second receiver starting
  at zero is refused. glowcap keeps reconnects safe inside one Node but cannot
  coordinate separate receivers
  ([upstream watch](upstream-watch.md#handoff-count-across-independent-receiver-sessions)).
- **Remote equality does not cross unrelated sessions.** Without durable peer
  proof, two sessions' targets stay unrelated even when their locators look
  alike.
- **Cap'n Proto is glowcap-to-glowcap only.** `zig build bench-codec` measures
  it against Syrup on the current workload.

[Community review](community-review.md) records outside-peer coverage and
specification gaps.

## Browser reachability

- **A browser cannot listen.** Cold dial reaches it through a relay that holds
  an inbound socket under the browser's key. Raw `keyed-relay` leaves frames
  cleartext and proves nothing. `noise-relay` seals the stream end to end, and
  WebRTC supplies encryption and signaling authority.
- **No check uses a public certificate.** Native WSS relay checks run against a
  local certificate authority, so nothing yet proves a native peer reaching a
  browser through a deployed secure route.
- **Rooms uses STUN only by default.** Symmetric NATs and strict firewalls need
  a configured TURN credential issuer, or those peers may find no route. Native
  WebRTC embeddings own their own TURN credential refresh.
- **A standalone Rooms session needs a relay URL** to dial browser DMs. Pass
  `--relay-url` or set `GLOWCAP_ROOMS_SESSION_RELAY_URL`. Deployments and
  `rooms-dev` configure it.
- **A session's inbox holds 4096 unacknowledged events within 16 MiB.**
  Pressure retires the observer, not the session, and reports a gap you must
  accept before observing again. An agent harness needs a live consumer to wake
  its model.
- **A DM sender hosts its own files until the recipient pulls them.** It keeps
  at most eight files per message, 128 live sources, and 64 MiB across direct
  conversations. The oldest idle source expires first. If the session ends or
  a file expires first, the recipient keeps the message but not the bytes.

[Rooms admission](rooms/admission.md) covers per-process limits and proxy
grouping.
