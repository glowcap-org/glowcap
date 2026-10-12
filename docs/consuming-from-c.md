# Using glowcap from C

The C application surface is `GlowcapHost`. It owns CapTP sessions, routing,
hosted objects, promises, handoff, and opaque capability identities while your
runtime owns I/O and scheduling. Native Zig still exposes `engine.Peer` for
low-level protocol work, and C has no equivalent of that internal type.

[`glowcap_ocapn.h`](../include/glowcap_ocapn.h) supplies shared ABI vocabulary:
contexts, frames, arguments, locators, and URI helpers.
[`glowcap_host.h`](../include/glowcap_host.h) supplies the CapTP application
surface. Transport headers supply connections and listeners and add no second
session API.

## Build the libraries

```sh
zig build
```

Headers are installed under `zig-out/include/`. Static and shared libraries are
installed under `zig-out/lib/`.

Static archives include the Zig compiler runtime they need. Native C compilers
can link them individually or together without a Zig compiler driver.

The embedding application owns signal handlers and alternate signal stacks.
The libraries disable Zig's automatic setup, so linking several archives does
not reserve an alternate stack per archive on every thread.

| Library | Header | Purpose |
| --- | --- | --- |
| `libglowcap_ocapn` | `glowcap_ocapn.h` | Shared values, locators, frames, and URI helpers. |
| `libglowcap_host` | `glowcap_host.h` | The byte-fed, multi-session CapTP host. |
| `libglowcap_driver` | `glowcap_driver.h` | The native loop: it exports only `glowcap_driver_*` and adopts an idle Host from `libglowcap_host` through `glowcap_driver_take_host`. |
| `libglowcap_loam` | `glowcap_loam.h` | Portable persistence, managed registration and storage effect ownership on the existing Host. |
| `libglowcap_loam_lmdb` | `glowcap_loam_lmdb.h` | Optional LMDB custody, startup creation/restoration and submitted storage execution. |
| `libglowcap_net_transport_iroh` | `glowcap_net_transport_iroh.h` | Optional encrypted QUIC transport. |
| `libglowcap_net_transport_webrtc` | `glowcap_net_transport_webrtc.h` | Optional WebRTC DataChannel transport. |
| `libglowcap_net_transport_onion` | `glowcap_net_transport_onion.h` | Tor onion services, through a Tor daemon you already run. The one transport the OCapN draft standardizes. |
| `libglowcap_net_transport_relay` | `glowcap_net_transport_relay.h` | Native `keyed-relay` and end-to-end sealed `noise-relay` provider package, with pollable `ws` and `wss` carriers. |
| `libglowcap_net_transport_tcp` | `glowcap_net_transport_tcp.h` | The complete TCP transport archive: `noise-tcp`, `keyed-tcp`, and testing `tcp`, plus low-level blocking framed connections for a byte-fed Host. |
| `libglowcap_net_transport_inproc` | `glowcap_net_transport_inproc.h` | In-process connections for tests and local scenarios. |

The driver archive starts with zero transports. To add `noise-tcp`, create a
`GlowcapTcpNetlayer`, call `glowcap_tcp_transport_provider`, and pass the
result to `glowcap_driver_add_provider`. iroh installs the same way through
`GlowcapIrohNetlayer` and `glowcap_iroh_transport_provider`. A key-addressed
listener publishes one complete locator. Read it with
`glowcap_driver_listener_locator`, parse it through
`glowcap_uri_parse_peer`, and pass those fields to `glowcap_driver_dial`
unchanged.

Provider installation, listener close, and final driver release take a
caller-owned `GlowcapDriverFailure`. Set its `abi_version` to
`GLOWCAP_DRIVER_FAILURE_ABI_VERSION` and its `struct_size` to
`sizeof(GlowcapDriverFailure)` before each call. A refusal or teardown failure
then fills in the result, the primary failure name, the first cleanup
consequence, and the consequence count. The names have process lifetime.
If listener close returns `GLOWCAP_ERR_WOULD_BLOCK`, the stop is committed but
its provider barrier is still pending. Keep the listener id, continue stepping
the driver, and retry after retirement. A failed asynchronous stop instead
arrives once as `GLOWCAP_DRIVER_EVENT_LISTENER_FAILED` with the same exact
failure record.

The relay archive takes declarative routes and trust policy, and picks `ws` or
`wss` from the locator. WSS trusts system roots by default, or PEM bytes you
pass in, parsed once. A program that does not link the relay archive does not
link Mbed TLS.

Link `libglowcap_ocapn`, `libglowcap_host`, and `libglowcap_driver` when linking
the native loop. Link only `libglowcap_ocapn` and `libglowcap_host` when the
application owns the byte-fed loop. Add the TCP archive and any optional
transport archives whose providers you install. The generated headers are
checked against their Zig declarations on every build.

Before minting sessions, selectively override Host policy with a caller-owned
`GlowcapSessionLimitOptions`. Set `abi_version` to
`GLOWCAP_SESSION_LIMIT_OPTIONS_ABI_VERSION` and `struct_size` to
`sizeof(GlowcapSessionLimitOptions)`. Zero fields keep the current policy.
Sessions already open keep the limits they were minted with.

## Drive the byte-fed Host

`GlowcapHost` does not own sockets. A runtime opens a Host session, associates
it with a transport connection, and repeats three operations:

1. feed received bytes with `glowcap_host_session_feed_bytes`
2. run resulting work with `glowcap_host_pump_drain`
3. take outbound frames with `glowcap_host_session_take_outbound`. Write the
   returned prefix bytes, then the frame bytes.

`feed_bytes` accepts canonical Syrup byte strings (`length:body`) and owns split
or coalesced input plus the bounded tail. Whole-frame `feed` and
`take_outbound` stay bare for intrinsically message-framed transports. If
`feed` or `feed_bytes` returns `GLOWCAP_ERR_WOULD_BLOCK`, the session already
has too many encoded outbound bytes queued. Drain `take_outbound`, write those
frames, then retry the feed.

The pump hooks handle flushes, completed promises, handoff dials, and gift-id
requests. Hosted behavior callbacks run synchronously while the Host is being
driven. Do not block or re-enter the same Host from one of those callbacks.

[`examples/c/host_embedder_pump.c`](../examples/c/host_embedder_pump.c) shows
the feed, drain, refusal, and break-far-vows sequence the language bindings
use. [`examples/c/frame_view.c`](../examples/c/frame_view.c) shows a
borrowed `GlowcapFrame` view over caller-owned bytes. Owned frames are
`GlowcapManagedFrame` values from `take_outbound` in the host example.
`zig build examples` compiles and runs both.

## One opaque capability type

Every application-held capability is:

```c
typedef struct GlowcapReference {
    uint64_t id;
} GlowcapReference;
```

The id is meaningful only to the `GlowcapHost` that issued it. C does not
inspect near/far, object/promise, import/export position, or handoff-token
variants. Those are session and wire projection details owned by the Host.

Fetch, enlivenment, calls, delivered arguments, publish, spawn, and handoff all
return this type. Passing a reference on another session of the same Host needs
no extra step when the Host can route it. Return an application retain with
`glowcap_host_ref_release`. Stale and foreign-Host ids fail closed.

Promise answers remain separate `uint64_t` vow handles. Only a resolved
`GlowcapReference` is a passable target identity.

## Host ownership versus session projection

| Operation | Host owns | Session selects |
| --- | --- | --- |
| `glowcap_host_publish` | One actor and one replaceable Host-wide alias. | Nothing until a fetch or `published_ref` lazily creates a Port projection. |
| `glowcap_host_session_publish` / `_spawn` | The actor and its callback lifetime, through Host teardown. | The initial bootstrap name or projection on that session's Port. |
| Send, tell, and turn verbs | The opaque capability identity and routing decision. | The peer/Port used when a route needs session context. The Host owns the actor. |

Closing the session that first published or spawned an actor removes that Port,
not the actor. A capability already projected through another Port remains
callable. The behavior context is released when the Host drops the actor graph.

After a three-party handoff, bindings use `glowcap_host_reference_exporter` to
recover the direct exporter session that a redeemed
reply routes through, for back-channel hosting. Ordinary references route
through the Host and usually have no unique exporter session.

## Locators and transports

Use `glowcap_uri_parse_peer`, `glowcap_uri_format_peer`, and the sturdyref URI
helpers instead of parsing `ocapn://` strings yourself. Host verbs take a
borrowed `GlowcapLocatorView`. Owned locator handles project the same view with
`glowcap_locator_borrow_view`. Sturdyref parse and format also require the
CapTP version: swiss-number path form belongs to the negotiated profile,
so the C ABI refuses to infer or default it.

Transport archives carry bytes for a Host session and own no CapTP state. iroh
and WebRTC are built from Rust, so building them needs Cargo.

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
   `GLOWCAP_OK`. The optional diagnostic length described below is independent
   of the operation result.

Constructors ending in `_in` allocate through the `GlowcapContext` supplied by
the caller. `GlowcapManagedFrame` owns its bytes and must be released once. Do
not inspect or modify its opaque private words. A `GlowcapReference` is an
integer, but its Host retain is explicit and must be returned with
`glowcap_host_ref_release`, including every reference inside a callback argument
or SETTLE action. The surrounding bytes may be borrowed while the retain is
owned.

## Errors and threads

Most functions return `int32_t`. `GLOWCAP_OK` is zero. Named errors are
negative. Each archive has a thread-local diagnostic reader matching its
family: `glowcap_last_error`, `glowcap_host_last_error`,
`glowcap_tcp_last_error`, and transport equivalents. Every status-returning
call clears its archive's slot first, so read it immediately after a failing
call. Zero length means no additional detail.

Read that slot on the same thread that made the failing call. Blocking transport
operations also end with the optional `out_error`, `error_cap`, and
`out_error_len` arguments. A synchronous caller may omit all three with
`NULL, 0, NULL`. A foreign runtime that dispatches the call to a worker supplies
`out_error_len` and optional caller-owned storage. The function copies that
worker's diagnostic before returning. A buffer or nonzero capacity without a
length slot is rejected before the operation begins. `glowcap_iroh_netlayer_new`
and its `_in` form follow the same contract.

A failure with no call left to return it, such as a finalizer refusing or a
retirement failing after the request that started it has returned, goes to the
`GlowcapContext` that owns the Host as one typed record. Drain that journal
with `glowcap_context_next_failure` when your application decides how to
respond. A full journal drops its oldest record and counts the loss on the
next one.

Serialize calls on one Host behind one thread or lock. Distinct Hosts are
independent. A binding that exposes an event-loop owner should reject
foreign-thread Host calls or marshal teardown back to the owning loop. The C
Host itself is unsynchronized.

Stream transport connections are full-duplex: one frame read and one frame
write may run concurrently. The archive serializes calls within each direction
because frame decoding and encoding carry connection-local state. Shutdown may
interrupt either direction. Release still requires the foreign owner to stop
new calls and join its own call leases before freeing the opaque handle.

## Learn from a binding

Rust, TypeScript, Python, and Racket consume this same Host ABI. Their pumps,
trampolines, and release paths are runnable examples for embedding glowcap in a
language runtime. See the [binding contract](../bindings/README.md).

## Persistent resources

The optional Loam archives attach persistence to the existing Host. Their
[resource lifecycle guide](loam/c-and-rust.md) specifies startup, copied
declarations, borrowed callback contexts, worker retirement, completion
consumption, recovery, and shutdown. The generated
[portable header](../include/glowcap_loam.h) and
[LMDB header](../include/glowcap_loam_lmdb.h) describe each callable boundary.
