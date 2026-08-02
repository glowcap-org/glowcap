# Architecture

Most applications use `driver.Session`, a view onto one connection owned by a
`driver.PollHost`. It presents fetch, call, publish, and handoff as ordinary
operations. The runtime ownership and protocol layers are separate views:

```text
Host: identity, routing, sessions
├── one Vat: actors, state, turns
└── sessions
    └── Port: that session's projection and ingress
        └── Peer: that session's CapTP state
```

A Host and a Vat are not aliases. The Host owns network identity and routing;
the Vat it owns supplies one actor graph and scheduler. Each session's Port
projects that graph into session-local export positions and attributes inbound
work to its own ingress. `engine.Peer` remains the protocol state for one
session.

The layers below separate protocol decisions from encoding, I/O, and
application scheduling.

```text
application
    driver.Session / driver.PollHost
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
| `foundation` | Owned frames, borrowed frame views, limits, crypto, and shared utilities. |
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
| `driver.Session` | You want one owned connection and blocking application calls. Handoffs are redeemed before a call returns. |
| `driver.PollHost` | You want one identity across several file-descriptor-backed sessions. |
| `driver.BlockingSession` | You own the connection and buffers and want the lower-level blocking path, or your transport has no pollable descriptor (an in-process pipe, a WebRTC peer) so `PollHost` cannot wait on it. Values are the actor layer's own references and messages rather than opaque host capabilities, and a call may return a handoff for you to redeem. |
| `driver_core.Host` | Your runtime feeds bytes and drains actions without letting pancake own its I/O. This is the core exposed to bindings. |
| `driver.Bridge` | You are connecting `driver_core.Host` to a completion loop for many sessions. |

The actor layer sits between the protocol peer and these application APIs.
`actors.Vat` hosts local objects, turns incoming calls into actor turns, and
settles their results. It also provides attenuation, revocation, and optional
snapshots. A snapshot covers local actor state only; it never rewinds a network
session. Persistent actor state uses a structurally shared map, so changing one
entry does not copy the whole map
([ADR-0060](decisions/adr/ADR-0060-vat-local-time-travel.md),
[ADR-0061](decisions/adr/ADR-0061-persistent-collections-module.md)).

Local eventual-sends enter ingress-attributed queues. The Vat measures the
complete owned-clone charge before mutation, applies per-ingress turn and byte
limits, and rotates runnable ingresses one turn at a time while retaining FIFO
within each one. Queue chunks reclaim independently, with at most one bounded
spare for the whole Vat. The actor layer owns this admission and scheduling;
the standard Host owns one Vat, and each session Port supplies its ingress
identity but does not own a queue
([ADR-0099](decisions/adr/ADR-0099-shared-vat-scheduling.md)).

## Transports and connection loops

The `net` layer turns a byte stream into complete frames. Its transport
implementations are plain TCP, keyed TCP, in-process pipes, iroh, and WebRTC.
The protocol above sees the same `Connection` contract for each one.

Inbound frames have a size limit. A frame larger than the current read buffer
uses one bounded spill buffer rather than forcing every connection to retain a
maximum-sized buffer. Read buffers are pooled across the completion loop.
Outbound backpressure stops reads when queued reply bytes cross their limit.

The simple blocking pump runs on one fiber. Applications that must keep reading
while a partner streams use the TCP or iroh completion loop. A WebRTC resident
owns one sidecar runtime and readiness fd shared by stable endpoint-scoped peer
ids. Peer creation and SDP/ICE submissions are synchronous control operations;
after submission, channel establishment, candidates, byte I/O, and closure are
readiness events with non-blocking try-I/O. The explicit blocking connection is
the `BlockingSession` tier, not the scale path. The generic Host adapter which
binds those peer events to sessions is not built. Crossed connections, where
both peers dial at once, are resolved by the host because the choice depends on
peer identity rather than transport mechanics.

[Known limitations](boundaries.md#transports-and-peer-identity) compares the
security and reachability of the transports.

## Limits belong to the layer they protect

Three options contain the phrase “frame cap,” but they limit different things:

| Option | What it limits | Default |
| --- | --- | --- |
| `driver.PollHost.Options.frame_cap` | One owned session's buffers and protocol admission. | 64 KiB |
| `driver_core.Host.Options.limits.max_frame_bytes` | Protocol admission for every peer the byte-fed host creates. | 1 MiB |
| `completion.Loop.Options.frame_cap` | Buffers in the shared read pool, not protocol admission. | 64 KiB |

Raising one does not raise the others.

`driver.ResilientClient` adds reconnect policy above the loop. It classifies
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
through `PancakeContext`.

There is no umbrella library. A C program links the core and only the host and
transport archives it needs. [The C guide](consuming-from-c.md) has the archive
table, build commands, and a complete program.

Bindings drive the byte-fed host in a three-part cycle:

1. feed bytes with `pancake_host_session_feed_bytes`;
2. let the host run resulting work with `pancake_host_pump_drain`;
3. take outbound frames with `pancake_host_session_take_outbound`.

The binding's runtime schedules that cycle and performs the actual I/O. pancake
does not create a background runtime inside Python, Racket, Rust, or
TypeScript.

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
