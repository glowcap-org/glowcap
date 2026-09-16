# Architecture

These names are glowcap's CapTP product:

| Name | Meaning |
| --- | --- |
| Host | Multi-session CapTP product: one identity, one Vat, one Node, and the sessions under them. An OS hostname is a different word. |
| Node | Host-owned I/O-free identity, routing state, and handoff router (`engine.Node`). |
| Vat | Actor container and turn loop. |
| Port | One actor-layer session projection and ingress into the Vat (`actors.Port`), inside the Host's serving shell. A TCP port is a different word; `GlowcapHostSession` is the Host-registered shell. |
| Peer | Local CapTP state machine for that session. In prose, "peer" still means the remote party. |
| Session | Application-facing one-partner CapTP conversation, backed by a Host-registered shell (`driver_core.HostSession` / `GlowcapHostSession`) and one byte connection. |

Most Zig programs start with `driver.Session`: connect or listen, then fetch,
call, publish, and redeem a live reference passed to a third party (a handoff)
as ordinary operations. That Session is a view onto one connection owned by a
`driver.HostRuntime`. Each runtime realizes one independent multi-session CapTP
Host, and a process may own many. Every Host has one Node, one Vat, and one
Port-plus-Peer per live session:

```text
process
└── HostRuntime(s)
    └── Host
        ├── one Node: identity, routing, advertised locators
        ├── one Vat: actors, state, turns
        └── sessions
            └── Port: that session's projection and ingress
                └── Peer: that session's CapTP state
```

Creating another Host creates another Node and Vat, so one process can serve
multiple independent CapTP products. The layers below separate protocol decisions
from encoding, I/O, and application scheduling.

```text
application
    driver.Session / driver.HostRuntime
    actors.Vat
    engine.Peer
    session
    codec
    model
    foundation

network I/O enters through net and the driver
```

If you are choosing an API, start with the product names and the Host diagram
above. If you are adding a codec, transport, or binding, start from the layer
table and work upward.

## The protocol core

The core is synchronous and has no I/O. A caller gives `engine.Peer` an inbound
frame, asks it to advance, and takes events and outbound frames back. The peer
does not open sockets, start tasks, or choose a scheduler.

| Layer | Responsibility |
| --- | --- |
| `foundation` | Owned frames, borrowed frame views, limits, crypto, the sealed byte channel both stream tiers compose (ADR-0107), and shared utilities. |
| `model` | Values and messages that can cross an OCapN session. |
| `codec` | Syrup and Cap'n Proto framing and encoding. |
| `session` | Imports, exports, answers, promises, handoff, and protocol validation. |
| `engine` | The caller-driven state machine around one session. |

Route lists have one owner (`model.route_bundle`). The identity rule sits on
top (`session.id_route`): every `id` route must prove the durable key the
locator names. `engine.Node` only schedules bundles those layers already
admitted; it does not treat `id` as a physical transport.

Session tables decide whether a reference is valid; a codec only encodes and
decodes that decision, so changing codecs cannot mint authority or change CapTP
behavior.

The module graph holds that split. Protocol modules cannot import adapters,
and Syrup and Cap'n Proto cannot import one another. The architecture check also
rejects `std.Io`, threads, and platform calls in the portable core
([ADR-0040](decisions/adr/ADR-0040-layer-modules-as-import-law.md),
[ADR-0048](decisions/adr/ADR-0048-codec-sibling-isolation.md)).

## From a peer to an application

`engine.Peer` is useful when the application already owns an event loop or is
embedding glowcap behind another runtime. Most Zig programs start higher.

| API | Use it when |
| --- | --- |
| `driver.Session` | You want one application-facing session with blocking calls, backed by a connection its `driver.HostRuntime` owns. Handoffs are redeemed before a call returns. |
| `driver.HostRuntime` | You want one identity across several file-descriptor-backed sessions. |
| `driver.BlockingSession` | You own the connection and buffers, or your transport has no pollable descriptor (an in-process pipe, or a WebRTC peer you already opened). Values are actor-layer references rather than opaque host capabilities. A call may return a handoff for you to redeem. |
| `driver_core.Host` | Your runtime feeds bytes and drains actions without letting glowcap own I/O. Native bindings hand this Host to the driver; the browser package feeds it itself. |
| `driver.Bridge` | You are connecting `driver_core.Host` to a completion loop for many sessions. |

Consumers reach Host through `driver.core`. The files under `host/` are
implementation; they are not a second public API.

The actor layer sits between the protocol peer and these application APIs.
`actors.Vat` hosts local objects, turns incoming calls into actor turns, and
settles their results. It also provides attenuation, revocation, and optional
snapshots. A snapshot covers local actor state only; it never rewinds a network
session. Actor state can use `loam.collections.PersistentMap`, so changing one
entry does not copy the whole map
([ADR-0060](decisions/adr/ADR-0060-vat-local-time-travel.md),
[ADR-0061](decisions/adr/ADR-0061-persistent-collections-module.md)).

Local eventual-sends enter queues keyed by *ingress*: which session the work
came from. The Vat measures the owned-clone charge before mutation, applies
per-ingress turn and byte limits, and rotates runnable ingresses one turn at a
time while keeping FIFO within each one. Queue chunks reclaim independently,
with at most one bounded spare for the whole Vat. The actor layer owns this
admission and scheduling; the standard Host owns one Vat, and each session Port
supplies its ingress identity but does not own a queue
([ADR-0099](decisions/adr/ADR-0099-shared-vat-scheduling.md)).

## Resource models

[Loam](loam.md) provides immutable collections, record storage, transactions,
and bounded residency through `glowcap.loam`. The `collections` leaf has no
storage dependency. The `records` module owns storage identities and checked
Syrup envelopes; `core` consumes them for transaction and lease state. Optional
LMDB execution and the volatile backend use the same batch validator. Native
I/O runs through the embedding's executor, with no new Host or scheduler.
The same transaction core owns incremental tracing and insertion barriers.
Stored marks and queue entries keep traversal out of the actor working set;
bounded live retention and pinned snapshots protect objects during sweep.

The `hosting` module attaches record-backed actors to the existing Vat/Host.
It owns bounded pending calls and lazy local capability restoration; ordinary
Host promises carry commit-gated replies. It adds no I/O or scheduling loop.
The included `access` module supplies resource authority and participates in
Store transactions. Hosted-facet integration remains in the
[Loam design](planning/loam/architecture.md).
Rooms' existing durability remains application-owned until that integration.

`glowcap.loam.access.core` owns resource graphs, scope evaluation, runtime policy
algebra, and local grant lifecycle. Resource names include owner identity and
generation; owned containment is bounded and acyclic. Exact selections and
scopes over future descendants have different narrowing rules. Grant edits
stay within immutable ceilings; effective access intersects every current
ancestor and refuses paused or revoked paths. Prepared writes reserve graph
scope and keep staged grants invisible until exact completion; uncertain
outcomes fence protected access.

Native opaque use and control references carry authority over a selected grant.
Controls constrain edits with separate lifecycle powers and management ceilings.
Their methods use the same evaluator and prepared-write implementation. The
separate build module imports no protocol or runtime layer and creates no actor
or Host.
[ADR-0153](decisions/adr/ADR-0153-access-resource-core.md) records resource
structure; [ADR-0154](decisions/adr/ADR-0154-access-local-grant-lifecycle.md)
records the grant model. [ADR-0155](decisions/adr/ADR-0155-access-prepared-grant-writes.md)
records preparation and storage completion;
[ADR-0156](decisions/adr/ADR-0156-access-native-grant-capabilities.md) records native
capability custody. [Known limitations](boundaries.md#api-gaps)
names the remaining application and foreign-binding integration. The
[storage plan](planning/loam/access/storage.md) places database I/O in optional
adapters and keeps record loading, memory budgets, and authority decisions
in shared Zig code. Loam owns shared persistence; managed access supplies resource and
grant semantics as a transaction participant. `loam_access_records` encodes
owners, sparse identity directories, resources, grants, and change events through
Syrup. `loam_access_core` shares revision-checked evaluation and mutation planning
between resident and stored models. `loam_access_storage` supplies bounded,
resumable record loading through Loam leases and stages managed changes in the
caller's Store transaction. Its owner header persists the policy descriptor,
identity counters, logical revisions, directory roots, and latest grant event.
[ADR-0167](decisions/adr/ADR-0167-managed-owner-storage.md) defines this storage
profile and its costs; the existing Store owns commit and recovery.

`access.storage.Capabilities` restores opaque native references from committed
use/control descriptors. Each operation owns a bounded Read and checks current
authority through the shared evaluator. Shared control rules enforce the same
management ceiling and lifecycle powers in resident and stored bindings.
Descriptors and derived grants join the caller's Store transaction. Loam's live
retention protects held references without pinning their records.
[ADR-0168](decisions/adr/ADR-0168-durable-managed-capability-bindings.md) defines
operation custody and restoration. `access.hosting.Service` supplies managed
working sets through the existing durable attachment's preparation seam. Its
fixed-resource use endpoints authorize committed content before invocation;
control endpoints stage permitted edits in the attachment's transaction.
Derivation stages the child grant, endpoint, publication, and bounded receipt
together. Host publication reservations stay hidden until confirmed commit;
top-level reply materialization reserves custody outside the Vat callback.
The same Host owns publication, Vat dispatch, recovery, and reply settlement.
`loam_access_hosting` depends on the storage and hosting modules; neither
lower module depends on managed hosting.
[ADR-0169](decisions/adr/ADR-0169-managed-host-turns.md) defines these lifetimes.
[ADR-0170](decisions/adr/ADR-0170-durable-facet-derivation.md) defines derivation
sequences, receipt retention, and publication activation.
Access descriptions share the admission evaluator and project only the held
endpoint's current access. [ADR-0171](decisions/adr/ADR-0171-scoped-access-descriptions.md)
defines their disclosure and snapshot contract.
[ADR-0172](decisions/adr/ADR-0172-explicit-disclosure-of-returned-capabilities.md)
defines disclosed replies: a managed content method hands over a stored reference
field only through a declared exact disclosure, and an undeclared capability value
fails closed.
[ADR-0173](decisions/adr/ADR-0173-dependent-returned-capabilities-and-reference-edits.md)
adds runtime facets that require both invoking and target authority, plus
transactional replacement and removal of local strong reference fields.

The Loam facade exposes managed access without requiring resource state for ordinary
objects. Its persistence core remains independent of managed access, Host, and CapTP
session state; optional integration connects them. The
[Loam API](planning/loam/api.md) separates record schemas, storage encoding,
reference restoration, and wire codecs. The planned libglowcap_loam companion
includes managed access, with no separate resource-management archive.

## Transports and connection loops

The `net` layer turns a byte stream into complete frames. Each byte-stream
message is a bare negotiated-codec frame inside one outer Syrup byte string;
the outer length supplies the boundary and the inner codec must consume the
body exactly. A transport that already preserves message boundaries hands bare
frames to the whole-frame API instead. The transport implementations are iroh,
WebRTC, Noise-sealed TCP, Noise-sealed relay, onion, keyed TCP, keyed relay,
plain TCP, and in-process pipes
([ADR-0110](decisions/adr/ADR-0110-byte-stream-message-envelope.md)).

Inbound frames have a size limit. A frame larger than the current read buffer
uses one bounded spill buffer rather than forcing every connection to retain a
maximum-sized buffer. Read buffers are pooled across the completion loop.
Outbound backpressure stops reads when queued reply bytes cross their limit.

The simple blocking pump runs on one fiber. Applications that must keep reading
while a partner streams use a completion loop (TCP, iroh, onion, or keyed-relay
outbound). Session and HostRuntime follow that socket path. WebRTC has no
socket to poll, so it joins a Host through a completion backend once signaling
is configured (`zig build webrtc-loop`; redeem via
`zig build webrtc-bridge-redeem`). A bare locator without that authority still
refuses. Crossed connections, where both peers dial at once, are resolved by
the host because the choice depends on peer identity rather than transport
mechanics.

The native TCP completion backend binds loopback by default. A service that
accepts from other hosts constructs `net.Backend` with
`initWithListenerIp4`, then gives that backend to `TcpLoop.initWithBackend`.
The backend reports the kernel-bound IPv4 address and resolved port together;
the embedding remains responsible for publishing a dialable locator when it
binds a wildcard address.

On Linux, `net.Backend` tries io_uring first. If the kernel or host policy
cannot support glowcap's io_uring backend, it uses epoll with the same bounded
pool and completion ownership rules. Applications can call
`net.tcpBackendStatus(&loop)` after constructing a TCP, onion, keyed-relay,
Noise, or iroh loop. A non-null `fallback_reason` explains why epoll was
selected. On an iroh loop, this names the wrapped Linux platform layer, not the
iroh transport. The many-sessions example and Rooms peer report this through
their own diagnostic streams. The library does not print it because the
embedding owns its logs and operator interface. The 500,000-session measurement
used io_uring. Epoll passes the completion-loop behavior tests but has no
equivalent scale result.
[ADR-0152](decisions/adr/ADR-0152-linux-completion-backend-selection.md) records
the selection boundary and evidence.

[Known limitations](boundaries.md#transports-and-peer-identity) compares the
security and reachability of the transports.

## Resource knobs

Protocol admission, shared read memory, outbound backpressure, and local-turn
amplification are separate decisions:

| Option | What it limits | Default |
| --- | --- | --- |
| `driver.HostRuntime.Options.frame_cap` | Protocol admission for sessions the owning face creates. | 1 MiB |
| `driver.HostRuntime.Options.wire_buffer_bytes` / `GlowcapDriverOptions.wire_buffer_bytes` | Each stream read/write buffer and multiplexed-resident read staging buffer. | 16 KiB |
| `driver.HostRuntime.Options.max_pending_opens` / `GlowcapDriverOptions.max_pending_opens` | Transport connects and CapTP handshakes admitted at once, across dial, accept, adoption, and redeem. | 256 |
| `driver.HostRuntime.Options.listener_setup` / `GlowcapDriverOptions.listener_setup_ms` | Maximum time one admitted listener construction may remain pending before its terminal failure. | 10 seconds |
| `driver_core.Host.Options.limits.max_frame_bytes` | Protocol admission for every peer the byte-fed host creates. | 1 MiB |
| `SessionLimits.max_retained_sent_answer_bytes` / `GlowcapSessionLimitOptions.max_retained_sent_answer_bytes` | Owned resolutions retained by sent inbound-answer rows after they leave transient flow accounting. | 16 MiB per session |
| `driver_core.Host.Options.local_turn_budget` / `glowcap_host_new(... local_turn_budget ...)` | Local actor turns one session may amplify into during a drive before the Host condemns that session. | Unbounded (`null` in Zig, `0` in C); loop demos and benches opt into `driver.core.default_loop_local_turn_budget` (4096). |
| Raw transport `max_frame_bytes` / `maxFrameBytes` / `max-frame` default | Admission for direct blocking frame-shuttle handles before a Host owns the session. | `GLOWCAP_RAW_TRANSPORT_DEFAULT_FRAME_CAP` (4 KiB) |
| `net.completion.BackendOptions.read_buffer_bytes` | Each buffer in the loop-wide shared read pool. | 16 KiB |
| `net.completion.Options.outbound_high_water_bytes` | Pending outbound bytes before one connection's reads park. | 64 KiB |
| `net.relay.RelayOptions.send_staging_bytes` | One retained masked WebSocket send chunk, including its header. | 4 KiB |

TLS and relay connection footprints, copy-shape pins, and `close_notify`
delivery live in [known limitations](boundaries.md#browser-reachability) and
the [ladder](ladder.md).

The completion loop can change admission, pool memory, outbound slack, and
transport staging independently. `initWithBackendOptions` tunes a backend the
loop builds; `initWithBackend` accepts only runtime policy because the supplied
backend already owns its resource configuration.

`driver.DialRetry` adds reconnect policy above the loop. It classifies
dial failures, opens a new CapTP session, and applies its own discovery budget.
The protocol core has no reconnect policy.

## Session tables

CapTP names imports, exports, and answers with integer positions. glowcap keeps
each namespace in its own hash table:

- direct lookup stays constant-time;
- a sparse number from an untrusted peer cannot force a giant array;
- garbage collection removes an answer row before its position can be reused;
- locally minted outbound answers fail closed in `session/answers/pipeline.zig`
  before their cursor can wrap;
- imports retain a separate cap because the remote peer chooses their count.

Sent inbound-answer rows have both cardinality and cumulative owned-byte caps.
Their semantic resolutions cannot be evicted without changing pipelining
authority, so overflow fails loud as `resource_exhausted`; answer GC and local
promise retirement release the exact durable charge (ADR-0121).

A near reference, promise, and answer share one internal slot representation,
and the codec derives the corresponding wire descriptor only when it renders a
frame. A far import is always the remote-mint value of its own position, so
its row keeps only its retain counts. One count is how many references the
partner's mentions granted. The other is how many of those the session itself
will release, beside the fire, callback, or shortening closure that spends
them. This keeps
pipelining, settlement, and handoff on the same state, and it keeps an
application's release from spending a retain the session still needs
([ADR-0146](decisions/adr/ADR-0146-session-held-import-retains.md)).

Recursive values are limited by `SessionLimits.max_nesting_depth`. Session
state also decides which messages are legal while negotiating, open, or closed.
An invalid transition is refused before it can mutate a table.

glowcap never reuses positions it allocates itself. A partner may reuse an
import position after release. The final decrement removes every sturdyref
cache entry and clears the import row's routing generation. An old host route
then fails closed even if its map row is reclaimed after the partner reuses the
position.

## Frame ownership and copies

`Frame` owns its bytes. `FrameView` borrows bytes for one bounded call. Session
state may never retain memory borrowed from an inbound frame.

The codec follows the same rule. `decodeBody` projects a borrowed view;
`decodeOwned` creates an owned value when data must survive the frame. Syrup
frames are byte-aligned, while Cap'n Proto frames require eight-byte alignment.
`FrameShape` keeps that difference visible.

Production code moves frames by ownership:

- `Frame.initOwned` and `Frame.initExternal` adopt existing storage;
- `Frame.view` borrows without allocating;
- `Peer.feedOwned` and `Peer.step` move an owned frame into an event;
- `Peer.recvBorrowed` makes the one copy required to retain borrowed input;
- `Peer.sendCopying` names its queueing copy in the API.

A delivered call to a live export makes exactly one owned-frame allocation.
The allocation and footprint checks under `test/engine/` protect that budget.
Test fixtures have their own copying helper; production `Frame` has no general
copy constructor.

## C ABI and bindings

The C ABI uses opaque handles, fixed-width result codes, `ptr + len` views,
caller-supplied callback contexts, and explicit release. Allocation goes
through `GlowcapContext`. Peer locators and sturdyrefs stay distinct values at
every public surface: a locator carries transport, designator, and hints; a
sturdyref embeds a peer locator plus swiss bytes.

An owned `GlowcapManagedFrame` moves the native frame owner into opaque words
inside the caller's descriptor. Producing, probing, and releasing that
descriptor allocate no metadata and copy no frame bytes (ADR-0122).

Lifecycle, admission, provider composition, protocol state, and failure
classification remain in `driver_core` or `driver`. The C layer validates ABI
layout and lossless representation, marshals values, owns opaque-handle and
event-delivery storage, and projects the Zig result. Bindings add host-language
resource idioms and drive effects to the native completion barrier; they do not
retain policy for a background worker or maintain a second state machine.

Returned failures remain in ordinary control flow. When the last caller or
close barrier that could receive a failure has gone, the `diagnostics` layer
normalizes it into a typed record in the owning `GlowcapContext` journal. The C
ABI only projects that record and the Context-local lifecycle IDs that name its
owners. Its per-thread `last_error`, a session's retained
abort, and the live protocol trace remain separate because each describes a
different fact. [ADR-0115](decisions/adr/ADR-0115-structured-diagnostic-waist.md)
owns this boundary.

There is no umbrella library. A C program links the shared OCapN vocabulary and
only the Host, driver, and transport archives it needs. [The C
guide](consuming-from-c.md) has the archive table, build commands, provider
install, and a complete program.

Every separately loaded archive exposes a reflected callable/constant/layout
fingerprint, including the core, Host, and driver. Binding-projected rows in
the canonical struct manifests also generate the Rust, TypeScript, Python, and
Racket layout expectations; C-only rows remain part of archive identity.
Native binding loaders compare every archive before an ordinary call;
implementation-only edits do not perturb the contract (ADR-0123).

Native bindings load `libglowcap_host` and `libglowcap_driver`. The driver
takes an idle Host and runs the loop. The binding waits on one readiness
descriptor, arms one runtime-native timer from
`glowcap_driver_step_wait_ms`, calls `glowcap_driver_step`, and drains one
event queue. The driver remains the sole authority for which pending operation
owns the nearest deadline; a binding only projects that duration into its
scheduler. The browser package and any embedder that already owns I/O still
drive the Host themselves: feed bytes, pump and drain, take outbound frames.
glowcap does not create a background runtime inside Python, Racket, Rust, or
TypeScript.

`libglowcap_driver` starts with zero transports; the application installs
provider packages through `glowcap_transport_provider.h`. The TCP archive supplies `noise-tcp`, `keyed-tcp`,
and testing `tcp`; the relay archive supplies `keyed-relay` and `noise-relay`;
onion, iroh, and WebRTC ship as separate archives the driver consumes without
naming their members. Listener ids remain the acceptance routing key through
every binding. The driver owns each listener's canonical public locator. A
provider also owns comparison of its complete effective configuration; an
equivalent package registration is idempotent, while a conflicting package is
refused. Bindings keep no parallel provider or credential registry. A
provider may separately expose opaque local restoration bytes through a
size-query/caller-buffer callback; those bytes never enter the locator, and
only the provider package interprets them (the onion package calls them a Tor
service key). Host and session progress occurs only inside a step call on the
one thread that drives the loop. A provider may use transport-owned workers,
but it reports their results through the common readiness seam and never calls
the Host from those workers.

After `glowcap_driver_take_host` succeeds, adoption is durable even when a later
bind fails: the supplied Host remains a valid loop-backed Host for another
attempt. Bindings tear down only loops and Hosts they minted themselves.

## Other entry points

The installable `glowcap` command is an application of the public library, not
another protocol layer. It owns terminal behavior, identity files, MCP stdio,
and room presence. [The CLI guide](cli.md) covers it.

First-party applications live under [`apps/`](../apps/). Compilable teaching
programs live under [`examples/`](../examples/README.md). Build checks and code
generators live under [`tools/`](../tools/README.md).

Rooms' [Rust application boundary](decisions/adr/ADR-0147-rooms-rust-application-boundary.md)
places the shared Rooms protocol and application policy above the Zig Host,
which continues to own CapTP. Rendering and platform I/O remain in adapters.
The running presentation remains TypeScript; recurring Rooms gates record the
implementation evidence.

CapTP and OCapN claims are checked against the upstream OCapN suite, live Goblins
peers, and the in-tree reference corpus. [Community review](community-review.md)
states exactly what that evidence covers.
