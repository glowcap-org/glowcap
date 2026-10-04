# What ships today

glowcap has no release yet, but everything on this page is implemented and checked in this repository. It speaks
signed CapTP 1.0 over Syrup to outside implementations. The regular checks against
[Spritely Goblins](https://spritely.institute/goblins/) use the cleartext `tcp` testing adapter.

Read [known limitations](boundaries.md) before deploying, and [stability](stability.md) for the evidence behind each
claim. If capabilities are new to you, [capabilities](capabilities.md) starts from zero.

## Application APIs

| Surface      | What it provides                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       |
| ------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Zig          | `driver.Session` connects or listens, fetches and publishes capabilities, calls them, and redeems three-party introductions. `driver.HostRuntime` owns the sessions behind that API.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| I/O-free Zig | `engine.Peer` exposes the protocol engine without sockets or scheduling. Callers feed frames, step the engine, drain output, and handle events.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        |
| C            | Opaque handles, fixed-width result codes, explicit release, and separate archives for the core, Host, native loop, and transports. See [the C ABI](#the-c-abi) below. |
| Bindings     | Rust, TypeScript, Python, and Racket expose the same session and actor model through the C ABI. They can dial, listen, host objects, call far objects, and pass capabilities.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| Browser      | `@glowcap/web` runs a full peer in WebAssembly. A browser can host objects, answer calls, redeem handoffs over WebSocket, register for sealed `noise-relay` cold-dials, and hold an ordinary keyed session over WebRTC after signaling.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                |

The [Zig examples](../examples/README.md), [C guide](consuming-from-c.md), and [binding contract](../bindings/README.md)
are the entry points for those surfaces.

### The C ABI

- **Closing.** A close takes a policy for pending work (`GlowcapCloseOptions`).
- **Frames.** Managed frames carry their ownership inline, with no descriptor allocation and no byte copy.
- **Version checks.** Every archive exposes a fingerprint computed from its functions, public constants, and canonical
  layout manifests. Manifest rows that bindings project also generate the language mirrors; C-only rows stay out of
  package APIs. Generated binding loaders compare each fingerprint before use, so a stale companion library is refused.
- **Diagnostics.** A structured diagnostic report is validated for stable result codes and shape before it is stored.
  A fallible blocking transport call can return its worker thread's diagnostic in storage the caller owns. Every status
  call starts a fresh diagnostic, so a refusal without detail never inherits an earlier call's cause.

### How the bindings run

The bindings combine `libglowcap_host` and `libglowcap_driver`. The driver offers one generic ABI for dialing,
listening, and events, over a Host it has adopted.

- The TCP provider package handles `noise-tcp`, `keyed-tcp`, and the testing `tcp`. Transports built separately
  register through the same common ABI.
- The iroh provider handles both dialing and listening. Native Zig uses
  `iroh.MultiplexedAdapter` with `driver.connectProviders` and
  `driver.listenProviders`; C and native callers share the adapter state.
  `zig build iroh-managed` checks identity, fetch, call and session lifetime
  after Server destruction over real endpoints.
- The onion archive supplies the standard Tor transport, and the driver never needs to know its symbol. Zig and all four
  bindings host onion with the same Session listener lifecycle as other providers. Only the onion package reads the
  listener's opaque restoration bytes, which hold the Tor service key.
- An idle Host that is not yet pumping can move into this runtime in one step. On success it keeps its identity and
  capabilities. A refused move leaves the original Host untouched. If setup fails after a successful move, the adopted
  Host stays valid so you can retry.
- Closing a listener keeps the sessions it already handed out.
- Wasm and explicitly supplied byte channels use the byte-fed Host instead of the driver.

## Protocol

- **Sessions.** glowcap negotiates a signed CapTP session and owns its imports, exports, answers, and releases. It
  validates messages before applying them and sends a typed abort when a protocol error requires the session to close.
- **Calls and promises.** Applications can fetch a bootstrap capability, call it, and send without waiting. They can
  also pipeline through an unresolved answer: calls, and field, index, and tag projections.
  - glowcap always accepts the OCapN 1.0 `op:untag` operation. It sends one only when the partner's signed hello
    advertises the separate `untag` feature, so a Goblins peer that does not advertise it stays on the proven set.
  - A CapTP 1.0 call that names only a resolver still gets a typed local answer through the normal reply path, without
    inventing a wire position. Every `u64` stays available to the partner as an answer position, and wire GC cannot
    confuse the local entry with a wire one.
  - One-way sends use the draft's `op:deliver` with no answer. Neither the pinned draft nor Goblins has a separate
    `op:deliver-only` operation.
- **Persistent references.** A sturdyref is a durable peer locator plus a swiss number, and it can be enlivened into a
  live capability. Enlivening on a session checks the complete peer locator before any cache lookup or wire traffic,
  and repeated enlivening on that session shares one import. A mismatched peer, or an accepted plain-TCP assertion, is
  refused. Pending enlivenments reserve their combined, bounded cache space before sending their fetches. When they are
  fulfilled, their swiss numbers move into the cache without allocating, even when other inserts share that cache.
- **Route bundles.** Handoff fallback routes and the `via` routes of an `id` locator are parsed into one route bundle
  owned by the model layer. `id` is glowcap's one private multi-home form: its designator names the peer's durable key,
  and its strong routes must prove that key. [Multi-home peers](https://jimisaacs.github.io/glowcap/multihome/)
  explains the design, and [known limitations](boundaries.md#protocol-and-interop) lists the exact rules.
  - A give carries route vocabulary only when both the recipient's and the exporter's sessions negotiated it. For a
    baseline recipient, `id` is lowered to the first compatible route with the private vocabulary removed, or the give
    fails closed when no such route exists.
  - When redeeming, the Node dials an `id` only over routes that can prove the same durable key. It keeps two strong
    routes in flight in the declared `via` order, accepts the first proved completion, and cancels the other attempt.
  - `alt-locators` are weak fallbacks, tried one at a time after the strong routes are exhausted. They can redeem the
    signed gift that authorized the dial. They never establish the outer identity, enter its durable cache, or serve
    as a sturdyref's dial path.
  - Route advice is kept for later gives only after a withdrawal succeeds.
  - Host-level enlivening supports `id` sturdyrefs only when the Host opts into `glowcap-next` with `multi_location`.
    It reuses an already authenticated session for the same key, or stages the concrete routes through the
    pending-dial path. Host `fetchAt` does the same for a named publication, and the application never chooses a CapTP
    version or codec for it.
- **Distributed reclamation.** Native Zig and all four language bindings hold two handles to one Goblins
  object, release them independently, and observe Goblins reclaim it before closing the session.
  Keeping an export or call answer alive prevents that weak-reference proof from succeeding.

- **Three-party handoff.** A capability received from one peer can be returned or passed recursively to another. Inbound
  signed gives become Host-owned promises immediately. Outbound foreign objects and promises wait as one bounded
  transaction until every gift id, exporter deposit, shared promise listener, recipient escrow, and rewritten message
  can commit. Core and C Host cover terminal failure. Node-local routes use an explicit reference arm, so every `u64`
  remains available to a peer as a wire import and an unlowered route is structurally refused by codecs. The recurring
  Deno, Python, Rust, and Racket gifter matrix proves two nested gives against live Goblins.
  The recurring iroh handoff proof also puts Goblins in the gifter and exporter roles and verifies
  direct redemption after the exporter's advertised routing advice changes.

- **Relayed promise settlement.** When a shared home promise settles, its complete Passable value crosses Host identity
  once. Each recipient reuses the bounded Passable transaction. Nested objects become gives, and nested promises become
  successor proxies. A recipient that cannot admit its projection breaks without publishing a prefix. No sibling rolls
  back. The live Goblins evidence covers both directions. A Goblins recipient reads glowcap's relayed give. In the
  reciprocal scenario, an owning native Session installs `listenTo` on a Goblins-owned pending promise. Goblins then
  settles it to a list containing a callable capability.

- **Handoff capability ownership.** Deposited gifts keep the exact actor in the Host Vat
  ([ADR-0101](decisions/adr/ADR-0101-actor-roots-and-reclamation.md)). Zig and the bindings can also listen for
  settlement of a promise received from a peer. The native path is recurring live Goblins evidence, including recursive
  capability lifting and explicit release ([ADR-0095](decisions/adr/ADR-0095-listening-on-a-received-promise.md)). Gifts
  and replay counters live on the sessions that own them; product Hosts mint a fresh signing key per session
  ([ADR-0100](decisions/adr/ADR-0100-session-owned-handoff-authority.md),
  [ADR-0097](decisions/adr/ADR-0097-captp-session-identity-attestation.md),
  [ADR-0116](decisions/adr/ADR-0116-inline-passable-handoff.md)).
- **Identity.** A session can report the identity its handshake established. On `driver.Session`, the C ABI, Wasm, and
  the bindings, every application capability is one opaque Host-scoped identity
  ([ADR-0096](decisions/adr/ADR-0096-host-scoped-capability-identity.md)). Repeated lifts on one live exporter session
  converge on that identity, including a target reached directly and through three-party handoff. C compares the opaque
  ids. Rust, Python, and Racket use their native equality operations. TypeScript uses `Ref.equals` because each
  wrapper occurrence independently owns one native retain. Release state is not part of equality. Wire positions surface
  only on the low-level `engine.Peer` and `BlockingSession` tiers.
- **Publication.** Each session reaches the Host's shared Vat through its own Port. Publishing changes discovery only;
  issued capabilities and deposited gifts keep the exact actor until their roots release
  ([ADR-0101](decisions/adr/ADR-0101-actor-roots-and-reclamation.md)). Durable publication is a separate namespace
  ([ADR-0098](decisions/adr/ADR-0098-sturdyref-peer-authority.md)): the Host mints an unpredictable swiss number, never
  reassigns it, and returns the complete sturdyref. Host enlivenment selects a live matching session or dials the
  sturdyref peer itself. Zig Host also provides an allocator-owned enliven operation
  with a retained capability result and synchronous observation cancellation.
  Cached, connected, and parked paths share the same producer. Queued and transferred
  completions own their capability retains as well as their data; projection grants
  independent consumer retains and leaves a refused completion available for retry
  ([ADR-0177](decisions/adr/ADR-0177-owned-sturdyref-enlivenment.md)).
- **Locators.** Zig, C, and the bindings parse and format `ocapn://` peer and sturdyref URIs. Default Host and Session
  enlivenment consume the canonical persistent form; the explicitly named Host variant parses another profile's
  form. Typed Host `fetchAt` takes a locator plus publication name, so application code chooses neither a CapTP
  version nor a sturdyref codec. Applications dial through a locator rather than a transport-specific session API.
- **Resource limits.** Session tables, durable sent-answer resolution bytes, projection depth, nesting depth, and Cap'n
  Proto traversal are bounded. Durable answer retention is independent of transient outbound pressure, so neither ledger
  can deadlock the other. One partner's outbound pressure holds back only the Node actions bound for it. Those park on
  that session and re-enter the queue when its bytes are next taken, while actions for every other session proceed
  ([ADR-0145](decisions/adr/ADR-0145-node-actions-park-per-recipient.md)). The C Host and every binding expose both
  ledgers through one versioned, named session-limit
  options value; zero fields preserve the current Host policy, and already-minted peers keep their snapshot. Distributed
  garbage collection is available as a per-session opt-in in every binding: fetched capabilities, fulfilled far results,
  and recursively nested delivered arguments all return their opaque Host retain through one finalizer seam. A final
  import release also clears sturdyref cache state and makes every old host route fail closed before the partner may
  reuse that position. Binding-local dispatch and ABI projection both refuse a spent capability occurrence, even when
  another occurrence keeps the same Host identity live.
- **Unreturned failures.** The vendor-neutral diagnostics layer and `GlowcapContext` provide one typed, bounded journal
  for a failure whose last deterministic recipient has gone
  ([ADR-0115](decisions/adr/ADR-0115-structured-diagnostic-waist.md)). Recording allocates nothing, saturation preserves
  an explicit sequence gap, and the C claim API leaves a record queued when caller storage is too small. Contexts assign
  every native Host a stable nonzero lifecycle ID, so reports from Hosts sharing a journal remain distinguishable
  without treating reusable addresses as identity. Runtime-surviving binding records use the same aggregate text bound
  and truncation flags. Returned errors, peer aborts, and protocol trace remain separate authorities. Native driver
  events use the same primary/first-consequence/count vocabulary, so an asynchronous dial, listener, or wire-close
  recipient does not flatten its cleanup chain merely because it crosses C. Every native terminal event owns queue
  capacity before its transition commits: opens and listeners reserve at admission, wires at adoption, and completions
  while their Host action is still parked. Provider installation and final driver release return a versioned
  caller-owned record with the exact primary, first consequence, and total consequence count; every binding projects
  that record without parsing thread-local diagnostic text.
- **Close.** Every owning front closes under an explicit pending-work policy
  ([ADR-0114](decisions/adr/ADR-0114-pending-work-close-policy.md)). Cancel stops admitted work at once. Finish seals
  admission and drives already admitted work within a bounded grace. Expiry escalates to cancel. Each owner holds one
  close barrier. The policy ships on the Zig Host, the C ABI (`glowcap_host_close`, `glowcap_host_close_progress`, and
  `glowcap_host_lifecycle_state`), the driver loop, and all four language bindings. Failures stay ordered on the owner
  that can still receive them: the exact primary, a bounded secondary prefix, and the total consequence count. A second
  close joins that barrier instead of running teardown again. Implicit destruction is non-panicking. A fire-and-forget
  local behavior failure cannot become a reply; its Host retains the exception. Callerless and finalizer failures prefer
  the live Context journal; if that recorder is gone they enter the process-scoped queue. Explicit release still raises.
  Provider installation and connector establishment keep the setup error primary and retain cleanup failure beside it.
  Native iroh and WebRTC close failure survives the peer or endpoint handle and returns from the owner's release. Those
  sidecars stay usable from a consumer already inside Tokio: they do not nest `block_on`. Python close raises the first
  object and keeps the rest on `terminal_failures` (at most 64 retained objects, with `terminal_failure_count` for the
  saturated total). Process-scoped leftovers use `take_runtime_failures()`. TypeScript uses `takeRuntimeFailures()` and
  keeps the exact primary object, including frozen application errors. Racket uses `host-take-failures!` and
  `take_failures()` with no separate read/clear journal, and a queue-cap refusal stays `QueueCapExceeded` through
  repeated close. Rust uses the bounded runtime queue. Relay pumps join both legs and return the first I/O failure plus
  ordered close consequences.

The passable-value model and typed C/binding waist cover the pinned OCapN scalar and aggregate forms, including
arbitrary-precision Integer, Struct, and Error-as-fulfilled-data, plus the Set and Keyword forms used by Goblins. Error
data remains distinct from a broken reply at the Host, C, Rust, TypeScript, Python, and Racket surfaces. OCapN Null is
not implemented; see [protocol limitations](boundaries.md#protocol-and-interop).

## Codecs

| Codec       | Use                                                                                                  |
| ----------- | ---------------------------------------------------------------------------------------------------- |
| Syrup       | The interoperable OCapN wire format. Its fixtures are cross-checked against upstream Syrup encoders. |
| Cap'n Proto | glowcap-to-glowcap, with checked golden frames. Goblins speaks Syrup.                                |

The authenticated OCapN 1.0 profile uses Syrup. Two glowcap peers can prefer Cap'n Proto or `"glowcap-next"`. Each side
puts that offer in the hello's locator hints, and `engine.Peer.settleNegotiatedProfile` settles the pair after both
verified hellos arrive. [ADR-0103](decisions/adr/ADR-0103-hello-carried-profile-offers.md) records that handshake. An
absent offer is the v1.0/Syrup floor, so Goblins traffic stays wire-identical. Over onion the offer is sent only when
the partner is known to be glowcap, because the pinned Goblins cannot dial a hinted onion locator. A dial includes the
offer when it was handed the glowcap-hinted address form. An accept includes it when answering a hello that already
stated one. [ADR-0118](decisions/adr/ADR-0118-onion-profile-by-knowledge.md) records that exception. Every binding
exposes `native` and `interop` as coherent Host-profile choices reflected from `model.Preference`; the individual codec
and version selectors remain available for protocol work. Binding checks (`zig build rust-dogfood`, `deno-dogfood`,
`python-dogfood`, and
`racket-dogfood`) exercise the C ABI as a real consumer over a live Cap'n Proto socket. Zig applications can add another
codec through the open registry without changing the protocol core.

## Transports

| Transport     | Use                                                                                                                                                                                                                                                                                                                                               |
| ------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `iroh`        | Encrypted QUIC with discovery, relays, and a node ID that also serves as the OCapN designator.                                                                                                                                                                                                                                                    |
| `webrtc`      | An encrypted DataChannel reached through signaling. It carries a normal keyed OCapN session once the channel is open.                                                                                                                                                                                                                             |
| `noise-tcp`   | The keyed-tcp grammar with ADR-0107's sealed channel on the wire: a Noise_XK handshake between the two peers encrypts the channel end to end, and completing it proves the dialed key. The Zig host tiers, C driver loop, and all four native bindings dial and listen on it.                                                                     |
| `noise-relay` | The keyed-relay pipe with ADR-0107's sealed channel: CapTP peers run Noise_XK with each other, and the relay only forwards ciphertext. The native provider and every native binding compose it. Every event-loop binding can register a durable listener or dial this profile; the managed browser connector uses the same byte-fed Host sealing. |
| `onion`       | The standardized OCapN Tor netlayer. A version 3 service id addresses an encrypted, location-hiding circuit; Tor proves the service to the dialer but reveals no caller identity to the listener.                                                                                                                                                 |
| `keyed-tcp`   | TCP with a key designator as the dial target. The channel is cleartext and unauthenticated; the key does not prove possession.                                                                                                                                                                                                                    |
| `keyed-relay` | Cleartext WebSocket to a relay; the key designator is a dial target with no listening address. Trusted network and relay only.                                                                                                                                                                                                                    |
| `tcp`         | Cleartext testing path and this repository's Goblins TCP adapter. A host:port designator.                                                                                                                                                                                                                                                         |
| `inproc`      | An in-process connection for tests and deterministic local scenarios.                                                                                                                                                                                                                                                                             |

`onion` is the draft's transport and the one Goblins ships. Live Goblins also meets glowcap over `tcp` and `iroh`
through adapters in `conformance/goblins-peer/`. In-tree onion checks use fake SOCKS and control daemons under
`zig build check`. Live Tor proofs are `onion-interop`, `goblins-onion`, `ocapn-conformance-onion`, `bindings-onion`,
and `demo-rooms-onion`. See [stability](stability.md) and [known limitations](boundaries.md).

TCP, iroh, and relay join the native loop as transport packages. WebRTC joins that same loop once signaling has opened a
DataChannel. A relay locator can carry its `rendezvous-relay` route, with deployment configuration retained only as the
fallback for a bare locator. A bare `webrtc` locator needs configured signaling authority (`zig build webrtc-loop`,
`zig build webrtc-bridge-redeem`). The native WebRTC companion accepts generic ICE server records, including
credentialed TURN; provider-specific credential issuance stays with the embedding. Browsers without native sockets use
the byte-transparent relay in Deno, Python, Rust, and Racket. The relay forwards bytes without parsing CapTP or holding
a capability.

The TCP completion loop has held 500,000 signed sessions live over plain TCP in one release-mode server process, spread across 32 Hosts that share one identity. Each
session completed its signed handshake and fetched a published capability before the measurement barrier. The repeatable
machine, memory, timing, and namespace setup are recorded in [the 1.0 ladder](ladder.md#2-performance-at-scale); the
cheap eight-session form runs under `zig build runtime-check` so the two-process harness stays live without overlapping
another process family. Its listener defaults to
`127.0.0.1`; `net.Backend.initWithListenerIp4` selects an interface address or `0.0.0.0` before the backend enters
`TcpLoop`. The loop then exposes the exact kernel-bound IPv4 address and resolved port. A runtime test binds the
wildcard address and reaches it through loopback, while the Darwin build checks the same API against kqueue. Linux
prefers io_uring and falls back to epoll when the kernel or host policy cannot support glowcap's io_uring backend.
Both paths keep the loop-wide bounded read pool. `net.tcpBackendStatus` exposes the choice and reason through the TCP,
onion, keyed-relay, Noise, and iroh loop compositions. The many-sessions example and Rooms peer write the selected
backend to their own diagnostic streams. The recorded 500,000-session result used io_uring. Epoll passes the
completion-loop behavior tests but has no matching scale result.

`noise-tcp` and `noise-relay` run ADR-0107's Noise_XK channel on the byte-fed Host and native tiers; `BlockingSession`
refuses both symbols. The optional native relay module composes `ws` and `wss` over one provider, while browser-managed
WebSockets use their runtime's carrier. The remaining secure relay evidence is recorded under
[browser reachability](boundaries.md#browser-reachability).

See [known limitations](boundaries.md#transports-and-peer-identity) for the security and reachability differences
between these choices.

## Resource models

[Loam](loam.md) is glowcap's storage layer. It provides immutable collections,
checksummed records with typed local edges, and a portable core for
transactions and leases.

**Backends.** Loam has a volatile backend and an optional native LMDB module.
Both share batch validation, atomic updates to records and roots, exact
encoded-byte totals, and the decisions for completion and recovery. The native
profile uses BSD `flock` locking and synchronous LMDB commits in the LMDB 1.x
disk format.

**Transactions.** A transaction may propose a record again after staging it,
and can read its own proposals back. Several operations can therefore update a
shared record, such as an owner header or a parent row, in one transaction,
while the submitted batch still holds one change per record. Each exclusive
open reserves a new incarnation, and committed object names survive reopen.
Resident and pending record buffers have explicit bounds that do not grow
with the number of stored objects.

**Crash tests.** Native tests cover reopening cyclic graphs, map exhaustion,
and custody. Process tests send SIGKILL before commit, and after commit but
before local installation, then verify the complete graph in a fresh process.

**Sleepy actors.** The `hosting` module runs record-backed sleepy actors on an
existing Host and Vat. An actor's state lives in a record and loads when a
message arrives.

- Cold activations are coalesced, retained calls are bounded, local and
  foreign capability fields are checked, and replies wait for the commit.
- Nested Host capability arguments stay in custody through cold reads,
  preparation restarts, and session loss. A durable capture that is not
  supported is refused before any content is written.
- Durable publication descriptors and retirement tombstones keep discovery
  decisions across reopen. The attachment's write lane owns the step from
  commit to registry. A name leaves discovery at the terminal outcome, and an
  unknown outcome fails closed. A recovery that proves the batch never landed
  restores the earlier discovery state.
- Opt-in cold lookup coalesces fetches, rechecks current authority, and
  restores one exact target, without listing every name at startup or keeping
  a permanent registry row. Both backends index names atomically and keep the
  reservations after collection.
- Native process proofs kill an actor invoked over CapTP around its commit,
  then fetch its unregistered publication and follow its cyclic capability
  graph. Pressure tests cover allocation refusal, lease lifetime,
  cancellation, and growth in cold objects without growth in endpoints.

**Garbage collection.** Bounded batches trace durable roots, live custody and
historical edges through a stored queue, reclaiming cycles without waking actors.
Each cycle captures live custody once and reuses its scratch, so later batches
skip that work. Writes join tracing atomically; kill tests show safe recovery.
The [collection contract](loam.md#collecting-unreachable-records) owns admission,
receipt recovery and cost limits.

**Performance.** Commit installation reuses unchanged cached records while
keeping historical lease revisions. Resident slots keep the checked record
envelope with its immutable bytes; each view still checks its lease and current
authority where required. Sparse directory edits stage only changed mappings:
an in-place leaf edit preserves ancestor identities without rewriting them.
`bench-loam` measures LMDB conversation
graphs, cold message chains, hot and cold calls, edits, wakeup bursts, and
collection with queued foreground reads.

- Its managed population measures resource creation, atomic use and control
  issuance, control dependency chains, receipt-backed edits, moves, and
  filtered child iteration across shallow and deep ancestry.
- It also exercises bounded terminal cleanup and owner retirement, including
  the cost of reclaimed payloads and permanent name reservations.
- A shared four-worker executor measures sustained ordinary and managed calls,
  with bounded admission and exact replies.
- Retention phases hold up to 128 facets through repeated collection.
  Foreign-field phases restore and call 32 published targets through both
  established and fresh byte-fed sessions.
- Offline compaction records physical pages and elapsed time after the
  workers shut down.
- OS snapshots report whole-process RSS, address space, lifetime peak, and
  faults separately from tracked Zig memory.

Native actor retirement holds off Host pumping until the outer Vat call
returns, including for synchronous near calls and destructor cleanup.

A small version of the workload runs under `check`. The
[benchmark method](../bench/loam/README.md) explains what is measured.

**Owner retirement.** Retiring a managed owner closes admission, cancels
observations, retires endpoint publications, and compacts terminal records.
The steps can resume after interruption and keep the allocation and receipt
floors. Surviving parent grants get their delegation capacity back. The
[retirement tests](../test/loam/access/maintenance_test.zig) cover repeated
churn, held CapTP references, cold LMDB reopen, and process loss around the
cleanup commit; the [usage contract](loam/access.md#bounded-owner-cleanup)
describes it.

**Map growth and compaction.** Native inspection reports page geometry.
Growing the map takes exclusive access, refuses while backend work is active,
and keeps copied leases. A failed remap blocks the backend until it is
reopened. Offline compaction verifies every key and value while holding the
writer lock throughout, then installs a smaller data file. The
[maintenance tests](../test/loam/lmdb/compaction_test.zig) cover copy refusal,
cancellation, rename and sync failures, process loss, and replay of cold
retirement and terminal receipts. The macOS job includes the replacement
proof, and a successful macOS run is still on the
[completion queue](planning/loam/completion.md#n11-verify-the-complete-managed-path-under-failure-and-on-macos).
This crash evidence does not establish behavior under power loss, and it is
not a performance comparison.

**C and Rust.** Optional `libglowcap_loam` and `libglowcap_loam_lmdb` archives
and Rust's `loam` feature project the first complete resource lifecycle into the
existing Host. The [consumer guide](loam/c-and-rust.md)
records create/share/edit/restart/cold-reopen evidence and ownership. The
[browser profile](loam/browser.md) executes that lifecycle through IndexedDB
with exclusive Web Lock custody, commit-gated installation and retained callbacks.
Its Chromium proof reloads the page and cold-fetches the same derived publication;
quota rollback, abandoned observers and unrelated-actor progress are covered.
Both consumers execute the same [managed-control trace](../bindings/proofs/_support/loam_management.rs):
bounded child issuance, explicit policy/lifecycle powers, policy edits that
preserve pause and child configuration, independent control retirement,
management receipt replay after restart and retained descendant revocation.

### Managed access

Managed access is Loam's layer for resources, grants, and the references that
use and control them. Native Zig exposes it as `glowcap.loam.access`. Owner
retirement and terminal cleanup are described under
[resource models](#resource-models). C and Rust project fixed-resource creation,
managed registration, shared-policy descriptors, storage completions and held
use/control capabilities, managed children, policy edits, control attenuation
and strong reference fields. A shared LMDB/IndexedDB trace checks transactional
field authoring, exact and dependent disclosure, removal and cold restoration.
General graph and owner APIs remain outside that profile.

**Resource graph.** `glowcap.loam.access.core` holds bounded resource graphs
with owner and generation identity, reparenting that refuses cycles, and
exact, selected, or subtree scope evaluation. Graph mutations check revisions
and allocate only at initialization
([resource structure](decisions/adr/ADR-0153-access-resource-core.md)).

**Grant ledger.** Runtime schemas, unsigned bounds, issuance ceilings, bounded delegation,
editable terms, pause/resume and branch revocation evaluate one current grant path
([grant lifecycle](decisions/adr/ADR-0154-access-local-grant-lifecycle.md)). Persisted
[permission dependencies](decisions/adr/ADR-0190-declarative-permission-dependencies.md)
constrain direct issuance, edits and control ceilings independently of partial effect demands.

- A successful mutation returns owned change events. A failed or unchanged
  request produces none.
- A prepared write reserves its scope and keeps its inputs until an exact
  completion ([prepared writes](decisions/adr/ADR-0155-access-prepared-grant-writes.md)).
  An unknown storage outcome blocks protected access until it is resolved.

**Use and control references.** Native opaque use and control references each
carry authority over one committed grant. Controls enforce independent
lifecycle powers and copied management ceilings, through the same
prepared-write path
([native grant capabilities](decisions/adr/ADR-0156-access-native-grant-capabilities.md)).
Resident and durable bindings share control powers and ceiling checks, and
the durable endpoints described below expose those checks over CapTP.

**Record views.** Resource scope and grant evaluation read revision-checked
record views, shared with the resident graph and ledger. An unloaded record
produces an explicit read demand. Known absence, malformed rows, and stale rows
are refused separately. `GrantPlan` prepares a mutation the same way for
every source: it produces the affected grant, an optional parent update, and
the proposed event, without publishing anything.
`glowcap.loam.access.records` encodes resources, grants, and change events in
the existing Syrup syntax. Decoding is bounded. Only selected grant scopes
allocate, with at most two exact-sized lists and no retained input bytes
([resource record views](decisions/adr/ADR-0158-access-resource-record-views.md),
[grant records and plans](decisions/adr/ADR-0166-access-grant-records-and-plans.md)).

**Owner storage.** `glowcap.loam.access.storage` keeps owner headers, policy
descriptors, allocation counters, and sparse resource and grant directories in
ordinary Loam records
([managed owner storage](decisions/adr/ADR-0167-managed-owner-storage.md)).

- A bounded read pins model records and resumes directory traversal after a
  storage miss.
- Resource creation and shared grant plans stage metadata and bounded change
  history alongside content, in the caller's transaction.
- Each owner keeps 32 batches of at most 16 effects. Grant, resource, content,
  and independent control changes can share one batch. Separate stamps for
  authority, lifecycle, inventory, placement, subtree, and content tie each
  scoped view to committed batch positions. An unchanged effect adds no
  history.
- Native observation loads bounded replay and returns owned, scoped snapshots
  with opaque cursors bound to their context. Hidden commits leave a cursor
  unchanged. Expired visible history asks the reader to resynchronize.
- Native LMDB tests cover reopen, recovery from a lost acknowledgement after
  both commit and abort, refusal on batch overflow, and collection of expired
  batches. Portable tests cover a 258-resource directory with two cache slots,
  stale completions, malformed paths, allocation failure, and cleanup. Loaded
  grant evaluation uses fixed scratch space and never calls the allocator.

**Durable references.** `storage.Capabilities` restores opaque use and control
references from committed descriptor leases
([durable managed capability bindings](decisions/adr/ADR-0168-durable-managed-capability-bindings.md)).
Each descriptor keeps its exact owner and grant records, and each live
reference uses Loam retention without pinning the record. Bounded operations
load current authority, expose their read work, and admit only the edits their
role allows: use, delegation, or control. Derivation stages the child grant and
its separate use and control descriptors atomically with content. Native LMDB
tests cover reopening with roles intact, uncertain revocation during cold
reads, and descriptor collection after final release. Portable tests cover
ceilings, allocation failures, quotas, and cleanup.

**Hosted endpoints.** `access.hosting.Service` connects managed preparation to
the existing durable Host attachment
([managed Host turns](decisions/adr/ADR-0169-managed-host-turns.md)).

- Fixed-resource use endpoints check current authority before calling the
  application, and commit content replacements before replying.
- Each content registration and service decoder receives the application's
  own context, borrowed. A preparation keeps its content descriptor and sharing
  entropy source bound across storage reads; [registration tests](../test/loam/access/registration_test.zig)
  prove instance isolation, callback routing and teardown lifetime.
- Control endpoints stage permitted lifecycle or policy edits through the
  shared grant rules.
- Ordinary durable publications keep and restore these endpoints.
- Tests cover held CapTP references across pause, resume, and revoke; stale
  queued and cold activation; role separation; commit gating; and cleanup.
  Native LMDB tests restore endpoints and publications after reopen, and block
  calls through lost acknowledgements after both commit and abort.

**Derivation.** Fixed-resource `derive` adds hidden publication reservations
and keeps eight retry receipts per source endpoint
([durable facet derivation](decisions/adr/ADR-0170-durable-facet-derivation.md)).
Tests cover narrowing of permissions and delegation, expiry without reissuing,
publication custody, and native recovery from a lost reply after reopen
without duplicate grants.

**Crash proof.** The [managed process proof](../test/loam_managed_crash.zig)
repeats issuance, control attenuation, revocation, content mutation, reference
removal, resource movement, and leaf deletion, killing the process with
SIGKILL at commit, at installation, and before the reply is delivered. Fresh
processes then fetch the durable names, keep the use and control roles, and
verify the committed events.

**Returned capabilities.** A managed content method can hand over the exact
saved authority in a stored reference field, through a declared disclosure
([explicit disclosure](decisions/adr/ADR-0172-explicit-disclosure-of-returned-capabilities.md)).
Any capability value the method did not declare fails closed before
settlement, both in process and over a live CapTP session.

- Dependent disclosure keeps both the invoking endpoint and a stored target.
  It admits each target method through the current authority of both
  ([dependent returned capabilities](decisions/adr/ADR-0173-dependent-returned-capabilities-and-reference-edits.md)).
- Strong reference fields can be replaced or removed inside the content
  transaction, with evidence for aborted writes and LMDB reopen.
- [Typed restoration recipes](loam/references.md) add bounded attachment
  dependencies and checked foreign sturdyrefs, with exact identity checks
  before any field write. Native compaction and restart tests keep the
  original, use, and control roles. Nine process-kill cases cover installing
  foreign fields.
- Foreign dependent calls use owned Host results, and nested replies go
  through ordinary handoff staging.

**Lifecycle and receipts.**
[Managed lifecycle](decisions/adr/ADR-0178-managed-lifecycle-and-mutation-receipts.md)
adds persistent child indexes, moves checked for cycles and depth, and stable
leaf deletion.

- Native child cursors filter candidates through admission and refuse stale
  continuations.
- Resource and content effects commit with shared receipts. Mutation windows
  keep eight exact results per endpoint, reject conflicts and expired
  sequences, and check current authority before replay.
- Controls support narrowing, independent revocation, and scoped inspection.
- `derive-managed` keeps the issuer's control separately, and the recipient's
  use cannot recover it.
- Preparations in the same batch validate the combined owner state, including
  independent control revocation. Exact completion tickets keep pending read
  custody, and prepared structural changes keep their resource bindings
  through close.
- CapTP and LMDB proofs cover lost issuance and attenuation replies, exact
  control recovery, hidden children, and rollback.

**Describing access.** `describe-access()` reports a use endpoint's own and
effective policy, using the same evaluator as protected calls
([scoped access descriptions](decisions/adr/ADR-0171-scoped-access-descriptions.md)).
An inactive endpoint reports only its status, and no ancestor identity or
owner revision is disclosed. Resident and stored native use APIs share this
contract. Tests cover ancestor restrictions, activity from unrelated owners,
stale queued inspection, exact large bounds, and LMDB recovery and reopen.
`describe-control()` reports current management powers without resource or
ancestor identities.

**Observing access.** `mutate(sequence, "observe")` registers a durable
receiver and a separate canceller over an exact descriptor. Receivers poll or
wait inside existing Attachment preparation. Cancelling closes the retained
context and retires both names atomically, and a retried registration recovers
the same references. Tests cover status-only delivery while inactive, ancestor
revocation, hidden activity, overflow, aborted writes, stale reads, allocation
failure, quotas, and 32 parked receivers within declared budgets. LMDB and
process-loss tests cover cold discovery, exact retry, and cancellation at the
commit and publication boundaries. The
[observation guide](loam/access.md#observing-held-access) covers the methods
and their costs.

## Actors and hosting

`actors.Vat` adds a Goblins-shaped actor layer above the protocol engine. It supports local actors, eventual sends that
return vows, hosted objects, forwarding, attenuation, and revocation. Optional snapshots and restore apply only to local
actor state; they never rewind a network session.

A Host owns one Vat and gives each session Port its own ingress, so one connection's runaway local work is condemned
without draining a sibling's. Queued turns are admitted under per-ingress budgets
([ADR-0099](decisions/adr/ADR-0099-shared-vat-scheduling.md)).

The same hosting model is available in each language binding. The browser peer can answer a caller over the connection
the call arrived on, so a peer with no listening socket can still receive replies and participate in a handoff.

## Tools and applications

- `zig build` installs the `glowcap` command. It can listen, call, fetch, enliven, run an interactive CapTP lab, serve a
  curated MCP interface, and join a rooms session.
- The rooms, tasks, and tools examples run one server with clients written in several bindings.
- The [Rooms application](../apps/rooms/) runs browser and terminal peers
  with durable sessions. Members hold rooms and direct messages with files
  over WebRTC, the Noise-sealed relay, iroh, and TCP. Room history is kept
  in files or PostgreSQL, and member-owned archives are read as one combined
  account ([ADR-0144](decisions/adr/ADR-0144-combined-archive-views.md)).
  IRC works in both directions, directories peer, and operator capabilities
  are revocable and come with a live timeline. Its three services keep
  their identity across restarts and drain on shutdown. Either participant can
  close and reopen a direct conversation: the current inbox is advertised
  again, fresh reply capabilities replace prior routes, and superseded owned
  connections close when no route uses them.
  `zig build rooms-web-shared-session` attaches two real browser profiles to
  the session service and proves the mirrored member, lines, files, and
  issued, paused, and revoked access. The other browser proofs under
  `rooms-web-*` cover joining, direct messages on every transport, private
  rooms, routes, reconnect, and archives on the shipped page. Rooms ships as
  source at an exact Git commit. The Compose deployment copies a complete
  verified Linux product into its image and runs without checkout mounts.
  On Linux, the checkout launcher selects that prepared product for deployment
  without extra flags. Deployment configuration stays in host state across
  source builds and product installations.
- ocapnviz can open a read-only trace sturdyref as a browser OCapN peer. Its production Chromium check covers replay,
  subsequent live observations, and exclusion of the observer session from its own topology. The rooms trace endpoint
  behind that sturdyref requires the trace capability from both viewers and
  trace producers
  (ADR-0120).
- The accountability example layers signed identity and an audit log above ordinary capabilities without changing CapTP.
  Its three-Host loopback proof redeems a real handoff and attributes the resulting call to the recipient, not the
  introducer.

### Rooms in detail

Rooms is a chat application built on glowcap. The [Rooms page](../apps/rooms/README.md) is the
way in, and [operating Rooms](../apps/rooms/operating.md) covers its grants, services, and limits.

- *One implementation.* A single Rust implementation owns room and directory policy, durable authority, the session
  and its recovery, files, archives, operations, peering, IRC, and the bounded CommonMark message rendering. It runs
  as the room server, the session service, the archive service, the web front, and the two IRC edges. In the
  browser it runs as Wasm, linked with glowcap's Zig Host in one module, and React renders what Rust observes.
- *Managed session declarations.* `rooms-application::content` defines version-one workspace intent, typed custody
  and effect records, session permission requirements and presets. The same application proofs run on Linux and
  in Wasm, and Rust generates the browser metadata. [Remaining integration](planning/rooms/integration.md)
  covers production storage, admission and management; the production session still uses its existing authority model.
  Bounded workspace/custody/effect codecs pair data coordinates with separately held strong fields and retain
  original effect targets. Portable proofs check fragments, generations and aggregate capacity; Linux opens the
  complete schema family. Browser metadata comes from that registry; Rooms permission dependencies project into Loam on Linux and Wasm.
- *Messages.* A message keeps its authored source on the wire and in archives. Raw HTML stays inert, remote images
  never load on their own, and links may use only approved schemes. A message can preview at most five validated
  URLs, which readers fetch through a same-origin service that refuses unsafe redirects and private addresses.
- *Sending.* A native room sender rebuilds its ordered receipt from retained text, and releases rejected requests even
  after the caller cancels. It reuses acknowledged, immutable upload bytes for local display and recording, while
  other members still receive the complete message.
- *History.* Room history is stored in files or PostgreSQL behind one index.
- *Failure reporting.* Operations credentials follow the retry class of their failure, and IRC numerics follow stable
  failure codes. Direct-message cleanup tells a departed registration apart from a partner whose close stalled.
- *Sessions and skills.* `glowcap apps rooms session` exposes the Rooms session through the Zig command tree. The
  individual and team skills share its lifecycle and local inbox. They observe every joined room and DM and keep each
  event until it is acknowledged. One `session listen` consumer delivers each event once per run, replays
  unacknowledged events after a restart, and stays quiet between changes. A failed inbox observer reports its gap
  without stopping other views of the session. The process proof covers several rooms, private replies, and
  restarting with unread events.
- *Packaging.* The [glowcap product package](../apps/rooms/host.md) includes the CLI, the private Rooms runtimes, the
  prepared browser application, and both skills. `glowcap-pack` serves the browser assets and repeats the process
  proof from an extracted installation, with no checkout tooling or library-path overrides. `glowcap-package-test`
  checks the package and image inventories and the archive publication fixtures, including checksum failures, rename
  failures, and termination signals. These checks do not claim that any archive or release has been published.
- *Running from a checkout.* The checkout launcher builds the product if it is missing, then runs the complete staged
  installation without build tools. After editing source, run `rooms-build` explicitly. The runtime proof exercises
  this path without a binary override.

[`docs/cli.md`](cli.md) is the command-line guide. The [examples](../examples/README.md) and [apps](../apps/README.md)
pages list the programs.

## What checks it

[Stability](stability.md) says which checks run on main and `dev` pushes and pull
requests, and what each one does not prove.
[Community review](community-review.md) is the outside-peer matrix.
