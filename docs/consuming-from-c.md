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
| `libpancake_net` | none | Common transport base; no public calls by itself. |
| `libpancake_net_transport_tcp` | `pancake_net_transport_tcp.h` | TCP connections and listeners. |
| `libpancake_net_transport_inproc` | `pancake_net_transport_inproc.h` | In-process connections for tests and local scenarios. |
| `libpancake_net_transport_iroh` | `pancake_net_transport_iroh.h` | Optional encrypted QUIC transport. |
| `libpancake_net_transport_webrtc` | `pancake_net_transport_webrtc.h` | Optional WebRTC DataChannel transport. |

Link `libpancake_host`, `libpancake_ocapn`, and the transport companions your
program uses. The generated headers are checked against their Zig declarations
on every build.

## Drive the byte-fed Host

`PancakeHost` does not own sockets. A runtime opens a Host session, associates
it with a transport connection, and repeats three operations:

1. feed received bytes with `pancake_host_session_feed_bytes`;
2. run resulting work with `pancake_host_pump_drain`;
3. take frames with `pancake_host_session_take_outbound` and write them.

The pump hooks handle flushes, completed promises, handoff dials, and gift-id
requests. Hosted behavior callbacks run synchronously while the Host is being
driven. Do not block or re-enter the same Host from one of those callbacks.

[`examples/c/host_embedder_pump.c`](../examples/c/host_embedder_pump.c) shows
the feed, drain, refusal, and EOF choreography used by the language bindings.
[`examples/c/frame_view.c`](../examples/c/frame_view.c) shows owned frames and
borrowed views. `zig build examples` compiles and runs both.

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

Promise answers remain separate `uint64_t` vow handles because an unresolved
answer is not a passable target identity.

## Host ownership versus session projection

| Operation | Host owns | Session selects |
| --- | --- | --- |
| `pancake_host_publish` | One actor and one replaceable Host-wide alias. | Nothing until a fetch or `published_ref` lazily creates a Port projection. |
| `pancake_host_session_publish` / `_spawn` | The actor and its callback lifetime, through Host teardown. | The initial bootstrap name or projection on that session's Port. |
| Send, tell, and turn verbs | The opaque capability identity and routing decision. | The peer/Port used when a route needs session context; it is not the actor's owner. |

Closing the session that first published or spawned an actor removes that Port,
not the actor. A capability already projected through another Port remains
callable; the behavior context is released when the Host drops the actor graph.

`pancake_host_reference_exporter` has one narrow purpose: after a three-party
handoff, bindings use it to recover the direct exporter session that a redeemed
reply routes through, for back-channel hosting. Ordinary references route
through the Host and usually have no unique exporter session.

## Locators and transports

Use `pancake_uri_parse_peer`, `pancake_uri_format_peer`, and the sturdyref URI
helpers instead of parsing `ocapn://` strings yourself. Use
`pancake_locator_record_encode` when a Host verb needs the encoded
`<ocapn-peer>` record.

TCP, in-process, iroh, and WebRTC connections all carry bytes for a Host
session. They do not own CapTP state. iroh and WebRTC use Rust sidecars and
therefore require Cargo when those optional archives are built.

## Ownership

The headers document ownership beside every declaration. Four rules cover the
surface:

1. Input pointers are borrowed for the duration of the call.
2. An owned result has a matching release function.
3. A handle is released by the family that created it.
4. Out parameters are initialized only when a call returns `PANCAKE_OK`.

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
`pancake_tcp_last_error`, and transport equivalents.

Serialize calls on one Host behind one thread or lock. Distinct Hosts are
independent.

## Learn from a binding

Rust, TypeScript, Python, and Racket consume this same Host ABI. Their pumps,
trampolines, and release paths are runnable examples for embedding pancake in a
language runtime; see the [binding contract](../bindings/README.md).
