# Using pancake from C

The C application surface is `PancakeHost`. It owns CapTP sessions, routing,
hosted objects, promises, handoff, and opaque capability identities while your
runtime owns I/O and scheduling. Native Zig still exposes `engine.Peer` for
low-level protocol work; C does not mirror that internal type.

[`pancake_ocapn.h`](../include/pancake_ocapn.h) supplies shared ABI vocabulary:
contexts, frames, arguments, locators, and URI helpers.
[`pancake_host.h`](../include/pancake_host.h) supplies the CapTP application
surface. Transport headers supply connections and listeners, never a second
session API.

## Build the libraries

```sh
zig build
```

Headers are installed under `zig-out/include/`; static and shared libraries are
installed under `zig-out/lib/`.

| Library | Header | Purpose |
| --- | --- | --- |
| `libpancake_ocapn` | `pancake_ocapn.h` | Shared values, locators, frames, and URI helpers. |
| `libpancake_host` | `pancake_host.h` | The byte-fed, multi-session CapTP host. |
| `libpancake_driver` | `pancake_driver.h` | The native loop: it exports only `pancake_driver_*` and adopts an idle Host from `libpancake_host` through `pancake_driver_take_host`. |
| `libpancake_net_transport_iroh` | `pancake_net_transport_iroh.h` | Optional encrypted QUIC transport. |
| `libpancake_net_transport_webrtc` | `pancake_net_transport_webrtc.h` | Optional WebRTC DataChannel transport. |
| `libpancake_net_transport_onion` | `pancake_net_transport_onion.h` | Tor onion services, through a Tor daemon you already run. The one transport the OCapN draft standardizes. |
| `libpancake_net_transport_relay` | `pancake_net_transport_relay.h` | Native `keyed-relay` and end-to-end sealed `noise-relay` provider package, with pollable `ws` and `wss` carriers. |
| `libpancake_net_transport_tcp` | `pancake_net_transport_tcp.h` | The complete TCP transport archive: `noise-tcp`, `keyed-tcp`, and testing `tcp`, plus low-level blocking framed connections for a byte-fed Host. |
| `libpancake_net_transport_inproc` | `pancake_net_transport_inproc.h` | In-process connections for tests and local scenarios. |

The driver archive starts with zero transports. For a sealed in-tree path,
create a `PancakeTcpNetlayer`, call `pancake_tcp_transport_provider`, and pass
the result to `pancake_driver_add_provider`; use `noise-tcp` from that package.
For encrypted QUIC, create a `PancakeIrohNetlayer` and install
`pancake_iroh_transport_provider` the same way. The TCP package also owns
`keyed-tcp` and testing `tcp`; the driver only consumes the common provider ABI.
The same TCP archive exposes the low-level blocking framed connections for
embedders that drive `libpancake_host` themselves. A key-addressed listener
publishes one complete locator. Read it with
`pancake_driver_listener_locator`, parse it through
`pancake_uri_parse_peer`, and pass those fields to `pancake_driver_dial`
unchanged.

Provider installation, listener close, and final driver release take a
caller-owned `PancakeDriverFailure`. Set its `abi_version` to
`PANCAKE_DRIVER_FAILURE_ABI_VERSION` and its `struct_size` to
`sizeof(PancakeDriverFailure)` before each call. A refusal or teardown failure
then returns the stable result, exact primary name, first cleanup consequence,
and total consequence count without making thread-local diagnostic text part
of the program's control flow. The names in that record have process lifetime.
If listener close returns `PANCAKE_ERR_WOULD_BLOCK`, the stop is committed but
its provider barrier is still pending. Keep the listener id, continue stepping
the driver, and retry after retirement. A failed asynchronous stop instead
arrives once as `PANCAKE_DRIVER_EVENT_LISTENER_FAILED` with the same exact
failure record.

The relay archive takes declarative routes and trust policy. System roots are
the default for WSS. A process owner may instead pass copied PEM bytes; the
runtime owns one immutable parsed snapshot and never retains a path or rescans
per connection. Listener close returns the provider's exact stop/cancellation
primary and first cleanup consequence through that record; thread-local text
is never the machine contract for a teardown barrier. The same archive selects
`ws` or `wss` for a locator-carried
route, and a program that does not link the relay archive does not link Mbed
TLS.

Link `libpancake_ocapn`, `libpancake_host`, and `libpancake_driver` when linking
the native loop. Link only `libpancake_ocapn` and `libpancake_host` when the
application owns the byte-fed loop. Add the TCP archive and any sidecar
transport archives whose providers you install. The generated headers are
checked against their Zig declarations on every build.

## Drive the byte-fed Host

`PancakeHost` does not own sockets. A runtime opens a Host session, associates
it with a transport connection, and repeats three operations:

1. feed received bytes with `pancake_host_session_feed_bytes`;
2. run resulting work with `pancake_host_pump_drain`;
3. take outbound frames with `pancake_host_session_take_outbound`; write the
   returned prefix bytes, then the frame bytes.

`feed_bytes` accepts canonical Syrup byte strings (`length:body`) and owns split
or coalesced input plus the bounded tail. Whole-frame `feed` and
`take_outbound` stay bare for intrinsically message-framed transports. If
`feed` or `feed_bytes` returns `PANCAKE_ERR_WOULD_BLOCK`, the session already
has too many encoded outbound bytes queued; drain `take_outbound`, write those
frames, then retry the feed.

The pump hooks handle flushes, completed promises, handoff dials, and gift-id
requests. Hosted behavior callbacks run synchronously while the Host is being
driven. Do not block or re-enter the same Host from one of those callbacks.

[`examples/c/host_embedder_pump.c`](../examples/c/host_embedder_pump.c) shows
the feed, drain, refusal, and break-far-vows choreography used by the language
bindings. [`examples/c/frame_view.c`](../examples/c/frame_view.c) shows a
borrowed `PancakeFrame` view over caller-owned bytes. Owned frames are
`PancakeManagedFrame` values from `take_outbound` in the host example.
`zig build examples` compiles and runs both.

## One opaque capability type

Every application-held capability is:

```c
typedef struct PancakeReference {
    uint64_t id;
} PancakeReference;
```

The id is meaningful only to the `PancakeHost` that issued it. C does not
inspect near/far, object/promise, import/export position, or handoff-token
variants. Those are session and wire projection details owned by the Host.

Values returned by fetch, enlivenment, calls, delivered arguments, publish,
spawn, and handoff all use this same type. Passing a reference on another
session of the same Host needs no enrollment step when the Host can route it;
local actors live in the Vat owned by the Host and are projected onto destination Ports only
as needed.
Return an application retain with `pancake_host_ref_release`; stale and
foreign-Host ids fail closed.

Promise answers remain separate `uint64_t` vow handles; only a resolved
`PancakeReference` is a passable target identity.

## Host ownership versus session projection

| Operation | Host owns | Session selects |
| --- | --- | --- |
| `pancake_host_publish` | One actor and one replaceable Host-wide alias. | Nothing until a fetch or `published_ref` lazily creates a Port projection. |
| `pancake_host_session_publish` / `_spawn` | The actor and its callback lifetime, through Host teardown. | The initial bootstrap name or projection on that session's Port. |
| Send, tell, and turn verbs | The opaque capability identity and routing decision. | The peer/Port used when a route needs session context. The Host owns the actor. |

Closing the session that first published or spawned an actor removes that Port,
not the actor. A capability already projected through another Port remains
callable; the behavior context is released when the Host drops the actor graph.

`pancake_host_reference_exporter` has one narrow purpose: after a three-party
handoff, bindings use it to recover the direct exporter session that a redeemed
reply routes through, for back-channel hosting. Ordinary references route
through the Host and usually have no unique exporter session.

## Locators and transports

Use `pancake_uri_parse_peer`, `pancake_uri_format_peer`, and the sturdyref URI
helpers instead of parsing `ocapn://` strings yourself. Host verbs take a
borrowed `PancakeLocatorView`; owned locator handles project the same view with
`pancake_locator_borrow_view`. Sturdyref parse and format also require the
CapTP version: swiss-number path form belongs to the negotiated profile,
so the C ABI refuses to infer or default it.

The C transport archives are iroh, WebRTC, onion, relay, TCP, and in-process.
Each carries bytes for a Host session and does not own CapTP state. Noise TCP
and keyed TCP live in the TCP package; Noise relay and keyed relay live in the
relay package. iroh and WebRTC use Rust sidecars and therefore require Cargo
when those optional archives are built.

TCP, in-process, and onion expose explicit blocking frame shuttles. Their
listener readiness descriptors keep an embedder from entering `accept` before
the operation can start, but readiness is advisory and a whole-frame read can
still wait for the rest of a fragmented frame. Dispatch those calls away from
an event-loop thread, or use a binding's runtime-native transport adapter.

## Shutdown

Stop new calls in the embedding, then call `*_shutdown`. Join the embedding's
operation leases, then call `*_release`. Release must not race a thread that
can still begin a call. Release children before their netlayer. The TCP and
onion netlayers each own their `std.Io` backend and reserve one cancellation
worker per netlayer so shutdown stays nonblocking. iroh and WebRTC use
readiness plus non-blocking try-I/O instead of the blocking frame shuttle.

## Ownership

The headers document ownership beside every declaration. Four rules cover the
surface:

1. Input pointers are borrowed for the duration of the call.
2. An owned result has a matching release function.
3. A handle is released by the family that created it.
4. Operation-result out parameters are initialized only when a call returns
   `PANCAKE_OK`; the optional diagnostic length described below is independent
   of the operation result.

Constructors ending in `_in` allocate through the `PancakeContext` supplied by
the caller. `PancakeManagedFrame` owns its bytes and must be released exactly
once. A `PancakeReference` is an integer value, but its Host retain is explicit
and must be returned with `pancake_host_ref_release`. This applies to every
reference leaf surfaced in a callback argument or SETTLE action as well as a
top-level `out_ref`; the containing bytes may be borrowed while the capability
retain is owned.

## Errors and threads

Most functions return `int32_t`. `PANCAKE_OK` is zero; named errors are
negative. Each archive has a thread-local diagnostic reader matching its
family: `pancake_last_error`, `pancake_host_last_error`,
`pancake_tcp_last_error`, and transport equivalents. Every status-returning
call clears its archive's slot before validation. Read the slot immediately
after a failing call: zero length means that result has no additional detail.
A later success or undetailed refusal cannot inherit an older call's cause.

Read that slot on the same thread that made the failing call. Blocking transport
operations also end with the optional `out_error`, `error_cap`, and
`out_error_len` arguments. A synchronous caller may omit all three with
`NULL, 0, NULL`. A foreign runtime that dispatches the call to a worker supplies
`out_error_len` and optional caller-owned storage; the function copies that
worker's diagnostic before returning. A partial request—buffer or nonzero
capacity without a length slot—is rejected before the operation begins. This is
one call contract, including `pancake_iroh_netlayer_new` and its allocator-aware
`_in` form, rather than a second diagnostic API to select correctly.

Serialize calls on one Host behind one thread or lock. Distinct Hosts are
independent. A binding that exposes an event-loop owner should reject
foreign-thread Host calls or marshal teardown back to the owning loop; the C
Host itself is unsynchronized.

Stream transport connections are full-duplex: one frame read and one frame
write may run concurrently. The archive serializes calls within each direction
because frame decoding and encoding carry connection-local state. Shutdown may
interrupt either direction; release still requires the foreign owner to stop
new calls and join its own call leases before freeing the opaque handle.

## Learn from a binding

Rust, TypeScript, Python, and Racket consume this same Host ABI. Their pumps,
trampolines, and release paths are runnable examples for embedding pancake in a
language runtime; see the [binding contract](../bindings/README.md).
