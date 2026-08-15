# Architecture

Most Zig programs start with `driver.Session`: connect or listen, then fetch,
call, publish, and redeem handoffs as ordinary operations. That Session is a
view onto one connection owned by a `driver.HostRuntime`. Each runtime realizes
one independent multi-session CapTP Host, and a process may own many. Every Host
has one Node (identity and routing), one Vat (actors and turns), and one
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

Those product names mean:

| Name | Meaning |
| --- | --- |
| Host | Multi-session CapTP product: one identity, one Vat, one Node, and the sessions under them. Not an OS hostname or transport endpoint. |
| Node | Host-owned sans-I/O identity, routing state, and handoff router (`engine.Node`). |
| Vat | Actor container and turn loop. |
| Port | One actor-layer session projection and ingress into the Vat (`actors.Port`). It lives inside the Host's serving shell; it is not a TCP port or a synonym for `PancakeHostSession`. |
| Peer | Local CapTP state machine for that session. In prose, "peer" still means the remote party. |
| Session | Application-facing one-partner CapTP conversation, backed by a Host-registered shell (`driver_core.HostSession` / `PancakeHostSession`) and one byte connection. |

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

Read this page from the top down if you are choosing an API. Read it from the
bottom up if you are adding a codec, transport, or binding.

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

Session state decides whether a reference is valid and what it names. A codec
only parses and renders that decision. This is why changing codecs cannot mint
authority or change CapTP behavior.

The module graph enforces the split. Protocol modules cannot import adapters,
and Syrup and Cap'n Proto cannot import one another. The architecture check also
rejects `std.Io`, threads, and platform calls in the portable core
([ADR-0040](decisions/adr/ADR-0040-layer-modules-as-import-law.md),
[ADR-0048](decisions/adr/ADR-0048-codec-sibling-isolation.md)).

## From a peer to an application

`engine.Peer` is useful when the application already owns an event loop or is
embedding pancake behind another runtime. Most Zig programs start higher.

| API | Use it when |
| --- | --- |
| `driver.Session` | You want one application-facing session with blocking calls, backed by a connection its `driver.HostRuntime` owns. Handoffs are redeemed before a call returns. |
| `driver.HostRuntime` | You want one identity across several file-descriptor-backed sessions. |
| `driver.BlockingSession` | You own the connection and buffers, or your transport has no pollable descriptor (an in-process pipe, or a WebRTC peer you already opened). Values are actor-layer references rather than opaque host capabilities. A call may return a handoff for you to redeem. |
| `driver_core.Host` | Your runtime feeds bytes and drains actions without letting pancake own I/O. Native bindings hand this Host to the driver; the browser package feeds it itself. |
| `driver.Bridge` | You are connecting `driver_core.Host` to a completion loop for many sessions. |

The actor layer sits between the protocol peer and these application APIs.
`actors.Vat` hosts local objects, turns incoming calls into actor turns, and
settles their results. It also provides attenuation, revocation, and optional
snapshots. A snapshot covers local actor state only; it never rewinds a network
session. Persistent actor state uses a structurally shared map, so changing one
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

## Transports and connection loops

The `net` layer turns a byte stream into complete frames. Each byte-stream
message is a bare negotiated-codec frame inside one outer Syrup byte string;
the outer length supplies the boundary and the inner codec must consume the
body exactly. A transport that already preserves message boundaries hands bare
frames to the whole-frame API instead. The transport implementations are plain
TCP, keyed TCP, Noise-sealed TCP, keyed relay, Noise-sealed relay, onion,
in-process pipes, iroh, and WebRTC
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

[Known limitations](boundaries.md#transports-and-peer-identity) compares the
security and reachability of the transports.

## Resource controls belong to the layer they protect

Protocol admission, shared read memory, and outbound backpressure are separate
decisions:

| Option | What it limits | Default |
| --- | --- | --- |
| `driver.HostRuntime.Options.frame_cap` | Protocol admission for sessions the owning face creates. | 64 KiB |
| `driver.HostRuntime.Options.wire_buffer_bytes` / `PancakeDriverOptions.wire_buffer_bytes` | Each stream read/write buffer and multiplexed-resident read staging buffer. | 16 KiB |
| `driver.HostRuntime.Options.max_pending_opens` / `PancakeDriverOptions.max_pending_opens` | Transport connects and CapTP handshakes admitted at once, across dial, accept, adoption, and redeem. | 256 |
| `driver.HostRuntime.Options.listener_setup` / `PancakeDriverOptions.listener_setup_ms` | Maximum time one admitted listener construction may remain pending before its terminal failure. | 10 seconds |
| `driver_core.Host.Options.limits.max_frame_bytes` | Protocol admission for every peer the byte-fed host creates. | 1 MiB |
| `net.completion.BackendOptions.read_buffer_bytes` | Each buffer in the loop-wide shared read pool. | 16 KiB |
| `net.completion.Options.outbound_high_water_bytes` | Pending outbound bytes before one connection's reads park. | 64 KiB |
| `net.relay.RelayOptions.send_staging_bytes` | One retained masked WebSocket send chunk, including its header. | 4 KiB |

The completion loop can therefore change admission, pool memory, outbound
slack, and transport staging independently. `initWithBackendOptions` tunes a
backend the loop builds; `initWithBackend` accepts only runtime policy because
the supplied backend already owns its resource configuration.

`driver.DialRetry` adds reconnect policy above the loop. It classifies
dial failures, opens a new CapTP session, and applies its own discovery budget.
The protocol core has no reconnect policy.

## Session tables

CapTP names imports, exports, and answers with integer positions. pancake keeps
each namespace in its own hash table:

- direct lookup stays constant-time;
- a sparse number from a hostile peer cannot force a giant array;
- garbage collection removes an answer row before its position can be reused;
- imports retain a separate cap because the remote peer chooses their count.

A near reference, far reference, promise, and answer share one internal slot
representation. The codec derives the corresponding wire descriptor only when
it renders a frame. This keeps pipelining, settlement, and handoff on the same
state.

Recursive values are limited by `SessionLimits.max_nesting_depth`. Session
state also decides which messages are legal while negotiating, open, or closed.
An invalid transition is refused before it can mutate a table.

pancake never reuses positions it allocates itself. A partner may reuse an
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
through `PancakeContext`. Peer locators and sturdyrefs stay distinct values at
every public surface: a locator carries transport, designator, and hints; a
sturdyref embeds a peer locator plus swiss bytes.

Lifecycle, admission, provider composition, protocol state, and failure
classification remain in `driver_core` or `driver`. The C layer validates ABI
layout and lossless representation, marshals values, owns opaque-handle and
event-delivery storage, and projects the Zig result. Bindings add host-language
resource idioms and drive effects to the native completion barrier; they do not
retain policy for a background worker or maintain a second state machine.

Returned failures remain in ordinary control flow. When the last caller or
close barrier that could receive a failure has gone, the `diagnostics` layer
normalizes it into a typed record in the owning `PancakeContext` journal. The C
ABI only projects that record and the Context-local lifecycle IDs that name its
owners. Its per-thread `last_error`, a session's retained
abort, and the live protocol trace remain separate because each describes a
different fact. [ADR-0115](decisions/adr/ADR-0115-structured-diagnostic-waist.md)
owns this boundary.

There is no umbrella library. A C program links the shared OCapN vocabulary and
only the Host, driver, and transport archives it needs. [The C
guide](consuming-from-c.md) has the archive table, build commands, provider
install, and a complete program.

Native bindings load `libpancake_host` and `libpancake_driver`. The driver
takes an idle Host and runs the loop. The binding waits on one readiness
descriptor, arms one runtime-native timer from
`pancake_driver_step_wait_ms`, calls `pancake_driver_step`, and drains one
event queue. The driver remains the sole authority for which pending operation
owns the nearest deadline; a binding only projects that duration into its
scheduler. The browser package and any embedder that already owns I/O still
drive the Host themselves: feed bytes, pump and drain, take outbound frames.
pancake does not create a background runtime inside Python, Racket, Rust, or
TypeScript.

`libpancake_driver` starts with zero transports; the application installs
provider packages through `pancake_transport_provider.h`. The TCP archive supplies `tcp`, `keyed-tcp`,
and `noise-tcp`; the relay archive supplies `keyed-relay` and `noise-relay`;
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

After `pancake_driver_take_host` succeeds, adoption is durable even when a later
bind fails: the supplied Host remains a valid loop-backed Host for another
attempt. Bindings tear down only loops and Hosts they minted themselves.

## Other entry points

The installable `pancake` command is an application of the public library, not
another protocol layer. It owns terminal behavior, identity files, MCP stdio,
and room presence. [The CLI guide](cli.md) covers it.

First-party applications live under [`apps/`](../apps/). Compilable teaching
programs live under [`examples/`](../examples/README.md). Build checks and code
generators live under [`tools/`](../tools/README.md).

Protocol claims are checked against the upstream OCapN suite, live Goblins
peers, and the in-tree reference corpus. [Community review](community-review.md)
states exactly what that evidence covers.
