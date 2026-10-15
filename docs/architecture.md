---
type: static
description: How glowcap's layers fit together, from the protocol core up to the Host, the C ABI and the bindings.
sources:
  - resource: /src/
  - resource: /include/
  - resource: /bindings/
---

# Architecture

glowcap's layers, from the protocol core up to the C ABI. These names come up
throughout:

| Name | Meaning |
| --- | --- |
| Host | One CapTP identity and every session it holds, with one Vat and one Node. Not an OS hostname. |
| Node | The Host's identity, routes, and handoff router, with no I/O (`engine.Node`). |
| Vat | Where the Host's actors live. It handles one message at a time, each to completion. |
| Port | One session's way into the Vat (`actors.Port`). Not a TCP port. |
| Peer | The CapTP state machine for one session (`engine.Peer`). In prose, "peer" means the other party. |
| Session | What the application holds: one conversation with one partner over one connection, registered with the Host (`driver_core.HostSession`, `GlowcapHostSession` in C). |

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
            └── Port: what that session sees of the Vat, and its way in
                └── Peer: that session's CapTP state
```

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
opens no sockets, starts no tasks, and chooses no scheduler.

| Layer | Responsibility |
| --- | --- |
| `foundation` | Owned frames, borrowed frame views, limits, crypto, the sealed byte channel both stream tiers compose (ADR-0107), and shared utilities. |
| `model` | Values and messages that can cross an OCapN session. |
| `codec` | Syrup and Cap'n Proto decoding and encoding. A frame reaches a codec whole: the envelope or the transport delimits it (ADR-0229). |
| `session` | Imports, exports, answers, promises, handoff, and protocol validation. |
| `engine` | The caller-driven state machine around one session. |

Route lists have one owner (`model.route_bundle`). The identity rule sits on
top (`session.id_route`): every `id` route must prove the durable key the
locator names. `engine.Node` only schedules bundles those layers already
accepted. It does not treat `id` as a physical transport.

Session tables decide whether a reference is valid. A codec only encodes and
decodes that decision, so changing codecs cannot create a reference or change CapTP
behavior.

The module graph enforces that split. Protocol modules cannot import adapters,
and Syrup and Cap'n Proto cannot import one another. The architecture check
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
| `driver_core.Host` | Your runtime feeds bytes and drains actions without letting glowcap own I/O. The bindings that load the C library hand this Host to the driver. The browser package feeds it itself. |

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

Local eventual sends go into queues keyed by *ingress*, the session the work
came from. (An eventual send is a call that runs later, not inline.) Before queuing, the Vat measures what the owned copy will cost and
applies turn and byte limits per ingress. It takes one turn at a time from each
runnable ingress in rotation, first-in-first-out within each one. The whole Vat
keeps at most one bounded spare queue chunk. The standard Host owns one Vat,
and each session Port supplies its ingress identity but owns no queue
([ADR-0099](decisions/adr/ADR-0099-shared-vat-scheduling.md)).

## Resource models

[Loam](loam.md) provides immutable collections, record storage,
transactions, and bounded residency through `glowcap.loam`. It does its disk
I/O through the application's executor and adds no Host or scheduler.

### Loam's modules

- **`collections`** holds the immutable collections and has no storage
  dependency.
- **`records`** owns storage identities and checked Syrup envelopes.
- **`core`** builds transaction and lease state on top of `records`. The
  optional SQLite and LMDB engines and the volatile engine share its batch
  validator.
  It also owns incremental tracing with insertion barriers. Marks and queue
  entries are stored, so traversal stays out of the actor working set, and
  bounded live retention and pinned snapshots protect objects during a sweep.
- **`hosting`** attaches record-backed actors to the existing Vat and Host. It
  owns bounded pending calls and lazy restoration of local capabilities, and
  ordinary Host promises carry the replies that wait for commit.
- **`access`** supplies resource permissions and joins Store transactions. It is
  described below.

Loam's persistence core does not depend on managed access, the Host, or CapTP
session state. Optional integration modules connect them, and the facade
offers managed access without requiring resource state for ordinary objects.
Rooms stores its managed session through Loam on SQLite and IndexedDB (the
[session guide](rooms/session.md) owns its recovery contract). The
[Loam API](loam/api.md) separates record schemas, storage encoding, reference
restoration, and wire codecs.

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
contract. [Known limitations](boundaries.md#api-gaps) names the integration
that remains for applications and foreign bindings.

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

A `Session` keeps reading while a partner streams: each blocking wait is one
`HostRuntime` pump that services every wire. The runtime accepts two kinds of
provider. A stream provider gives each connection its own readiness descriptor
and nonblocking reads and writes, and runs on `net.external_completion`. A
multiplexed provider carries many connections over one endpoint. A completion
backend joins the runtime through `net.completion_resident`, lending each
received chunk from the backend's pool and keeping no buffer on an idle wire
([ADR-0202](decisions/adr/ADR-0202-stream-transports-join-hostruntime-as-a-completion-resident.md)).

iroh is the multiplexed case: `iroh.MultiplexedAdapter` drives every
connection from the endpoint's one readiness descriptor, and the C ABI uses the
same adapter state. A Server accepts connections through the runtime's listener
lifecycle, and a session it hands out keeps working after the Server is
destroyed. WebRTC has no socket to poll, so it joins a Host through a
completion backend once signaling is configured (`zig build webrtc-loop`, and
`zig build webrtc-redeem` for redeem). A bare locator without signaling set up
is refused. The Host resolves crossed connections, where both peers dial at once,
because the choice depends on peer identity, not transport mechanics.

The TCP completion backend binds loopback by default. A service that
accepts from other hosts constructs `net.Backend` with `initWithListenerIp4`,
then gives it to `TcpLoop.initWithBackend`. The backend reports the
kernel-bound IPv4 address and resolved port together, and the application
publishes a dialable locator when it binds a wildcard address.

On Linux, `net.Backend` tries io_uring first and falls back to epoll, with the
same bounded pool and completion ownership rules, when the kernel or host
policy cannot support it. After constructing a TCP, onion, keyed-relay, Noise,
or iroh loop, call `net.tcpBackendStatus(&loop)`. A non-null `fallback_reason`
explains why epoll was selected (on an iroh loop, for the wrapped Linux
platform layer). The library prints nothing, because the application owns its
logs ([ADR-0152](decisions/adr/ADR-0152-linux-completion-backend-selection.md)).
[Known limitations](boundaries.md) covers what `driver.HostRuntime` reports.

[Known limitations](boundaries.md#transports-and-peer-identity) compares the
security and reachability of the transports.

## Resource knobs

Each option limits one thing: frame size, shared read memory, data waiting to
be sent, or how much local work one session can set off. Each default sits
beside its option in the code.

| Option | What it limits |
| --- | --- |
| `driver.HostRuntime.Options.frame_cap` | The largest frame a session this runtime creates accepts. |
| `driver.HostRuntime.Options.wire_buffer_bytes` / `GlowcapDriverOptions.wire_buffer_bytes` | The minimum size of the one read buffer the runtime shares among connections that copy received bytes instead of lending them. |
| `driver.HostRuntime.Options.max_pending_opens` / `GlowcapDriverOptions.max_pending_opens` | How many transport connects and CapTP handshakes may run at once, counting dials, accepts, adoptions, and redeems. |
| `driver.HostRuntime.Options.listener_setup` / `GlowcapDriverOptions.listener_setup_ms` | How long setting up one listener may take before it fails. |
| `driver_core.Host.Options.limits.max_frame_bytes` | The largest frame any peer of a byte-fed Host accepts. |
| `SessionLimits.max_retained_sent_answer_bytes` / `GlowcapSessionLimitOptions.max_retained_sent_answer_bytes` | Bytes of resolutions a session keeps for answers it already sent, once they no longer count as data in flight. |
| `driver_core.Host.Options.local_turn_budget` / `glowcap_host_new(... local_turn_budget ...)` | How many local actor turns one session may set off during one drive before the Host ends that session. `null` in Zig or `GLOWCAP_LOCAL_TURN_BUDGET_UNBOUNDED` in C turns the cap off. A bare `Served` is unbounded. |
| `driver_core.Host.Options.release_on_drop` / `glowcap_host_new(... release_on_drop ...)`, read with `glowcap_host_release_on_drop` and set with `glowcap_host_set_release_on_drop` | Whether a binding releases its hold on a far capability when the language reports that it went out of scope. The Host stores the setting and attaches no behavior to it ([ADR-0192](decisions/adr/ADR-0192-rust-releases-on-drop-by-default.md)). Rust turns it on. TypeScript, Python, and Racket turn it off, because their release runs from a finalizer, and keep the per-session opt-in. |
| Raw transport `max_frame_bytes` / `maxFrameBytes` / `max-frame` default | The largest frame a raw blocking transport handle accepts before a Host owns the session. |
| `net.completion.BackendOptions.read_buffer_bytes` | The size of each buffer in the loop's shared read pool. |
| `net.completion.Options.outbound_high_water_bytes` | Bytes waiting to be sent before the loop stops reading from that connection. |
| `net.relay.RelayOptions.send_staging_bytes` | One buffered WebSocket chunk waiting to send, header included. |

`initWithBackendOptions` tunes a backend the loop builds. `initWithBackend`
accepts only runtime policy, because the supplied backend already owns its
resource configuration. [Stability](stability.md) lists the checks for TLS and relay
carriers, and [benchmarks](../bench/README.md) hold connection
footprints.

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
are capped by count and by total owned bytes. Evicting one would change what
pipelining can reach, so overflow fails as `resource_exhausted`. Answer GC and
local promise retirement release exactly the bytes each row was charged
(ADR-0121).

Near references, promises, and answers share one internal slot type. The codec
works out the matching wire descriptor only when it renders a frame.

A far import's position was chosen by the remote peer, so its row needs two
retain counts. The first counts the references the partner granted by
mentioning it. The second counts how many of those the session itself will
release, held next to the closure that spends them. With both on one row,
pipelining, settlement, and handoff read the same state, and an application's
release can never spend a retain the session still needs
([ADR-0146](decisions/adr/ADR-0146-session-held-import-retains.md)).

`SessionLimits.max_nesting_depth` limits recursive values. Session state also
decides which messages are legal while negotiating, open, or closed, and an
invalid transition is refused before it can mutate a table.

glowcap never reuses positions it allocates itself. A partner may reuse an
import position after release. The final decrement removes every sturdyref
cache entry and clears the import row's routing generation. An old host route
then fails closed even if its map row is reclaimed after the partner reuses the
position.

## Frame ownership and copies

`Frame` owns its bytes. `FrameView` borrows bytes for one bounded call. Session
state may never retain memory borrowed from an inbound frame.

The codec follows the same rule. `decodeBody` returns a borrowed view.
`decodeOwned` creates an owned value when data must survive the frame. Syrup
frames are byte-aligned, while Cap'n Proto frames require eight-byte alignment.
`FrameShape` keeps that difference visible.

Production code moves frames by ownership:

- `Frame.initOwned` and `Frame.initExternal` adopt existing storage.
- `Frame.view` borrows without allocating.
- `Peer.feedOwned` and `Peer.step` move an owned frame into an event.
- `Peer.recvBorrowed` makes the one copy required to retain borrowed input.
- `Peer.sendBorrowed` lends a message for the call: a deliver leaves as its
  frame before it returns, and the kinds the queue keeps name their copy.
- `Peer.sendFreight` lends a deliver's values as views: the session
  certifies them, the encoder reads them, and nothing copies them.

A delivered call to a live export makes one owned-frame allocation, and the
allocation and footprint checks under `test/engine/` protect that budget.
Production `Frame` has no general copy constructor.

## C ABI and bindings

The C ABI uses opaque handles, fixed-width result codes, `ptr + len` views,
caller-supplied callback contexts, and explicit release. Allocation goes
through `GlowcapContext`. Peer locators and sturdyrefs stay distinct values at
every public interface: a locator carries transport, designator, and hints. A
sturdyref contains a peer locator plus swiss bytes.

An owned `GlowcapManagedFrame` moves the C frame owner into opaque words
inside the caller's descriptor. Producing, probing, and releasing that
descriptor allocate no metadata and copy no frame bytes (ADR-0122).

Lifecycle, accepting connections, provider composition, protocol state, and failure
classification stay in `driver_core` or `driver`. The C layer validates ABI
layout and lossless representation, marshals values, owns opaque-handle and
event-delivery storage, and passes on the Zig result. Bindings add host-language
resource idioms and drive effects to the completion barrier. They keep
no policy for a background worker and no second state machine.

A failure that can be returned stays in ordinary control flow. When no caller
or close barrier is left to receive it, the `diagnostics` layer turns it into a
typed record in the owning `GlowcapContext` diagnostic log, and the C ABI exposes that
record with the Context-local lifecycle IDs that name its owners. The
per-thread `last_error`, a session's retained abort, and the live protocol
trace stay separate because each describes a different fact
([ADR-0115](decisions/adr/ADR-0115-structured-diagnostic-waist.md)).

There is no umbrella library. A C program links the shared OCapN vocabulary and
only the Host, driver, and transport archives it needs. [The C
guide](consuming-from-c.md) has the archive table, build commands, provider
install, and a complete program.

Every separately loaded archive, including the core, Host, and driver, exposes
a reflected callable/constant/layout fingerprint. Binding-projected rows in the
canonical struct manifests also generate the Rust, TypeScript, Python, and
Racket layout expectations, and C-only rows stay part of archive identity.
Binding loaders compare every archive before an ordinary call.
Implementation-only edits do not perturb the contract (ADR-0123).

The fingerprints check the public ABI, so archives sharing opaque Host and
actor owners are built together. Private compatibility across different builds
is outside that check. Actor callbacks use stable protocol tokens and
diagnostic text across archive copies, with typed Zig errors local to their
compilation ([ADR-0059](decisions/adr/ADR-0059-composable-c-abi-archives.md)).

Bindings that load the C library use `libglowcap_host` and `libglowcap_driver`. The driver
takes an idle Host and runs the loop. The binding waits on one readiness
descriptor, arms one timer from the host runtime from `glowcap_driver_step_wait_ms`,
calls `glowcap_driver_step`, and drains one event queue. The driver decides
which pending operation owns the nearest deadline, and the binding turns
that duration into a timer on its scheduler.

The browser package and any application that already owns I/O drive the Host
themselves: feed bytes, pump and drain, take outbound frames. glowcap creates
no background runtime inside Python, Racket, Rust, or TypeScript.

`libglowcap_driver` starts with no transports. The application installs
provider packages through `glowcap_transport_provider.h`:

- The TCP archive supplies `noise-tcp`, `keyed-tcp`, and the testing `tcp`.
- The relay archive supplies `keyed-relay` and `noise-relay`.
- Onion, iroh, and WebRTC ship as separate archives. The driver uses them
  without naming what is inside.

The rules for providers:

- Listener ids key the routing of accepted connections in every binding. The
  driver owns each listener's canonical public locator.
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
product installation, and Rooms deployment, which shares the installed product
inventory with Docker image construction. [The CLI guide](cli.md) covers it.

First-party applications live under [`apps/`](../apps/). Compilable teaching
programs live under [`examples/`](../examples/README.md). Build checks and code
generators live under [`tools/`](../tools/README.md).

Rooms' [Rust application boundary](decisions/adr/ADR-0147-rooms-rust-application-boundary.md)
puts the shared Rooms protocol and application policy above the Zig Host,
which owns CapTP. Rendering and platform I/O remain in adapters.
The running presentation is TypeScript.

CapTP and OCapN claims are checked against the upstream OCapN suite, live Goblins
peers, and the in-tree reference corpus. [Community review](community-review.md)
states what those checks cover.

## Loam language boundary

The optional C Loam archive brings persistence and fixed-resource managed
hosting into the existing Host. Each disk-engine companion holds its database exclusively
and executes submitted effects. Rust supplies typed descriptors,
callback contexts, and joined workers. The rules for who may hold a graph, and
how a commit is installed, stay in Zig ([ADR-0185](decisions/adr/ADR-0185-loam-c-and-rust-resource-lifecycle.md)).
The [C/Rust guide](loam/c-and-rust.md) gives the consumer path and its limits.
