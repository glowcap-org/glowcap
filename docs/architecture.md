# Architecture

These names come up throughout:

| Name | Meaning |
| --- | --- |
| Host | Multi-session CapTP product: one identity, one Vat, one Node, and the sessions under them. An OS hostname is a different word. |
| Node | Host-owned I/O-free identity, routing state, and handoff router (`engine.Node`). |
| Vat | Actor container and turn loop. |
| Port | One actor-layer session projection and ingress into the Vat (`actors.Port`), inside the Host's serving shell. A TCP port is a different word. `GlowcapHostSession` is the Host-registered shell. |
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

The layers below separate protocol decisions from encoding, I/O, and
application scheduling.

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
admitted. It does not treat `id` as a physical transport.

Session tables decide whether a reference is valid. A codec only encodes and
decodes that decision, so changing codecs cannot mint authority or change CapTP
behavior.

The module graph holds that split. Protocol modules cannot import adapters,
and Syrup and Cap'n Proto cannot import one another. The architecture check also
rejects `std.Io`, threads, and platform calls in the portable core
([ADR-0040](decisions/adr/ADR-0040-layer-modules-as-import-law.md),
[ADR-0048](decisions/adr/ADR-0048-codec-sibling-isolation.md)).

## From a peer to an application

Use `engine.Peer` directly when the application already owns an event loop or
embeds glowcap behind another runtime.

| API | Use it when |
| --- | --- |
| `driver.Session` | You want one application-facing session with blocking calls, backed by a connection its `driver.HostRuntime` owns. Handoffs are redeemed before a call returns. A transport with no pollable descriptor joins as a multiplexed resident. |
| `driver.HostRuntime` | You want one identity across several sessions over the transports it serves. |
| `driver_core.Host` | Your runtime feeds bytes and drains actions without letting glowcap own I/O. Native bindings hand this Host to the driver. The browser package feeds it itself. |

Consumers reach Host through `driver.core`. The files under `host/` are
implementation. They are not a second public API.

The actor layer sits between the protocol peer and these application APIs.
`actors.Vat` hosts local objects, turns incoming calls into actor turns, and
settles their results. It also provides attenuation, revocation, and optional
snapshots. A snapshot covers local actor state only. It never rewinds a network
session. Actor state can use `loam.collections.PersistentMap`, so changing one
entry does not copy the whole map
([ADR-0060](decisions/adr/ADR-0060-vat-local-time-travel.md),
[ADR-0061](decisions/adr/ADR-0061-persistent-collections-module.md)).

Local eventual sends go into queues keyed by *ingress*, meaning the session the
work came from. Before queuing, the Vat measures what the owned copy will cost.
It applies turn and byte limits per ingress, and it takes one turn at a time
from each runnable ingress in rotation, keeping first-in-first-out order within
each one. Queue chunks are reclaimed independently, and the whole Vat keeps at
most one bounded spare chunk. The actor layer owns this
admission and scheduling. The standard Host owns one Vat, and each session Port
supplies its ingress identity but does not own a queue
([ADR-0099](decisions/adr/ADR-0099-shared-vat-scheduling.md)).

## Resource models

[Loam](loam.md) provides immutable collections, record storage,
transactions, and bounded residency through `glowcap.loam`. It does its LMDB
I/O through the embedding's executor and adds no Host or scheduler of its own.

### Loam's modules

- **`collections`** holds the immutable collections and has no storage
  dependency.
- **`records`** owns storage identities and checked Syrup envelopes.
- **`core`** builds transaction and lease state on top of `records`. The
  optional LMDB backend and the volatile backend share its batch validator.
  The same core owns incremental tracing and its insertion barriers. Marks and
  queue entries are stored, so traversal stays out of the actor working set,
  and bounded live retention and pinned snapshots protect objects during a
  sweep.
- **`hosting`** attaches record-backed actors to the existing Vat and Host. It
  owns bounded pending calls and lazy restoration of local capabilities, and
  ordinary Host promises carry the replies that wait for commit. It adds no
  I/O or scheduling loop.
- **`access`** supplies resource authority and joins Store transactions. It is
  described below.

Loam's persistence core does not depend on managed access, the Host, or CapTP
session state. Optional integration modules connect them. The Loam facade
offers managed access without requiring resource state for ordinary objects.
Rooms stores its managed session through Loam on LMDB and IndexedDB. The
[session guide](rooms/session.md) owns its custody and recovery contract.
The [Loam API](loam/api.md) separates record schemas, storage encoding,
reference restoration, and wire codecs.

### Managed access

Managed access is Loam's layer for resources, grants, and the references that
use and control them. Its modules stack so each lower one works alone:

- **`loam_access_core`** evaluates resource graphs, scopes, and grants. It
  imports no protocol or runtime layer and creates no actor or Host.
- **`loam_access_records`** encodes owners, resources, grants, and change
  events in Syrup.
- **`loam_access_storage`** loads records in bounded steps and stages changes
  in the caller's Store transaction.
- **`loam_access_hosting`** serves managed references through the durable
  attachment.

The [managed access architecture](loam/access-architecture.md) owns the
contract and its decision records. [Known limitations](boundaries.md#api-gaps)
names the integration that remains for applications and foreign bindings.

## Transports and connection loops

The `net` layer turns a byte stream into complete frames. Each byte-stream
message is a bare negotiated-codec frame inside one outer Syrup byte string.
The outer length supplies the boundary and the inner codec must consume the
body exactly. A transport that already preserves message boundaries hands bare
frames to the whole-frame API instead. The transport implementations are iroh,
WebRTC, Noise-sealed TCP, Noise-sealed relay, onion, keyed TCP, keyed relay,
plain TCP, and in-process pipes
([ADR-0110](decisions/adr/ADR-0110-byte-stream-message-envelope.md)).

Inbound frames have a size limit. A frame larger than the current read buffer
uses one bounded spill buffer, so no connection retains a maximum-sized buffer.
Read buffers are pooled across each completion resident. Outbound backpressure
stops reads when queued reply bytes cross their limit.

A `Session` keeps reading while a partner streams: each of its blocking
waits is one `HostRuntime` pump that services every wire. Session and
HostRuntime accept two kinds of provider through one runtime. A stream provider gives each
connection its own readiness descriptor and nonblocking reads and writes, and
runs on `net.external_completion`. A multiplexed provider carries many
connections over one endpoint. A completion backend joins HostRuntime the same
way through `net.completion_resident`, lending each received chunk from the
backend's pool and keeping no buffer on an idle wire
([ADR-0202](decisions/adr/ADR-0202-stream-transports-join-hostruntime-as-a-completion-resident.md)). Native iroh
is the multiplexed case: `iroh.MultiplexedAdapter` drives every connection
from the endpoint's one readiness descriptor, and the C ABI uses the same
adapter state. A Server admits connections through the runtime's listener
lifecycle, and a session it hands out keeps working after the Server is
destroyed. WebRTC has no socket to poll, so it joins a Host through a
completion backend once signaling is configured (`zig build webrtc-loop`,
redeem via `zig build webrtc-redeem`). A bare locator without that authority
refuses. The Host resolves crossed connections, where both peers dial at once,
because the choice depends on peer identity, not transport mechanics.

The native TCP completion backend binds loopback by default. A service that
accepts from other hosts constructs `net.Backend` with
`initWithListenerIp4`, then gives that backend to `TcpLoop.initWithBackend`.
The backend reports the kernel-bound IPv4 address and resolved port together.
The embedding remains responsible for publishing a dialable locator when it
binds a wildcard address.

On Linux, `net.Backend` tries io_uring first. If the kernel or host policy
cannot support glowcap's io_uring backend, it uses epoll with the same bounded
pool and completion ownership rules. Applications can call
`net.tcpBackendStatus(&loop)` after constructing a TCP, onion, keyed-relay,
Noise, or iroh loop. A non-null `fallback_reason` explains why epoll was
selected (on an iroh loop, for the wrapped Linux platform layer). The library
does not print it, because the embedding owns its logs. `driver.HostRuntime`
does not report the selection for its own stream stack. The 500,000-session
measurement used io_uring, and epoll has no equivalent scale result.
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
| `driver.HostRuntime.Options.wire_buffer_bytes` / `GlowcapDriverOptions.wire_buffer_bytes` | The floor of the one read-staging buffer the runtime shares across wires whose resident copies rather than lends its received bytes. | 16 KiB |
| `driver.HostRuntime.Options.max_pending_opens` / `GlowcapDriverOptions.max_pending_opens` | Transport connects and CapTP handshakes admitted at once, across dial, accept, adoption, and redeem. | 256 |
| `driver.HostRuntime.Options.listener_setup` / `GlowcapDriverOptions.listener_setup_ms` | Maximum time one admitted listener construction may remain pending before its terminal failure. | 10 seconds |
| `driver_core.Host.Options.limits.max_frame_bytes` | Protocol admission for every peer the byte-fed host creates. | 1 MiB |
| `SessionLimits.max_retained_sent_answer_bytes` / `GlowcapSessionLimitOptions.max_retained_sent_answer_bytes` | Owned resolutions retained by sent inbound-answer rows after they leave transient flow accounting. | 16 MiB per session |
| `driver_core.Host.Options.local_turn_budget` / `glowcap_host_new(... local_turn_budget ...)` | Local actor turns one session may amplify into during a drive before the Host condemns that session. | `driver.core.default_loop_local_turn_budget` (4096). `null` in Zig or `GLOWCAP_LOCAL_TURN_BUDGET_UNBOUNDED` in C turns the cap off. A bare `Served` is unbounded. |
| `driver_core.Host.Options.release_on_drop` / `glowcap_host_new(... release_on_drop ...)`, read with `glowcap_host_release_on_drop` and set with `glowcap_host_set_release_on_drop` | Whether a far capability a binding projects releases its Host retain when the language's scope end for it is observed. The Host stores the setting and attaches no behavior to it ([ADR-0192](decisions/adr/ADR-0192-rust-releases-on-drop-by-default.md)). | `true` in Zig. Rust passes 1. TypeScript, Python, and Racket pass 0, because their release rides a finalizer, and keep the per-session opt-in. |
| Raw transport `max_frame_bytes` / `maxFrameBytes` / `max-frame` default | Admission for direct blocking frame-shuttle handles before a Host owns the session. | `GLOWCAP_RAW_TRANSPORT_DEFAULT_FRAME_CAP` (4 KiB) |
| `net.completion.BackendOptions.read_buffer_bytes` | Each buffer in the loop-wide shared read pool. | 16 KiB |
| `net.completion.Options.outbound_high_water_bytes` | Pending outbound bytes before one connection's reads park. | 64 KiB |
| `net.relay.RelayOptions.send_staging_bytes` | One retained masked WebSocket send chunk, including its header. | 4 KiB |

[Stability](stability.md) lists the TLS and relay carrier evidence, and the
[ladder](ladder.md) holds connection footprints.

`initWithBackendOptions` tunes a backend the
loop builds. `initWithBackend` accepts only runtime policy because the supplied
backend already owns its resource configuration.

`HostRuntime` retries a staged dial above the loop on `driver.DialPolicy`,
which classifies dial failures and sets the discovery budget. A transient
fault parks the open for one interval and re-issues the dial on the same
session, and a permanent fault fails the open at once. The protocol core has
no reconnect policy.

## Session tables

CapTP names imports, exports, and answers with integer positions. glowcap keeps
each namespace in its own hash table:

- direct lookup stays constant-time
- a sparse number from an untrusted peer cannot force a giant array
- garbage collection removes an answer row before its position can be reused
- locally minted outbound answers fail closed in `session/answers/pipeline.zig`
  before their cursor can wrap
- imports retain a separate cap because the remote peer chooses their count

Once the session sends the answer to an inbound call, it keeps that answer's
resolution, because later pipelined messages may still refer to it. These rows
are capped both by count and by total owned bytes. A resolution cannot be
evicted without changing what pipelining is allowed to reach, so overflow
fails loudly as `resource_exhausted`. Answer GC and local promise retirement
release exactly the bytes each row was charged (ADR-0121).

Near references, promises, and answers share one internal slot type. The codec
works out the matching wire descriptor only when it renders a frame.

A far import's position was chosen by the remote peer, so its row only needs
two retain counts. The first counts the references the partner granted by
mentioning it. The second counts how many of those the session itself will
release, held next to the closure that will spend them. With both on one row,
pipelining, settlement, and handoff read the same state, and an application's
release can never spend a retain the session still needs
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

The codec follows the same rule. `decodeBody` projects a borrowed view.
`decodeOwned` creates an owned value when data must survive the frame. Syrup
frames are byte-aligned, while Cap'n Proto frames require eight-byte alignment.
`FrameShape` keeps that difference visible.

Production code moves frames by ownership:

- `Frame.initOwned` and `Frame.initExternal` adopt existing storage.
- `Frame.view` borrows without allocating.
- `Peer.feedOwned` and `Peer.step` move an owned frame into an event.
- `Peer.recvBorrowed` makes the one copy required to retain borrowed input.
- `Peer.sendCopying` names its queueing copy in the API.

A delivered call to a live export makes one owned-frame allocation. The
allocation and footprint checks under `test/engine/` protect that budget. Test
fixtures have a copying helper, and production `Frame` has no general copy
constructor.

## C ABI and bindings

The C ABI uses opaque handles, fixed-width result codes, `ptr + len` views,
caller-supplied callback contexts, and explicit release. Allocation goes
through `GlowcapContext`. Peer locators and sturdyrefs stay distinct values at
every public surface: a locator carries transport, designator, and hints. A
sturdyref embeds a peer locator plus swiss bytes.

An owned `GlowcapManagedFrame` moves the native frame owner into opaque words
inside the caller's descriptor. Producing, probing, and releasing that
descriptor allocate no metadata and copy no frame bytes (ADR-0122).

Lifecycle, admission, provider composition, protocol state, and failure
classification remain in `driver_core` or `driver`. The C layer validates ABI
layout and lossless representation, marshals values, owns opaque-handle and
event-delivery storage, and projects the Zig result. Bindings add host-language
resource idioms and drive effects to the native completion barrier. They do not
retain policy for a background worker or maintain a second state machine.

A failure that can be returned stays in ordinary control flow. When no caller
or close barrier is left to receive it, the `diagnostics` layer turns it into
a typed record in the owning `GlowcapContext` journal. The C
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
Racket layout expectations. C-only rows remain part of archive identity.
Native binding loaders compare every archive before an ordinary call.
Implementation-only edits do not perturb the contract (ADR-0123).
These fingerprints check the public ABI. Archives sharing opaque Host and actor
owners are built together. Private compatibility across different builds is
outside that check. Actor callbacks use stable protocol tokens and diagnostic
text across archive copies, with typed Zig errors local to their compilation
([ADR-0059](decisions/adr/ADR-0059-composable-c-abi-archives.md)).

Native bindings load `libglowcap_host` and `libglowcap_driver`. The driver
takes an idle Host and runs the loop. The binding waits on one readiness
descriptor, arms one runtime-native timer from
`glowcap_driver_step_wait_ms`, calls `glowcap_driver_step`, and drains one
event queue. The driver remains the sole authority for which pending operation
owns the nearest deadline. A binding only projects that duration into its
scheduler. The browser package and any embedder that already owns I/O still
drive the Host themselves: feed bytes, pump and drain, take outbound frames.
glowcap does not create a background runtime inside Python, Racket, Rust, or
TypeScript.

`libglowcap_driver` starts with no transports. The application installs
provider packages through `glowcap_transport_provider.h`:

- The TCP archive supplies `noise-tcp`, `keyed-tcp`, and the testing `tcp`.
- The relay archive supplies `keyed-relay` and `noise-relay`.
- Onion, iroh, and WebRTC ship as separate archives. The driver uses them
  without naming what is inside.

The rules for providers:

- Listener ids are the key for routing accepted connections, through every
  binding. The driver owns each listener's canonical public locator.
- A provider compares its own complete effective configuration. Registering an
  equivalent package again does nothing, and a conflicting package is
  refused. Bindings keep no separate registry of providers or credentials.
- A provider may expose opaque local restoration bytes, read through a
  size query and a caller-supplied buffer. Those bytes never enter the
  locator, and only that provider package interprets them. The onion package
  stores its Tor service key there.
- Host and session progress happens only inside a step call, on the one thread
  that drives the loop. A provider may run its own worker threads, but it
  reports their results through the shared readiness mechanism and never
  calls the Host from them.

After `glowcap_driver_take_host` succeeds, adoption is durable even when a later
bind fails: the supplied Host remains a valid loop-backed Host for another
attempt. Bindings tear down only loops and Hosts they minted themselves.

## Other entry points

The installable `glowcap` command is an application of the public library. It
owns terminal behavior, identity files, MCP stdio, room presence, verified
product installation, and Rooms deployment. Its deployment path shares the
installed product inventory with Docker image construction, so the image holds a
complete immutable product and no checkout output. [The CLI guide](cli.md)
covers it.

First-party applications live under [`apps/`](../apps/). Compilable teaching
programs live under [`examples/`](../examples/README.md). Build checks and code
generators live under [`tools/`](../tools/README.md).

Rooms' [Rust application boundary](decisions/adr/ADR-0147-rooms-rust-application-boundary.md)
places the shared Rooms protocol and application policy above the Zig Host,
which continues to own CapTP. Rendering and platform I/O remain in adapters.
The running presentation is TypeScript.

CapTP and OCapN claims are checked against the upstream OCapN suite, live Goblins
peers, and the in-tree reference corpus. [Community review](community-review.md)
states what that evidence covers.

## Loam language boundary

The optional C Loam archive projects persistence and fixed-resource managed
hosting into the existing Host. The LMDB companion owns exclusive database
custody and executes submitted effects. Rust supplies typed descriptors,
callback contexts and joined workers. Graph authority and installation remain
in Zig. [ADR-0185](decisions/adr/ADR-0185-loam-c-and-rust-resource-lifecycle.md)
records release refusal, physical retirement and explicit completion consumption.
The [C/Rust guide](loam/c-and-rust.md) gives the
consumer path and its limits.
