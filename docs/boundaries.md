# Known limitations

These are the limits that can change a deployment or API choice. [What ships](shipped.md)
is the feature inventory. [Stability](stability.md) says how each surface is
tested. The [roadmap](roadmap.md) lists future work.

## Transports and peer identity

- **Plain `tcp` is a testing transport.** Its designator is an address, so the
  peer claims no identity and proves none, and the channel is cleartext. That
  fails the OCapN draft's own netlayer requirement that a session be secure
  enough that only its participants can insert messages. Upstream Goblins ships
  onion (and an in-process `fake`), not TCP. The OCapN suite's equivalent is
  named `tcp-testing-only` and declares itself unsafe in its own source. The
  Goblins TCP netlayer these checks dial is a shim in this repository. Use
  `tcp` to reach a peer that speaks nothing else, not to deploy.
- **`keyed-tcp` and `keyed-relay` are cleartext and unauthenticated.** Their key
  designator is a stable dial target, but the channel proves no possession of
  it. Anyone on the path reads and can alter every frame; on `keyed-relay` that
  includes the relay operator even when the carrier leg itself uses WSS.
  Prefer `noise-tcp` or `noise-relay` for glowcap-to-glowcap sealed channels,
  iroh when discovery or NAT traversal is needed, and WebRTC for a direct
  browser channel.
- **A TCP locator names a socket.** On plain TCP, the crossed-connection
  tiebreak trusts the location each peer declares. A peer that can connect and
  claim an address you are dialing can make your outgoing session lose that
  tiebreak. Only a channel-authenticated key designator can collapse a session,
  so an unproved claim from raw keyed TCP or keyed relay cannot condemn one.
- **Two sessions to one peer stay open on an address transport.** `127.0.0.1`
  and `[::1]` are different designators, and neither is an identity glowcap
  will act on, so nothing joins the two sessions. A key-designator transport
  with channel proof recognizes the peer by its durable name and keeps one.
- **`inproc` is a test transport.** Its unbounded pipes block the reading
  thread, so it is not a production or load-test substitute.
- **`onion` is proven live against the portable upstream suite, but not at scale.** `zig build
  onion-interop` holds a session between two glowcap peers and restores the same
  service in a fresh process. `zig build goblins-onion` does it with a real
  Spritely Goblins vat in both directions. `zig build ocapn-conformance-onion`
  passes the complete portable upstream suite plus the strict abort probe through the
  upstream onion netlayer. The local fake-daemon checks cover the blocking
  resident, the completion resident behind `driver.Transports`, generic
  provider package, native Zig `OnionLoop`, and provider installation from
  every native binding. Native Zig `Session` and `Server` reach Tor at TCP
  addresses only; a Unix-socket SOCKS or control endpoint needs a binding or
  the blocking resident. Live steps need `tor`
  and outbound network access, so they remain siblings of `check`. No recorded
  live-Tor scale run exists.
- **An onion session upgrades past the `1.0` profile only when the partner is
  known to be glowcap.** The pinned Goblins accepts a hinted hello on any
  transport, and `zig build goblins-onion` probes that live. Its dial arm
  still refuses a hinted onion locator, and gift withdrawal is keyed by the
  full node value, so every onion locator on the wire stays bare. A glowcap
  peer states a preferred profile over onion only when it already knows the
  other side: it was handed the glowcap-hinted form of the address, or it is
  answering a hello that stated a preference. A host on the default baseline
  profile, and every Goblins session, settles the baseline. Two glowcap peers
  that both know each other settle `glowcap-next` over Tor.
  [ADR-0108](decisions/adr/ADR-0108-onion-netlayer.md) records the locator
  rule.
  [ADR-0118](decisions/adr/ADR-0118-onion-profile-by-knowledge.md) records
  when that offer is allowed. `conformance/ocapn-findings` is the Goblins
  behavior record.
- **iroh reachability is not fully exercised in CI.** The loop checks
  multiplexing, and opt-in checks cover discovery and relay use from one host.
  They do not cover hole-punching between separate NATs.
  `discovery_no_relay` has no green check because it needs a publishable direct
  address. A live Goblins-over-iroh session does have one, `goblins-iroh`, over
  the iroh netlayer this repository wrote for Goblins; it runs on loopback with
  direct dial (no relay), so it adds no reachability evidence.
- **A `webrtc` dial needs configured signaling authority.** On TypeScript, a
  runtime composed with `webrtc.connector(signaling)` dials a bare `webrtc`
  locator: the connector runs the offer, answer, and candidate exchange and
  holds the keyed session over the opened DataChannel. Native Zig sets that
  authority on the WebRTC backend rather than on Session. Without it the dial
  refuses.

The iroh and WebRTC transports rely on their existing sidecars; glowcap does
not ship a native Zig QUIC or WebRTC stack.

- **A peer that dies without closing is noticed on iroh in seconds, not at
  once.** A TCP peer killed at the terminal is reported gone immediately: the
  OS sends a FIN and the far end reads end of stream. UDP has no equivalent, so
  a killed QUIC peer simply stops answering.
- **iroh ends a silent peer with an idle timeout.** The sidecar turns that into
  a closed event (`transports/iroh/src/lib.rs`). The default is fifteen seconds;
  set `GlowcapIrohConfig.idle_timeout_ms` (surfaced on every binding) when a
  live session means presence. Rooms asks for eight. There is no separate
  keep-alive: the transport derives the heartbeat from the timeout. A shorter
  timeout costs more idle traffic, charged against the per-connection budget in
  [`docs/ladder.md`](ladder.md).

## Runtime and scale

- **TypeScript on Bun cannot host the native driver loop.** Bun's FFI executes
  native calls on its JavaScript thread, so a listener or blocking transport
  lifecycle could park the reactor. Those APIs refuse before allocating a
  native runtime. The synchronous Host and locator surface and byte-fed client
  path remain available; Deno owns the full native-loop binding proof.

- **A Host's actor runtime (its Vat) is single-threaded and non-preemptive.**
  A hosted behavior runs synchronously to the end of its turn, so a slow or
  blocking handler stalls every session adapter (Port) that shares the Host.
  Keep handlers bounded. Separate Hosts isolate scheduling, but they also
  separate network identity and actor graphs. When those must stay shared,
  move the blocking work out of the behavior callback:
  - In the actor layer, a behavior defers its answer with a resolver vow
    ([ADR-0102](decisions/adr/ADR-0102-off-turn-settlement.md)). When the work
    finishes, it settles the answer through `Vat.fulfillVow` or
    `Vat.breakVow` on the owning thread.
  - A byte-fed embedder has the same mechanism in C:
    `glowcap_host_turn_defer` and its settle verbs.
  - A TypeScript or Python behavior that returns a promise defers this way
    automatically. The Rust and Racket bindings expose the resolver pair
    directly.
  - A native worker thread hands its settle back through
    `driver.SettleMailbox`. Posting to it wakes the owning thread, because
    `driver.HostRuntime` polls the mailbox's fd alongside its residents. The
    settle then applies
    on the owning thread. Settles from another thread carry plain data only;
    a capability never crosses threads.
- **`BlockingSession` serves one connection on one fiber.** Use `Session` or
  `Server` for a partner that streams while waiting for you to drain output;
  `HostRuntime` serves every session on resident completion I/O.
- **`driver.HostRuntime` runs every transport as a resident.**
  - Every TCP profile, `inproc`, both relay symbols, and onion run on one
    runtime-owned `net.StreamStack`, a completion resident
    (`net.completion_resident`, ADR-0202), with the Host sealing `noise-tcp`
    and `noise-relay`. Foreign stream providers run on the external
    completion resident. An onion listen still publishes its service
    synchronously, holding the runtime's thread for up to its setup deadline.
  - The runtime does not report which Linux backend its stream stack
    selected. A completion loop reports io_uring or epoll, with the fallback
    reason, through `net.tcpBackendStatus`.
  - A transport that multiplexes many connections behind one shared readiness
    descriptor joins through the common provider package ABI (ADR-0112). That
    ABI covers dials, listener metadata and lifecycle, claiming accepted
    connections, and teardown.
  - iroh implements the multiplexed entry point of that ABI
    (`glowcap_iroh_transport_provider`). `zig build iroh-driver-provider`
    proves both dial and accept live.
  - WebRTC implements the ABI's external connection claim. Its archive handles
    signaling and opens the DataChannel, then `glowcap_driver_adopt_external`
    hands either session role to the generic driver.
    `zig build webrtc-driver-provider` proves both halves and an authenticated
    capability fetch.
- **`libglowcap_driver` steps one `HostRuntime` from C.** It waits on a
  single readiness descriptor: epoll on Linux and kqueue on Darwin. On other
  systems `glowcap_driver_readiness_fd` returns a typed failure, but the
  stepping verbs still work. Dial and accept handshakes advance a little on
  each step, within the handshake budget. That means two loops on one thread
  can dial each other, and a stalled connector cannot block a step. Stream
  providers start connections through a nonblocking `start_connect` contract
  and report completion when the descriptor is ready.
- **Memory for connections that are still opening is bounded.**
  `max_pending_opens` defaults to 256 per driver Host. It counts transport
  connects and CapTP handshakes from dials, accepts, external adoption, and
  redeems. A stream accept over the limit waits in the kernel backlog. A
  multiplexed-provider accept over the limit is claimed and closed without
  creating a session. Tune the bound together with the wire-buffer and
  deadline policy you deploy.
- **A driver loop permits at most one listener per registered provider
  profile.** Listener ids route accepts independently; listeners can be
  selected as the Host's acceptable route and closed individually. A provider
  package may impose a narrower runtime limit. Closing the selected listener
  leaves no acceptable route until the caller selects another.
- **Provider packages own which profiles the loop can open.** The TCP package
  realizes `noise-tcp`, `keyed-tcp`, and testing `tcp`. Key-addressed profiles take
  their designator from the wrapped Host and expose the bound address as a
  separate listener hint; `noise-tcp` seals and authenticates the channel in
  the Host. Other transports arrive as packages. Iroh's multiplexed provider
  (`glowcap_iroh_transport_provider`) owns listener start, metadata, accept
  claim, stop, and dial. Providers that cannot host refuse listener start
  explicitly.

  The relay package can dial both `keyed-relay` and `noise-relay`, but may host
  only one at a time. The deployed rendezvous protocol queues inbound legs by
  durable designator without a channel-profile discriminator. Two relay
  listeners would therefore route nondeterministically.
- **Callers can still choose an infinite wait.** Zig requires an explicit
  handshake and settle budget, but `.unbounded` remains available. The CLI and
  examples use finite deadlines; library callers must make the same choice.
- **A durable sturdyref survives a restart only if you keep its entropy.** The
  library keeps no registry across processes, because the core does no I/O and
  cannot own a file. Instead, it guarantees that a durable name depends only
  on the 16 entropy bytes you passed to `publishDurable`. Keep those bytes and
  republish with them at startup, and callers holding the old sturdyref reach
  the new actor. If you lose them, the name is gone. `Host.Options.bootstrap_durability` still refuses
  `.durable_bootstrap`, which would promise a registry the library does not
  have.
- **Some binding pumps copy outbound frames.** TypeScript, Python, and Racket
  copy bytes before an asynchronous write because their FFI lifetimes cannot
  retain the Zig-owned frame. Rust retains the frame across the write.
- **Third-party codec registration is Zig-native today.** The C ABI and the
  language bindings can select the built-in Syrup and Cap'n Proto codecs, but
  they cannot install a new codec implementation into the registry. A future
  binding-facing codec extension should be an extension archive or Wasm
  component registered at the codec seam, with explicit frame ownership and no
  per-frame callback into a host-language runtime.
- **macOS runs the native suite, and Windows is not implemented.** `zig build check`
  and the external-runtime matrix remain Linux-only.

## API gaps

### Loam storage

[Loam](loam.md) stores local records and runs record-backed sleepy actors:
actors whose state lives in a record and loads when a message arrives. The
[usage guide](loam.md) explains costs and limits, and the
[implementation sequence](planning/loam/architecture.md) owns the remaining
integration. Rooms' main chat page and process startup use the managed Loam workspace,
capability custody and effect receipts. Browser startup restores the per-tab
IndexedDB owner; process startup restores LMDB and separate use/control publications.
Recursive room and directory resources remain the next Rooms integration phase.

- **What restores.** The optional LMDB backend and the Host attachment restore
  checked local and foreign fields and committed actor state. LMDB stores
  need the LMDB 1.x disk format, and a store from an older prerelease needs a
  fresh directory. Metadata format 3 rejects older record and name-index
  profiles.
- **What is not durable.** Pending messages are not durable, and a lost reply
  does not mean the mutation was aborted. Callbacks only encode durable state
  and perform no external effects.
- **References in calls.** Host and CapTP calls carry owning capability
  arguments and replies. An admitted argument stays in custody through
  storage waits and through every terminal outcome.
- **Garbage collection.** Local tracing collection protects live custody and
  pinned historical edges. It needs spare storage for its queue and marks.
  Initial custody is captured once per cycle; new custody reserves a bounded
  marking obligation before publication. A full journal can refuse new custody.
  Root shading is bounded independently of the record/phase work limit, so that
  limit does not bound all batch work. Scratch and journal capacity are reused
  without extending a database-reader lifetime.
  A retired name keeps its index reservation after its descriptor is
  collected.
- **Names.** Opt-in publication discovery restores a cold name through one
  bounded lookup and the shared cache, without listing every name at startup.
  The attachment owns the barriers that admit retirement, and an unknown
  outcome fails closed.
- **Locking and growth.** LMDB storage holds an advisory BSD `flock` lock
  and grows its memory map only within an explicit budget.
- **Compaction.** Offline compaction keeps the same owner lock, compares every
  key and value, and installs the copy with a same-directory rename followed
  by a directory sync. Reopening ignores leftover copies.
- **What is tested.** Refusal for lack of copy space, installation failures,
  and process loss are tested on Linux; macOS runs are still required.
  Process-kill tests cover ordinary actors and managed issuance. Managed
  probes also cover control attenuation, revocation, content and reference
  edits, resource moves, leaf deletion, observation registration and
  cancellation, owner closure, and cleanup of terminal publications. None of
  this establishes behavior under hardware power loss.
- **What is measured.** LMDB workload measurements cover collection service
  time, queued reads, atomic managed issuance, control chains, receipt-backed
  edits, and moves and filtered children with cold ancestry. A bounded
  executor workload covers sustained ordinary calls and foreground work during
  collection. Further slices measure returned facets, eight parked calls,
  sustained managed workers, up to 128 held facets, foreign restoration through
  fed bytes, and offline compaction. Admission calibration checks refusal and
  progress of unrelated actors. OS snapshots report whole-process RSS, address
  space, lifetime peak, and faults separately from retained Zig bytes.
- **What is not measured.** Open-loop arrival rates, maximum throughput, and
  real transport latency are not measured.
- **Consumer scope.** C/Rust and IndexedDB implement the fixed-resource
  lifecycle and strong saved-reference fields. General graph editing, collection cursors
  and privileged owner lifecycle remain broader language projections.
- **Continuation scope.** C/Rust receipt handles retain original intent and
  exact targets through confirmed commit and live execution. Applications own
  durable effect receipts and restart recovery. These handles do not persist
  themselves; the production executor stores them with the managed workspace; the
  [Rooms session guide](rooms/session.md) records the production evidence.

### Managed access

Managed access is Loam's layer for resources, grants, and the references that
use and control them. The [usage guide](loam/access.md) gives its memory and
lifetime contract. The
[managed access architecture](planning/loam/access/architecture.md) and the
[Rooms plan](planning/rooms/access-grants.md) own the remaining integration.
The [session guide](rooms/session.md)
records the managed browser module, receipt executor and production recovery evidence. JavaScript mutation handles last only while their
application owner lives; committed receipts survive independently in shared
storage. Callback shutdown retains admission until its exact upstream seat or
name retires. Unknown admission refuses cleanup. A failed browser close retains
the owner for retry; disposal relinquishes that recovery handle.
Managed inboxes must close before their session attachment and Store.
C and Rust implement the
[first resource lifecycle](loam/c-and-rust.md), including its
[IndexedDB execution profile](loam/browser.md). General graph editing,
application-specific management metadata and privileged lifecycle projections
remain outside that consumer profile. Zig owns the semantics.
The fixed-resource profile supports independent Inspect/Issue/Edit/DelegateControl
and lifecycle powers. It includes revision-checked policy/label edits and indexed
direct-child inventory. Persisted kind applicability, dependent control
attenuation and strong saved-reference fields share that profile.
Rooms' bounded workspace/custody/effect codecs preserve exact field coordinates
and original effect authority. Generated browser metadata projects its Rust
declarations. The [dependency queue](planning/rooms/integration.md#shared-prerequisite-and-remaining-order)
records the completed session integration and owns the subsequent recursive resource phase.

**What it hosts today.** The Host attachment hosts managed use and control
endpoints for fixed resources, including held CapTP calls and ordinary
publication restoration.

- Opaque use and control references enforce their selected grants and
  management ceilings. Durable descriptors restore the exact use or control
  role through bounded native operations.
- Deriving from a fixed resource stores the child and its publication in one
  atomic step, and keeps eight retry receipts per source endpoint. Derivation
  reserves actor and publication custody before it writes. An expired receipt
  fails rather than issuing again.
- Structural and content effects can share one owner transaction.
- Use endpoints answer `describe-access` with a scoped snapshot of access; an
  inactive endpoint reports only its status. These snapshots do not deliver
  events or list controls. `describe-control` shows the current management
  powers without revealing owner or ancestor identities, and an unavailable
  control reports only its status.

**Content methods.** A managed content method can disclose a prepared stored
reference, either through an exact handoff or through a runtime facet that
both the invoking grant and the target grant allow. It can replace or remove
strong fields atomically with checked local or foreign recipes.
Explicit live fields retain the exact capability in a bounded shared hosting
scope. Startup advances a separate epoch through the ordinary work lane;
warm lookup checks it and restart refuses old fields. C/Rust project activation
and live declarations. Recursive read interfaces mediate exact returned readers
under original source intent. Production Rooms session workers consume these interfaces.
Registered content graphs prepare owned pages through a bounded lease window
and replace them in the same transaction as managed state and receipts.
Page handles belong to the current callback; page links cannot stand in for
capability fields. Payload updates preserve exact page identity and committed
edges without restoring their targets. Written pages also preserve selected
committed fields without enlivening them; no raw object identity can select a
field outside the prepared graph. Rooms proves the codec graph, publication,
private invitation, direct and IRC acquisition, room uploads and restricted direct file readers;
production consumers use these owners through the [managed session](rooms/session.md).

- A remote publication's lifetime is its remote owner's responsibility. There
  is no distributed transaction.
- Receipt intent and result codecs still require durable capabilities from the
  same attachment. A capability value that was not declared fails closed.
- Descriptor creation can include grant and content updates in the same step.
  Restoring its native reference still allocates.
- An evaluation result cannot be reused to authorize a later content effect.

**Receipts and replay.** Mutations other than derivation share a separate
window of eight results. A replay must match the exact intent and pass
current admission. Terminal cleanup must keep the retired sequence floor.

**Storage.** The current graph and grant ledger reserve their full capacity in
memory, and resource and grant views share evaluation and mutation
preparation with them. The storage participant persists owner headers and
indexed resource and grant records. It loads them in bounded, resumable steps,
and native LMDB evidence covers atomic content, grant, and event updates and
recovery.

**Batched changes.** Several managed changes can join one Store transaction.
Each stage validates against the transaction's own combined state, and the
batch carries one header change per owner. A stale preparation is refused
before submission. The caller that owns the batch aborts it, which discards
the earlier stages; hosted calls do this through their transaction runner.
Volatile and LMDB evidence covers combined commit, abort, and recovery from
an unknown outcome with reopen.

**Controls, issuance, and resources.**

- Control descriptors persist immutable powers, independent revocation, and
  the management dependencies they keep. Attenuation narrows those powers.
- Managed issuance keeps the use and the issuer's control separately,
  including exact receipt recovery.
- Persistent resource moves check ancestry and descendant depth, update child
  indexes atomically, and keep stable IDs.
- Deleting a leaf leaves inactive identity metadata behind, while its content
  follows its own retention.
- Native child cursors filter each candidate through admission, and refuse
  after another commit intervenes.
- Hosted observation uses persisted exact contexts and opaque cursors bound to
  them. Receivers and cancellers run on separate actor lanes.

**Change events.** A resident grant mutation returns its committed change
events. A stored mutation returns proposed events, to publish once the commit
is confirmed.

- The owner keeps 32 committed batches, each of at most 16 grant, resource,
  content, or control effects. A shared batch holds ordered effects for one
  owner transaction. Expired batch edges become collectible.
- Scoped replay keeps cursors unchanged when the only activity is hidden, and
  explicitly resynchronizes when visible changes have expired. Current
  authority bounds every reply, including inactive status.
- Resource and control revisions still invalidate stale operations, while
  exact mutation receipts keep committed results.

**Read and close rules.**

- Host finish preserves Loam child work admitted through a live operation lease;
  Session admission remains independent. Cancellation refuses unstarted source
  preparation and invocation. Submitted writes and unknown outcomes retain their
  custody through settlement and recovery.
- A Store read expires after any commit and refuses during uncertainty. A read
  that consumed proposals also expires after an abort or a missing recovery.
- A storage read cannot close while an append or a resource change borrows it,
  or while submitted read work is still outstanding.
- Iteration cannot release bindings that a prepared effect borrows. Graph and
  ledger destruction refuse while a write is pending.
- Native capability operations keep their source reference, descriptor lease,
  and bounded managed working set. Close refuses while reads are submitted,
  and the Capabilities owner refuses while references or operations are live.
- Under a tight cache budget, release finished operations before admitting new
  work. A descriptor survives final native release only with explicit root or
  containing-edge retention.

**Space and cost.**

- The stored profile never reuses committed resource or grant slots. Its owner
  root keeps active indexed records.
- Bounded maintenance prunes terminal rows and compacts dead descriptors and
  endpoints, without reusing allocation or receipt floors. Owner retirement
  closes admission before cleanup, and tracing reclaims payloads once
  retained custody ends.
- A permanent name reservation costs 58 logical bytes before backend overhead.
- Directory traversal takes up to four page reads plus the target, in addition
  to the owner header.
- Read working sets pin bounded records, and cache buffers reserve the
  configured maximum record size for each slot.
- No managed-owner throughput figure or 500k-scale claim is established.

**Policy limits.** One ledger borrows one stable graph and copies one
immutable policy schema.

- A schema allows at most 64 Boolean permissions and 16 unsigned lower or upper
  bounds. Persisted positive dependencies constrain configured terms and control
  ceilings; partial effect demands do not need prerequisite closure. Up to 16
  persisted kind declarations govern exact, mixed and future-subtree support.
  Effects check the exact target, and containment preserves future support.
  Shared callbacks receive canonical bound-resource context. Recursive Rooms
  interfaces, content facts and exact-target admission remain in the
  [Rooms queue](planning/rooms/integration.md).
- Applications must declare every fact relevant to an effect. Fact relations,
  alternatives, projections, and remote dependencies are not implemented.
- A fresh store needs fresh identities. Neither the graph nor the ledger can
  grow or be restored.
- A revoked record keeps its capacity, including its child count, until the
  ledger is destroyed.
- Selected scopes need bounded copies on issuance and editing. Reads and
  lifecycle changes allocate nothing, and traversal is bounded by the
  configured ancestry limits. Reparenting costs one bounded ancestry walk and
  two subtree traversals.

### Rooms

Limits that belong to the Rooms application, rather than to the library, are
listed in [operating Rooms](../apps/rooms/operating.md#known-limitations).

### Host and ABI

- **Rust finalizer recovery belongs to the owning thread.** If that thread
  exits with refused native releases still pending, their callbacks, allocator
  and other Rust owners remain allocated for the process lifetime. Thread exit
  cannot revoke a native borrow. Finish close and required recovery before
  leaving the thread to reclaim those resources.

- **Enlivening a sturdyref checks the whole locator before anything is sent.**
  Turning a sturdyref back into a live reference either selects an existing
  session or dials a new one. Every tier does this the same way
  (`driver.HostRuntime.enliven`, `glowcap_host_enliven`, and each binding's
  host-level verb), and each checks the sturdyref's peer against the session
  it selects or dials.
  - An accepted plain-TCP session is refused by default. Only the native
    low-level `assertion_only` opt-in proceeds, and it reports that the
    peer was asserted rather than proved.
  - Dial staging is a prepare-then-commit step in the Node. Host parking and
    completion capacity are reserved before a dial action becomes visible.
  - Settled Zig Host actions own their data and capability retains, through
    borrowed pops, retries, and transfer. Projection gives each consumer its
    own retain, and its byte views borrow the action. Closing the source
    session does not retire a capability owned elsewhere.
  - Owning local callbacks can send and tell without an ingress Session.
    Local public vows support Host completion actions and explicit release;
    raw wire listeners and pipelining refuse `SessionlessVow`. Their replies
    use trusted Host-allocator storage, with the shared Value depth limit.
    `Host.Call` retains its explicit fixed reply capacity.
  - `Host.enlivenCapability` tracks its completion apart from the action
    queue. Destroying the observation detaches it, while a shared dial stays
    Host work.
  - This API does not prove that a supplied sturdyref names some other
    capability you already hold.
- **The public API and ABI are not stable.** There are no release tags or
  compatibility guarantees yet. Pin a commit when consuming the package.

Archive discovery and packaging are documented in the
[packaging guide](../bindings/PACKAGING.md#finding-the-archives). Windows release
assets are not published.

## Protocol and interop

- **Locator hint count is an implementation resource bound, not an OCapN wire
  maximum.** glowcap accepts at most 32 entries in one locator hint map across
  owned values, Syrup, Cap'n Proto, and URI parsing. URI parsing refuses the
  33rd entry before decoding or allocating it. Unknown names within the bound
  remain preserved and ignored unless a negotiated feature owns their meaning.

- **Keyed TCP and keyed relay prove no peer.** Matching the hello's key claim
  rejects an accidental mismatch, but the cleartext channel reports
  `unauthenticated`. A fresh session key limits honest reconnects; it does not
  stop a captured hello from being replayed. iroh, WebRTC signaling, and
  `noise-tcp` / `noise-relay` supply connection-scoped identity proof
  (ADR-0107). `BlockingSession` refuses Noise symbols.
  An embedder with its own authenticated channel records the same fact through
  `glowcap_host_session_bind_verified_channel_key`.
- **OCapN Null is absent.** Unknown Syrup records remain tagged values instead.
  The encoding is an open upstream question
  ([watch](upstream-watch.md#ocapn-null)).
- **Only the negotiated features are accepted.** glowcap supports
  `pipelining`, `handoff`, `wire_delta`, `sturdyref`, `untag`, and the
  ADR-0125 `multi_location` bit. Identity-route vocabulary is opt-in: an `id`
  locator is refused before send or apply unless the settled session is
  `glowcap-next` with that bit. Host-level `id` sturdyrefs also require the
  Host to opt into that same feature and then match only authenticated same-key
  sessions or staged concrete `via` routes. Feature names from older CapTP
  designs (streams, equality queries, a `draining` lifecycle) exist in neither
  the pinned draft nor Goblins, so their absence here is not an interop gap.
- **Only the Node chooses among a route bundle's routes.** A route bundle is
  the list of paths in an `alt-locators` hint or an `id` locator's `via` hint
  ([multi-home peers](https://jimisaacs.github.io/glowcap/multihome/),
  ADR-0125).
  - The Node uses bundles to schedule handoff and redeem, and to lower a
    signed give for `id`. A give keeps its route vocabulary only when both the
    recipient's and the exporter's sessions negotiated it. A
    baseline-compatible override still works. Otherwise the give falls back to
    the concrete location the exporter claimed on its session.
  - The generic single-path dial planner and the Host open path refuse a
    bundle transport as a physical session.
  - Host `fetchAt(locator, name)` and sturdyref enlivenment send their lookup
    through the Node's pending-dial path. That is the one place that resolves
    `id` into a concrete transport, so an application never has to choose a
    CapTP profile.
  - The declared `via` order ranks a window of two attempts. The first proved
    completion wins, and the losing attempts are cancelled before their
    executor state is retired.
  - A weak fallback serves only the ticket that authorized it. It is cached as
    the exporter's session only when its channel independently proves the
    bundle's durable identity.
  - Route advice discovered along the way becomes available to later gives
    only after one withdrawal succeeds.
  - Rooms combines its active listeners into an identity route and publishes
    durable rooms between directories through the ordinary handoff path. A
    Rooms Host also writes room and steward sturdyrefs with the identity route
    it advertises on the asking session. Rooms reaches the directory
    publication through `fetchAt`, so a browser or native binding can
    reconnect through that route and try its alternatives without changing
    room authority. Ordinary member introductions still pass along the
    member's signed session location.
- **Handoff signatures always use Syrup.** That signing domain does not change
  when the surrounding session uses Cap'n Proto.
- **Pinned Goblins can reject handoffs from independent receivers.** Goblins
  records an accepted `handoff-count` on the Gifter-Exporter session, although
  the certificate assigns that count to the Receiver-Exporter session. Two
  independent receivers can therefore each correctly begin at zero while the
  second is rejected against the first receiver's retained count. Glowcap keeps
  one V1 issuance cursor for replacement sessions inside a Node, which handles
  reconnects but cannot coordinate independent recipients. The live
  `goblins-rooms-matrix-iroh` step reproduces the rejection; the source-level
  mismatch is tracked in
  [upstream watch](upstream-watch.md#handoff-count-across-independent-receiver-sessions).
- **Remote equality does not cross unrelated sessions.** A proved exporter
  session gives direct and handed-off references one Host identity. Two
  independently established sessions without durable peer proof carry no
  stable target id from which glowcap could infer that identity, so their
  targets remain unrelated even when their locators look alike.

Cap'n Proto is a glowcap-to-glowcap format. The project does not publish a
fixed speed ratio between the codecs; `zig build bench-codec` measures the
current workload.

[Community review](community-review.md) is the precise outside-peer coverage
and specification-gap record.

## Browser reachability

A browser is a full peer after it has a channel, but it cannot open a listening
socket. Cold dial works through a relay that holds an inbound socket under the
browser's keyed identity. A `rendezvous-relay` locator hint carries the route,
so the dialer need not share the registrant's deployment configuration. Raw
`keyed-relay` reaches the peer but proves nothing and leaves frames cleartext.
WebRTC supplies encryption and signaling authority. `noise-relay` seals the
CapTP stream end to end (ADR-0107).

`zig build bindings-keyed-relay-rendezvous` proves Deno, Python, Rust, Racket,
and the native CLI honor locator-carried routes over a local fallback that is
not running. `zig build zig-keyed-relay-register` proves the CLI registration
half. The relay provider archive owns both `keyed-relay` and `noise-relay`,
including native dial and registration through the generic driver. The
managed browser connector carries both profiles, while the byte-fed Host owns
Noise sealing. `zig build bindings-noise-relay-listen` has every native
event-loop binding register, advertise, accept, and serve through its managed
listener. `zig build web-peer-test` drives the browser path in Chromium and
has the native CLI call an object hosted in the page over `noise-relay`.

`zig build bindings-native-wss-relay` additionally runs every native binding
against one local WSS authority. Each binding observes exact hostname and
unknown-authority refusals from the shared C provider, then completes a call
and joins the session close barrier. The binding rows prove projection and
foreign linkage; the Zig TLS scenarios remain the semantic authority.

That proof uses a loopback `wss://` relay and a fixture authority copied into
the native process. The optional native Zig relay module and the C relay
archive compose a pollable WSS carrier with immutable
system or copied-PEM trust, SNI, and hostname verification. The completion-loop
relay path drives the same neutral TLS transform below the existing WebSocket
machine without a thread or second framing pass. Its deterministic engine check
proves transition, refusal, cleanup, and footprint behavior. `zig build
native-tls-build` uses real local certificate chains for both carriers. It
proves success, unknown and expired authorities, hostname and SNI refusal,
peer alerts, malformed TLS, and authenticated truncation without
`close_notify`. It also proves completion delivery of the terminal TLS close
record and a hostname open through its asynchronous resolver and bounded
eight-seat address race. No public-certificate relay check yet proves a native
peer reaching a browser through a deployed secure route; the recurring proof
uses a local authority so expiry, hostname, and plaintext observation stay
deterministic.

Rooms gives browser WebRTC peers public STUN by default, so ordinary NATs can
produce server-reflexive candidates. A deployment can configure an HTTPS TURN
credential issuer for symmetric NATs and restrictive firewalls: the Rooms
server retains the issuer bearer token and publishes bounded, short-lived
credentials to each new browser connection. With no issuer configured, the
posture remains STUN-only and those networks can still leave no candidate pair.
TURN is a relay under the end-to-end DTLS channel, not an automatic switch to
the browser's separately selectable **Through the room relay** transport.
Native WebRTC embeddings pass the same provider-neutral ICE facts as fixed C
records: URLs plus optional username/password credentials. They still own any
credential API, expiry, and refresh policy above the transport.

`glowcap apps rooms session` uses the shared Rust session, with iroh, TCP, onion,
and relay routes supplied by its host providers, not WebRTC. A browser that
wants host-initiated DMs selects **Through the room relay**; the session also
needs the relay URL, supplied explicitly or derived from its HTTP bootstrap.

The session's local inbox holds 4096 unacknowledged events within a 16 MiB
journal. Pressure or failed persistence retires the observer, not the session,
and reports a gap requiring explicit acceptance before observation resumes.
Its file events contain descriptions; local control does not transfer bytes. The agent
harness must keep a live consumer to wake a model; the session alone keeps
receiving but cannot invoke a model after its turn ends.

A room stores posted files under its room and server ceilings. A direct-message sender has no server
in its path, so it hosts each blob until the recipient pulls it. The Rust application's
`files::sources` owner retains at most eight files per message, 128 live sources,
and 64 MiB across direct conversations. It allows 32 simultaneous reads.
Pressure expires the oldest source with no active read. If the session ends or
the ceiling expires a file first, the recipient keeps the message
metadata but cannot fetch bytes it never received.
