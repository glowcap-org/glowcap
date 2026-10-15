---
type: living
description: The known limits that can change a deployment or API choice.
sources: []
---

# Known limitations

[What ships](shipped.md) is the feature inventory, [stability](stability.md)
says how each part is tested, and the [roadmap](roadmap.md) lists future
work.

## Transports and peer identity

- **Plain `tcp` is a testing transport.** Its designator is an address, so the
  peer claims no identity and proves none, and the channel is cleartext. Use
  `tcp` to reach a peer that speaks nothing else, not to deploy.
- **`keyed-tcp` and `keyed-relay` are cleartext and unauthenticated.** Their key
  designator is a stable dial target, but the channel proves no possession of
  it. Anyone on the path reads and can alter every frame. On `keyed-relay` that
  includes the relay operator even when the carrier leg itself uses WSS. A
  fresh session key limits reconnects but does not stop a captured hello
  from being replayed. Prefer `noise-tcp` or `noise-relay` between glowcap
  peers, iroh when you need discovery or NAT traversal, and WebRTC for a direct
  browser channel. An application with its own authenticated channel records the
  proof through `glowcap_host_session_bind_verified_channel_key`.
- **A TCP locator names a socket.** On plain TCP, the crossed-connection
  tiebreak trusts the location each peer declares. A peer that can connect and
  claim an address you are dialing can make your outgoing session lose that
  tiebreak. Only a channel-authenticated key designator can collapse a session.
- **Two sessions to one peer stay open on an address transport.** `127.0.0.1`
  and `[::1]` are different designators, and neither is an identity glowcap
  acts on. A key-designator transport with channel proof recognizes the peer
  by its durable name and keeps one session.
- **A proved peer is a computer, not a person.** A transport proves which
  key answered. Checking who a person is, and telling one person from many
  bots, belongs to the application
  ([What about identity?](https://jimisaacs.github.io/glowcap/identity/)).
- **`inproc` is a test transport.** Its unbounded pipes block the reading
  thread, so it is not a production or load-test substitute.
- **`onion` has no scale tests.** Live checks need `tor` and network access,
  so they run apart from `zig build check`. Zig `Session` and `Server` reach
  Tor at TCP addresses only. A Unix-socket SOCKS or control endpoint needs a
  binding, whose provider archive accepts socket paths.
- **Over onion, glowcap offers more than `1.0` only to a peer it knows is
  glowcap.** That means a peer that handed out the glowcap-hinted address, or
  one whose hello stated a preference. Pinned Goblins refuses a hinted onion
  locator, so every onion locator on the wire stays bare. Goblins sessions and
  hosts on the default profile use `1.0`
  ([ADR-0108](decisions/adr/ADR-0108-onion-netlayer.md),
  [ADR-0118](decisions/adr/ADR-0118-onion-profile-by-knowledge.md)).
- **CI does not test iroh hole-punching between separate NATs.** Opt-in checks
  cover discovery and relay use from one host. `discovery_no_relay` has no
  check because it needs a publishable direct address.
- **A `webrtc` dial needs configured signaling.** In a browser, TypeScript
  composes the runtime with `webrtc.connector(signaling)`. On a server, Rust,
  Python, Racket, and Deno compose it with `webrtc.provider(signaling)`, Zig
  gives the backend a `SignalingAuthority`, and the C library takes callbacks
  in `GlowcapWebrtcConfig.signaling`. Without it the dial refuses.
- **glowcap has no Zig QUIC or WebRTC stack.** iroh and WebRTC run through
  their own Rust libraries.
- **iroh notices a peer that died without closing only after an idle
  timeout.** A killed TCP peer sends a FIN at once. UDP has no equivalent. The
  default is in the `GlowcapIrohConfig` header. Set `idle_timeout_ms` on any
  binding when a live session means presence. A shorter timeout costs more
  idle traffic.

## Runtime and scale

- **TypeScript on Bun cannot host the driver loop.** Bun runs FFI
  calls on its JavaScript thread, so a listener could park it. Those APIs
  refuse before allocating. The synchronous Host, locators, and the byte-fed
  client still work. Use Deno for the full driver loop.
- **A Host's Vat is single-threaded and non-preemptive.** A behavior runs to
  the end of its turn, so a slow handler stalls every session on that Host.
  Keep handlers bounded. Separate Hosts isolate scheduling but also separate
  identity and actor graphs. To keep them shared, move blocking work out of
  the callback:
  - A Zig behavior defers its answer with a resolver vow
    ([ADR-0102](decisions/adr/ADR-0102-off-turn-settlement.md)) and settles it
    later through `Vat.fulfillVow` or `Vat.breakVow` on the owning thread.
  - A byte-fed C program uses `glowcap_host_turn_defer` and its settle verbs.
  - A TypeScript or Python behavior that returns a promise defers
    automatically. Rust and Racket expose the resolver pair.
  - A worker thread posts its result to `driver.SettleMailbox`, which wakes the
    owning thread. Only plain data crosses threads, never a capability.
- **`driver.HostRuntime` does not report which Linux backend it selected.** A
  completion loop reports io_uring or epoll, with the reason, through
  `net.tcpBackendStatus`.
- **`libglowcap_driver` has a readiness descriptor only on Linux and Darwin.**
  Elsewhere `glowcap_driver_readiness_fd` returns a typed failure, and the
  stepping verbs still work.
- **Connections that are opening are capped.** `max_pending_opens` (default
  `GLOWCAP_DRIVER_DEFAULT_MAX_PENDING_OPENS`) caps them per driver Host,
  across dials, accepts, external adoption, and redeems. A stream accept over
  the limit waits in the kernel backlog. A multiplexed accept over the limit
  is closed without a session.
- **A driver loop allows one listener per transport.** Closing the
  selected listener leaves no acceptable route until you select another. The
  relay package dials both `keyed-relay` and `noise-relay` but hosts only one
  at a time, because the rendezvous protocol queues inbound legs by designator
  alone. Providers that cannot host refuse listener start.
- **Callers can choose an infinite wait.** Zig requires a handshake and settle
  budget, and `.unbounded` is allowed.
- **A durable sturdyref survives a restart only if you keep its entropy.** The
  library keeps no registry across processes. A durable name depends only on
  the <!-- value ../src/ocapn/session/references/bootstrap.zig durable_swiss_entropy_len -->16<!-- /value --> entropy bytes you pass to `publishDurable`. Republish with the same
  bytes at startup and old sturdyrefs reach the new actor. Lose them and the
  name is gone.
- **Some binding pumps copy outbound frames.** TypeScript, Python, and Racket
  copy bytes before an asynchronous write, and Rust retains the frame.
- **Only Zig can register a new codec.** The C ABI and the bindings select the
  built-in Syrup and Cap'n Proto codecs.
- **macOS runs the Zig suite, and Windows is not implemented.** `zig build check`
  and the external-runtime matrix are Linux-only.

## API gaps

### Loam storage

[Loam](loam.md) stores records and runs sleepy actors (actors that leave memory between calls).
It has no recursive room or directory resources.

- **Disk format.** LMDB stores need the LMDB 1.x format, and SQLite stores carry
  the row format version they were written with. A store from an older
  prerelease needs a fresh directory.
- **What is not durable.** Pending messages are not durable, and a lost reply
  does not mean the change was aborted. Behaviors perform no outside effects.
- **Collection.** Tracing needs spare storage for its queue and marks, and a
  full work list (`max_collection_roots`) can refuse a new retention. A
  retired name keeps its index reservation after its descriptor is collected.
- **Locking and growth.** Each disk engine holds an advisory `flock` lock. LMDB
  grows its file-size limit and SQLite its page limit only within an explicit
  budget.
- **Uncertain disk commits.** When a commit fails without saying whether it
  landed, as a full disk can, the store refuses other work until
  [recovery](loam/store.md#when-a-writes-outcome-is-unknown) finds out.
- **Engine memory.** LMDB and SQLite each keep a page cache outside the
  Store's memory limits. [LMDB operations](loam/lmdb.md#read-failures) says
  what LMDB's costs.
- **Testing.** [Stability](stability.md) says which platforms and failures the
  crash tests cover.
- **Capacity.** The Store and hosting defaults size a small program. An
  application declares its own record, call and live-capability limits from
  the shape of its data. One process owns a store at a time, and one commit
  changes at most `ChangeBatchRecord.max_effects` resources of one owner, so
  a bulk load is many commits.
- **Measurement.** Open-loop arrival rates, maximum throughput, real transport
  latency, a cold OS page cache, and browser transaction latency are not
  measured.
- **C, Rust, and IndexedDB.** These cover creating, sharing, editing, and
  reopening a fixed resource, strong saved-reference fields, and bounded
  collection steps. General graph editing and the operations reserved for a
  resource's owner are Zig-only. C and Rust receipt handles do
  not persist themselves. The application owns durable effect receipts and
  restart recovery.

### Managed access

The [managed access guide](loam/access.md) gives the full memory and lifetime
contract.

- **No distributed transaction.** A remote publication's lifetime belongs to
  its remote owner.
- **Receipts.** Derivation and other mutations each keep a fixed window of
  retry receipts per endpoint (`access.records.RetryWindow.capacity`). An
  expired receipt fails rather than issuing again. Receipt codecs accept only
  durable capabilities from the same attachment.
- **Authorization does not carry over.** An evaluation result cannot authorize
  a later effect.
- **Fixed capacity.** The graph and grant ledger reserve their full capacity in
  memory and cannot grow or be restored. A fresh store needs fresh identities.
  A revoked record keeps its capacity until the ledger is destroyed. The
  stored profile never reuses committed resource or grant slots.
- **History.** An owner keeps a fixed window of committed change batches
  (`access.records.ChangeHistoryRecord.capacity`, each up to
  `ChangeBatchRecord.max_effects` effects). Observation resynchronizes when
  visible changes expired.
- **Policy schema.** Boolean permissions, lower or upper bounds, and kind
  declarations are capped by the `max_*` constants on `access.core.Policy`.
  Applications declare every fact an effect needs. Fact relations,
  alternatives, projections, and remote dependencies are not implemented.
- **Access descriptions.** `describe-access` returns a snapshot. It delivers no
  events and lists no controls.
- **Live fields.** An explicit live field holds a capability for one hosting
  lifetime. After a restart it refuses.
- **Reads and closing.** A Store read expires after any commit and refuses
  during an unknown outcome. Close refuses while reads are submitted or
  references are live. Under a tight cache, release finished operations before
  starting new work. A descriptor survives final C release only when a
  root or containing edge retains it.
- **Cost.** A permanent name keeps a fixed index reservation
  ([cleanup](loam/access.md#bounded-owner-cleanup) gives its size). Directory
  traversal takes up to four page reads plus the target.
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
  exits with refused C releases pending, their callbacks and Rust owners
  stay allocated for the process lifetime. Finish close and recovery before
  the thread exits.
- **Enlivening a sturdyref refuses an accepted plain-TCP session.** Only the
  `assertion_only` opt-in proceeds, and it reports the peer as asserted
  rather than proved. Enlivening does not prove that a sturdyref names some
  capability you already hold.

Archive discovery and packaging are in the
[packaging guide](../bindings/PACKAGING.md#finding-the-archives). Windows release
assets are not published.

## Protocol and interop

- **A locator holds at most <!-- value ../src/ocapn/model/hints.zig max_count -->32<!-- /value --> hint entries.** This is glowcap's resource
  bound, not an OCapN maximum. Unknown names within it are kept and ignored.
- **OCapN Null is absent.** Unknown Syrup records stay tagged values
  ([watch](upstream-watch.md#ocapn-null)).
- **Only the negotiated features are accepted.** glowcap supports
  `pipelining`, `handoff`, `wire_delta`, `sturdyref`, `untag`, and
  `multi_location`. An `id` locator is refused unless the session negotiated
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

- **A browser opens no listening socket.** Cold dial reaches it through a
  relay that holds an inbound socket under the browser's key, or over WebRTC,
  where the browser answers offers its signaling carries. Raw `keyed-relay`
  leaves frames cleartext and proves nothing. `noise-relay` seals the stream
  end to end, and WebRTC encrypts its channel and relies on the application's
  signaling to say who the peer is.
- **No check uses a public certificate.** Zig and binding WSS relay checks run against a
  local certificate authority, so no check proves a non-browser peer reaching a
  browser through a deployed secure route.
- **Rooms uses STUN only by default.** Symmetric NATs and strict firewalls need
  a configured TURN credential issuer, or those peers may find no route. Zig
  WebRTC programs own their own TURN credential refresh.
- **A standalone Rooms session reaches a browser through a relay or over
  WebRTC, and each is configured.** Pass `--relay-url` (or
  `GLOWCAP_ROOMS_SESSION_RELAY_URL`) for members that chose the relay, and
  `--dial-transports=webrtc` for members that advertise WebRTC, which also
  lets those members open a WebRTC connection to the session. WebRTC
  gathers through `--ice-servers`, STUN only unless the list carries TURN
  credentials, so a session behind a symmetric NAT may find no route.
  Deployments and `rooms-dev` configure the relay.
- **A session's inbox is bounded** ([operating Rooms](../apps/rooms/operating.md)
  has the limits). Pressure retires the observer, not the session, and
  reports a gap you must accept before observing again. An agent harness needs
  a live consumer to wake its model.
- **A DM sender hosts its own files until the recipient pulls them.** It keeps
  a bounded number of files and bytes across direct conversations. The oldest
  idle source expires first. If the session ends or a file expires first, the
  recipient keeps the message but not the bytes.

[Rooms admission](rooms/admission.md) covers per-process limits and proxy
grouping.
