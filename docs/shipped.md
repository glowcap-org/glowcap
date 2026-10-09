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
  `iroh.MultiplexedAdapter` as a `driver.Transports` resident for
  `driver.connect` and `driver.listen`; C and native callers share the
  adapter state.
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
  Locally invoked owning behaviors can forward their answer to a foreign
  capability, preserving exact reply identities in the original bounded result
  owner. Failed outer turns withdraw the forwarded effect, including staged
  third-party introductions.
  Zig and C owning callbacks can also send or tell local and foreign targets.
  Local public sends deliver exact values through Host actions; tell allocates
  no answer owner. Child work survives Host finish, while outer-turn failure
  withdraws uncommitted delivery. Public handle release cancels observation.
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
  can commit. The waiting message keeps its place in the recipient's queue, so later sends to that peer stay behind
  it. A failed actor turn withdraws such a message with its other far sends, including any promise proxy the message
  created. Core and C Host cover terminal failure. Node-local routes use an explicit reference arm, so every `u64`
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
  Rust preserves owners of refused native releases across thread exit instead of destroying borrowed state.
  Those abandoned releases remain allocated for the process lifetime. Successful retries return empty queue storage.
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
`zig build webrtc-redeem`). The native WebRTC companion accepts generic ICE server records, including
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
onion, keyed-relay, Noise, and iroh loop compositions. The recorded 500,000-session result used io_uring. Epoll passes the
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

**Backends.** Loam has a volatile backend and an optional LMDB module.
Both share batch validation, atomic updates to records and roots, exact
encoded-byte totals, and the decisions for completion and recovery. The LMDB
module uses BSD `flock` locking and synchronous commits in the LMDB 1.x
disk format.

**Transactions.** A transaction may propose a record again after staging it,
and can read its own proposals back. Several operations can therefore update a
shared record, such as an owner header or a parent row, in one transaction,
while the submitted batch still holds one change per record. Each exclusive
open reserves a new incarnation, and committed object names survive reopen.
Atomic bootstrap opening admits missing metadata or the exact existing store
identity. Rust staging exposes provisional resource metadata before commit;
aborted names never repeat, and unsubmitted guards abort on retirement.
Resident and pending record buffers have explicit bounds that do not grow
with the number of stored objects.

**Crash tests.** Native tests cover cyclic graphs, map exhaustion and custody.
Process tests send SIGKILL before commit, and after commit but
before local installation, then verify the complete graph in a fresh process.

**Sleepy actors.** The `hosting` module runs record-backed sleepy actors on an
existing Host and Vat. An actor's state lives in a record and loads when a
message arrives. Cold activations coalesce, calls are bounded and replies wait
for commit. Nested capability arguments retain custody through cold reads,
preparation restarts and session loss. Unsupported durable captures refuse
before content writes. The [reference guide](loam/references.md) owns saving,
restoration and disclosure contracts.

Explicit live fields retain exact Host custody under graph-owned recipes.
Zig and C/Rust epoch activation use the existing storage lane; unknown writes
preserve reservations and committed custody survives reply refusal.
Warm lookup checks the lifetime; restart refuses old fields. Bounded collection
retirement releases custody. Rooms proves publication, invitation, membership
and private direct/IRC custody. The [session guide](rooms/session.md) describes production ownership and recovery.

The [Rooms managed browser module](rooms/session.md)
opens a per-tab IndexedDB workspace with independent use/control handles.
The production page and process startup use this owner. The complete shipped
browser inventory, runtime contracts and external protocol checks exercise these
production consumers. [Session measurements](../bench/rooms/session-costs.md) cover sole Host
locator ownership, membership snapshot reuse and linear UI custody projection.
Its inboxes check initiating grants, bound queued input and drain calls on close.
Managed directory and room workers install their actual callback, register or
subscribe, and acquire the exact committed results. They retain failed stages
for retry and retire when their installed selection changes. The session owns
cleanup after a view disappears. A managed aggregate reconciles requested
directory, room and direct rows, preserving sibling workers and shared field aliases.
An owned workspace observation continuously reconciles these rows, interrupting
readiness waits when intent changes and retaining failed cleanup for retry.
Direct workers announce their actual reciprocal inbox through a retained command.
Their bounded callbacks preserve posted-line capabilities and refuse retired routes.
The viewer matches introduction readiness to the original registration and opening.
Pending waits have a 30-second deadline, and closing or cancelling a wait refuses it.
Directory registration preserves the requested nickname separately from the
assigned name. Nickname edits retire the worker; assignment does not restart it.
Rooms retain the current name and registration identity. Pending nickname
requests preserve their seats; assignment changes fence callbacks and rejoin.
Directory readers expose listing, location and member metadata through the exact
acquiring grant; retained readers cannot be redirected by workspace edits.
The exported managed browser application starts directory, room and direct consumers
and reports readiness or admission failures. Notifications contain descriptive
data and bounded file handles. Each file retains its exact initiating workspace
endpoint; its dependent reader checks that grant and the upstream file authority.
Explicit release prevents disclosure from a pending read. The application owns
consumer shutdown and retains failed cancellation for retry.
Membership workers share private content and grant-inventory feeds and check their exact held
source after a wake, without per-membership observation registrations. Runtime observers are
fenced by the session's live marker and reclaim expired quota on registration.
Idle retained calls stay independent of membership
count; callbacks and retained readers still check their exact acquiring grant.
Worker sources must address their owning session. Arbitrary foreign session
custody remains importable but cannot start a local membership worker.
Direct consumers return real posted lines and project reciprocal routes, typing
and room/archive handoffs. Line changes recheck the original grant and installed
route. Opaque incoming handles prepare exact-authority acquisition; source pause,
replacement and callback retirement fence retained lines. Directory introduction
and publication use exact managed receipts. Production page proofs exercise
scoped outage reporting, recovery and retention of uncertain send receipts.
Recovery resumes the exact retained executor before reading its result. Paused
executors and uncertain result acquisitions retain their original receipt custody.
Failed activity reads wait for a later change or explicit retry with the same reader.
The real-server browser journey covers selected text previews, acquisition of
posted-line custody, exact edit/withdrawal and history under enabled server policy.
Directory acquisition retains the fetched target and the exact invoking workspace
endpoint in one revision-checked candidate. The shared client and generated
browser front preserve that source across a remote caller's capability reflection.
Main-page and process startup use the managed Loam owner. Browser presentation
consumes managed intent and activity; prepared actions retain exact custody through
refusal and recovery. The access editor holds independent controls and submits
revision-checked issuance, policy, label and lifecycle operations.
Supervised memberships retain exact upstream name/seat retirement custody
through source revocation and interrupted leave waits. Public results remain
source-dependent; unknown subscriptions refuse cleanup and retain ownership.
The managed browser application publishes its independent management branch;
issued and narrowed controls have exact durable names distinct from use.
Prepared policy, label and lifecycle changes retain their exact control and
receipt identity across resubmission. Replaying an old pause after resume
recovers its outcome without pausing the grant again.
Known local issued use and control handles expose those names at their owner's
relay. Attached or restored custody requires its original publication address.

Durable publication descriptors preserve discovery decisions across reopen.
Unknown retirement fails closed; confirmed absence restores prior discovery.
Cold lookup coalesces fetches and restores one exact target without a startup
population scan. Both backends retain name reservations after collection.
Process proofs fetch unregistered publications and cyclic graphs after killing
writers around commit. Pressure tests cover custody, cancellation and capacity.

**Garbage collection.** Bounded batches trace durable roots, live custody and
historical edges through a stored queue, reclaiming cycles without waking actors.
Each cycle captures live custody once and reuses its scratch, so later batches
skip that work. Writes join tracing atomically; kill tests show safe recovery.
The [collection contract](loam/collection.md) owns admission,
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
[browser profile](loam/browser.md) uses IndexedDB with exclusive Web Lock custody.
Shared resumable batch evaluation bounds inputs; terminal events gate installation.
Its Chromium proof covers reload, cold publication fetch, quota rollback,
abandoned observers and unrelated-actor progress.
Both consumers execute the same [managed-control trace](../bindings/proofs/_support/loam_management.rs):
bounded child issuance, explicit policy/lifecycle powers, policy edits that
preserve pause and child configuration, independent control retirement,
management receipt replay after restart and retained descendant revocation.
Rust lends typed management descriptions and indexed inventory [views](loam/c-and-rust.md).

### Managed access

Loam supplies independently held use and control capabilities, scoped policy,
durable issuance and exact recovery, paged management and access observations.
The [managed access coverage](loam/coverage.md) records its implementation and
proofs; [remaining consumer boundaries](boundaries.md#managed-access) stay explicit.

## Actors and hosting

`actors.Vat` adds a Goblins-shaped actor layer above the protocol engine. It supports local actors, eventual sends that
return vows, hosted objects, forwarding, attenuation, and revocation. Optional snapshots and restore apply only to local
actor state; they never rewind a network session.

A Host owns one Vat and gives each session Port its own ingress. Queued turns are admitted under per-ingress budgets
([ADR-0099](decisions/adr/ADR-0099-shared-vat-scheduling.md)).

Far-vow observation is one-shot. After a notification is delivered or discarded,
a late listener is refused without keeping a history of completed answers.
Canceling a listener leaves the pending notification available for another observer.
During bulk failure, callbacks can cancel other pending listeners before their
contexts are retired. The drain allocates nothing and releases its storage.

Releasing a Host vow or cancelling its owned call also works while a foreign
argument is awaiting gift preparation. The pending queue owns the answer release
through success or failure. Caller cancellation cannot retract the admitted send.

A failed turn finishes participant rollback before notifying failure listeners.
Those listeners can start new turns without publishing the failed turn's sends.
Local turns preserve replies that borrow replaced actor state before committing
their sends. If that copy fails, the turn drops its sends and staged replacement.
`become` records the next state before freeing a superseded pending state.
Snapshot restore installs the restored table before freeing discarded state.
Destructors can reenter or spawn actors without invalidating a live table borrow.
Reply interceptors run after the handler commits. Nested actor calls keep their
effects whether the interceptor forwards, claims or refuses the reply.
Answered far sends reserve notification storage during admission, shared across
the Vat's Ports. Rollback keeps each listener cancellable until it is invoked.
Forwarding to an existing vow registers a turn participant. A failed turn detaches
that continuation and breaks its own answer, leaving the source vow independently
observable and settleable. Local and wire callers receive the failure once.
An answerless forwarded turn preserves handler failure for payload retirement,
even though there is no caller waiting for a reply.

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
  A fresh session Host retires saved directory registrations, direct routes and
  publication leases before exposing the workspace. Nickname choices, history and drafts remain;
  registration readiness follows the new callback's acquisition. Reconnect checks the
  peer's exact directory registration and reuses that conversation. A replacement
  registration gets separate history. Closing an already closed rail entry
  removes it from the workspace.
  Send transfers the submitted text and files out of the editable composer.
  A queued submission survives earlier receipt settlement and later typing.
  Refusal restores an untouched draft; recovery selects the original gesture
  by its operation identity, including when another message has identical text.
  `zig build rooms-web-shared-session` attaches two real browser profiles to
  the Rust managed owner and proves the mirrored member, lines, files, and
  issued, paused, and revoked access. The other browser proofs under
  `rooms-web-*` cover joining, direct messages on every transport, private
  rooms, routes, reconnect, and archives on the shipped page. Rooms ships as
  source at an exact Git commit. The Compose deployment copies a complete
  verified Linux product into its image and runs without checkout mounts.
  On Linux, the checkout launcher selects that prepared product for deployment
  without extra flags. Deployment configuration stays in host state across
  source builds and product installations.
  [What Rooms ships](../apps/rooms/shipped.md) describes each part in detail.
- Host trace replay reports currently open sessions without retaining message history. Callback and queue installation
  in the C ABI replay after publishing the new consumer. Trace callbacks refuse Host-driving reentry.
- ocapnviz can open a read-only trace sturdyref as a browser OCapN peer. Its production Chromium check covers replay,
  subsequent live observations, and exclusion of the observer session from its own topology. The rooms trace endpoint
  behind that sturdyref requires the trace capability from both viewers and
  trace producers (ADR-0120). The exporter advertises the browser CapTP channel
  and telemetry route separately. Channel admission supplies no trace authority;
  the ordinary Swiss fetch acquires the object.
- The accountability example layers signed identity and an audit log above ordinary capabilities without changing CapTP.
  Its three-Host loopback proof redeems a real handoff and attributes the resulting call to the recipient, not the
  introducer.

[`docs/cli.md`](cli.md) is the command-line guide. The [examples](../examples/README.md) and [apps](../apps/README.md)
pages list the programs.

## What checks it

[Stability](stability.md) says which checks run on main and `dev` pushes and pull
requests, and what each one does not prove.
[Community review](community-review.md) is the outside-peer matrix.
