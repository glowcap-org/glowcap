# bindings/

Per-language consumers of the Zig `libpancake` C ABI. Each binding dogfoods the
C ABI as a real foreign-language consumer. That is what catches wire-shape and
ABI regressions that only surface through an actual FFI consumer.

## The application surface (what you build against)

An application holds one thing: a `Connection`. It composes a peer, a vat, and the
language's async I/O into a single object, so a consumer never stitches those
layers together by hand. The application vocabulary is small and shared across
the bindings:

| Verb | What it does |
| --- | --- |
| `connect(host, port)` | Dial a server over TCP, return a `Connection` |
| `listen(host, port)` | Accept TCP connections, yield a `Connection` each |
| `connect_iroh_uri(uri)` | Dial a peer over iroh from its `ocapn://…iroh?…` URI (optional iroh artifact) |
| `listen_iroh()` | Bind an iroh endpoint; its `uri` is what a partner dials (optional iroh artifact) |
| `conn.publish(name, behavior)` | Make a local actor fetchable by name (a swiss number) |
| `conn.fetch(name)` | Fetch a partner's published capability by name; returns a `Ref` |
| `conn.spawn(behavior)` | Create a local actor; returns a `Ref` that auto-marshals in args |
| `conn.send(ref, verb, args)` | Call a method on a capability and await the reply |
| `conn.tell(ref, verb, args)` | Fire-and-forget send (Goblins `<-np`): no answer, no reply. Use it for notifications and broadcasts. |
| `conn.serve()` | Run the inbound event loop (resolves on close, rejects on error) |
| `conn.close()` | End the connection |

A `Ref` is an opaque capability. Pass it as a `send` argument and it marshals to
the right wire reference automatically. Application code never constructs
`near`/`far` references and never manages export-position numbers.

Each language renders the surface in its own idiom. Deno returns native
`Promise`s and supports `using`. Python uses coroutines and `async with`. Rust
returns `impl Future` from a `!Send` `Connection`; create and use it on one task
inside a `LocalSet`. Racket keeps the Goblins verbs, including `spawn`, `$`, `<-`,
`on`, `bcom`, and `methods`, and adds `connect`, `conn-fetch`, and `conn-send`. Native
Zig speaks the same verbs through one owning `driver.Connection`: `driver.connect`
dials and `driver.listen` hosts (each `accept` hands back a connection), `call`
drives one request to its reply, and a hosted connection runs under `serve` or one
explicit `step` at a time. The buffer-explicit spellings, `driver.connectTcp` and
`driver.acceptTcp`, stay public for a caller that owns the peer and buffers at the
call site. A selector a binding
exposes follows the same discipline: profile and codec are spelled in each
language's idiom (a string union, a symbol, an enum), and a selector parameter
accepts every value the library supports, not a single hard-wired one.

Every binding hosts as well as dials. Deno and Python yield a `Connection` per
accepted partner from `listen`. Rust binds a `Server` whose `accept` returns one.
Racket's `(accept (listen host port))` returns the same `connection` that
`connect` does.

The raw peer (`conn.peer`) remains available beneath the application surface. Use
it when an application needs handoff, promise pipelining, session control, or
fixed-position interop with a partner that expects a known export slot. No example
application needs that lower-level path; the [`examples/apps/`](../examples/apps/)
clients are built entirely on the surface above.

One binding-specific shape remains, and it follows Rust's async model. Rust's
`tell` returns once the deliver is queued on the driver task, and that task
flushes it. The other bindings await the flush directly. Replies still behave the
same way in every binding. A `send` or `tell` to a `Ref` spawned by the same
connection resolves in process everywhere; Rust routes that hosted export to a
local turn on the driver task, the same as Deno and Python.

## The C ABI surface today

The `Connection` and actor layers above are pure composition over the C ABI. The
ABI itself stays small and C-shaped. The current `pancake.h` exposes these groups:

- **Allocation context.** A `PancakeContext` owns allocation policy for a handle
  family. Create one with `pancake_context_new` or
  `pancake_context_new_with_allocator`, and release it with
  `pancake_context_release`. The `*_in` constructors, such as
  `pancake_peer_new_in` and `pancake_tcp_netlayer_new_in`, allocate peers,
  netlayers, and every managed frame and buffer through that context. By default
  they use the library allocator; a host can supply `alloc` and `free` callbacks.
- **Peer and frame primitives.** A binding can create a peer, feed it borrowed or
  owned frames, step it, take outbound frames, poll events, and release returned
  frames and events explicitly. `pancake_peer_new` and `pancake_peer_new_in`
  create negotiating, authenticated v1.0 peers over Syrup;
  `pancake_peer_new_negotiated` and `_negotiated_in` carry an out-of-band
  negotiated profile and codec when the ends agreed on something else.
  `pancake_peer_new_raw_open` and
  `_raw_open_in` are fixture constructors for tests that inject frames directly.
- **Sans-I/O stream input.** `pancake_peer_recv_stream` reads from a raw
  byte-stream buffer, finds one frame with the active codec's parser, dispatches
  it, and reports how many bytes it consumed. For a partial frame it returns
  `PANCAKE_ERR_WOULD_BLOCK`. The peer never blocks and owns no socket, so a
  binding can drive it from the language's own event loop.
- **Bootstrap serving and fetching.** `pancake_peer_register_bootstrap_cap`
  publishes a local capability behind a swiss number so a partner can fetch it
  through the bootstrap object, and `pancake_peer_send_bootstrap_fetch` queues
  the canonical fetch for a partner's published capability, so no binding
  re-encodes the `fetch` deliver by hand.
- **Typed OCapN driving surface (ADR-0031).** `pancake_peer_send_deliver` and
  `pancake_peer_send_resolve` construct calls and replies from fixed-layout
  `PancakeReference` and `PancakeArgument` structs, and `pancake_peer_send_gc_export`
  and `pancake_peer_send_gc_answer` emit the GC release verbs so a long-lived
  session does not strand table rows. `pancake_peer_peek_event`,
  `pancake_peer_poll_event_deliver`, and `pancake_peer_poll_event_resolve` read
  inbound deliveries and resolutions as structured values; a value the typed
  surface cannot carry (e.g. a handoff argument) leaves the event queued, and
  the consumer drains it with the opaque `pancake_peer_poll_event`, reading the
  raw frame in the codec `pancake_peer_codec` reports.
  `pancake_peer_register_export` and `pancake_peer_register_import` name the
  served and called positions, and `pancake_peer_next_export` and
  `pancake_peer_next_answer` allocate fresh export and answer positions from the
  session's own counters, so a binding never mints a position that aliases a
  live one. This is what lets a binding drive OCapN directly instead of
  shuttling opaque frames.
- **Per-thread last error.** `pancake_last_error` and `pancake_clear_last_error`
  expose the concrete socket cause behind a flat `PANCAKE_ERR_IO`.
- **Blocking TCP endpoint handles (cleartext; no TLS).** The endpoint API is an
  explicit handle for the I/O backend: create and release the tcp netlayer, dial
  or listen, accept, read and write whole frames, read the listener port, and close
  the connection or listener. The host owns the peer. It reads a frame, feeds it
  to the peer, steps the peer, takes outbound frames, and writes them back.
  Framing uses the active codec's one parser, selected through `PANCAKE_CODEC_*`;
  `pancake_peer_new_negotiated` constructs a peer whose session speaks the same
  codec, so a Cap'n Proto conversation is reachable over the ABI end to end.
  The C side never names `std.Io`; the netlayer handle owns it explicitly, with no
  hidden runtime. This endpoint is cleartext and loopback-grade. A real transport
  such as TLS or QUIC would layer above the same adapter. See
  [ADR-0030](../docs/decisions/adr/ADR-0030-netlayer-connection-and-memory-posture.md).

The shared library still carries no TLS and no background run loop.
Crossed-hellos detection lives above the endpoint handles. A host coordinates a
registry across connections and asks the peer to emit the typed abort; the C ABI
does not hide a runtime that does it for you.

The C ABI default peer posture is an authenticated v1.0 negotiation:
`pancake_peer_new` creates a negotiating peer and
`pancake_peer_start_session` signs canonical location bytes from caller-supplied
seed material. Already-open peers exist only as `pancake_peer_new_raw_open` /
`_raw_open_in` for low-level fixtures. The Deno, Python, Rust, and Racket Goblins
interop steps each drive the authenticated path over the C ABI.

Each binding is a real foreign-language consumer of the installed pancake
artifacts. Rust links the installed static library. Deno, Python, and Racket load
the installed shared library. Each binding ships an idiomatic API over the whole
C ABI, and the raw FFI stays private. A consumer touches a `Peer` that releases
itself, native values as call arguments, typed events, and a
`Netlayer`/`Listener`/`Endpoint` for running a peer over a real TCP socket. The
dogfood consumer in each binding drives a real OCapN round-trip through that API:
it constructs a call, reads a delivery as structured values, and runs a peer over
a loopback socket, both synchronously and through the language-native async layer.

| Binding | Idiomatic API | Dogfood consumer |
| --- | --- | --- |
| [`rust/`](rust/) | `src/lib.rs` (`Peer`, `Reference`/`Argument`/`Event` enums) | `cargo test` |
| [`deno/`](deno/) | `pancake.ts` (`Peer` class, discriminated-union values) | `zig_smoke.ts` |
| [`python/`](python/) | `pancake.py` (`Peer`, native Python values) | `zig_smoke.py` |
| [`racket/`](racket/) | `pancake.rkt` (`peer`, native Racket values, event structs) | `zig-smoke.rkt` |

Each binding also exposes an async connection in its language-native idiom. It
drives the same sans-io peer over its own non-blocking sockets through
`pancake_peer_recv_stream`. There is no blocking C netlayer in that path and no
thread per call.

| Binding | Async idiom | Async type |
| --- | --- | --- |
| [`rust/`](rust/) | tokio (opt-in `async` feature) | `AsyncConnection` over `tokio::net::TcpStream` |
| [`deno/`](deno/) | native promises | `AsyncConnection` over `Deno.connect`/`Deno.listen` |
| [`python/`](python/) | `asyncio` | `AsyncConnection` over `asyncio` streams |
| [`racket/`](racket/) | green threads + ports | `async-connection` over `tcp-connect`/`tcp-listen` |

One async connection owns one peer, because the peer is a single-owner state
machine. It lives on one task or thread as a connection actor. The peer calls do
no I/O and never block the event loop; only the socket reads and writes await.

The inbox each connection accumulates is bounded by the library, not by binding
code: a connection keeps reading only while `recv_stream` answers "partial frame,
read more", and a frame that cannot complete within the peer's `max_frame_bytes`
is refused with the typed `FRAME_TOO_LARGE` error the moment that is knowable.
That can be when its length prefix declares past the cap or when its bytes have
already crossed it (ADR-0041). Every binding's smoke pins this, so a hostile
partner cannot grow a binding's inbox without bound.

The outbound side is bounded by write discipline rather than a queue: every
binding awaits or blocks on its socket writes frame by frame (Deno `writeAll`,
Rust `write_all(...).await`, Python `write` plus an awaited `drain()` per
pump, Racket blocking `write-bytes`), so a partner that stops reading stalls
the connection's pump instead of growing a buffer. That is the same posture as
the Zig blocking pump: bounded memory, with the tradeoff that a write to a slow
reader can head-of-line-block that one connection. The Zig completion loop's high-water
read parking
([ADR-0042](../docs/decisions/adr/ADR-0042-outbound-high-water-backpressure.md))
is the many-connection alternative; no binding exposes a loop of that shape.

Each async surface also speaks its runtime's native async sequences, so a consumer
reads events as a stream and awaits a send's result rather than polling and
registering callbacks. The `nextEvent`/`on` style still works underneath; these
are additive:

| Binding | Event stream | Awaited send |
| --- | --- | --- |
| [`deno/`](deno/) | `for await (const event of conn)` | `await vat.send(ref, verb, args)` |
| [`python/`](python/) | `async for event in conn` | `await vat.send(ref, verb, args)` |
| [`racket/`](racket/) | `(in-async-events conn)` sequence | `(on vow handler)` |
| [`rust/`](rust/) | a task handle over `tokio::sync::mpsc` | `Vat::send(...).await` shape |

The `examples/apps/rooms/` clients each build a small `Room` on this surface, so
the app above reads like an app in every language.

Each binding also exposes a Goblins-shaped **actor layer** in its own idiom,
built on the typed peer surface (no extra C ABI). A `Vat` holds local actors and,
when bound to a peer, routes eventual-sends to partner-hosted references over the
wire. `publish` binds a local actor to a peer export, so an inbound deliver runs
the actor and resolves the answer with its reply. A leading symbol argument is the
method verb. An actor is the language's native callable, such as a Rust closure or
a Python callable, not a foreign callback. That mirrors how `pancake.actors` is
native Zig.

| Binding | Actor idiom |
| --- | --- |
| [`racket/`](racket/) | **Goblins-faithful**: `(define (^name bcom arg …) …)` constructors, `methods`, `spawn`, `$` (near), `<-`/`<-np` (eventual), `on`, `bcom`, `with-vat` |
| [`rust/`](rust/) | `actors::Vat` over `FnMut(&str, &[Argument])` closures |
| [`deno/`](deno/) | `Vat` over `(verb, args) => Argument` callbacks |
| [`python/`](python/) | `Vat` over `behavior(verb, args)` callables |

The Racket layer is the reference shape because it reads like Spritely Goblins,
the way a Racket distributed-systems programmer expects. The model is uniform
across all four bindings and Zig's `pancake.actors`: a reference is local or far,
`$` is the synchronous near-call and only works locally, `<-` is the
location-transparent eventual-send that returns a promise, and an inbound deliver
to a published actor runs a turn and resolves the answer. Every binding proves a
far-send round-trip in its smoke by sending `<-` to a partner-hosted actor and
observing the answer settle the promise.

Each idiomatic layer maps the same value model. Integers, floats, booleans, bytes,
strings, symbols, references, and lists use the language's own types. References
use small constructors such as `Far(5)`, `far(5n)`, or `(far 5)`. Polling returns
typed `Deliver`, `Resolve`, and other events. Bootstrap serving and TCP networking
are exposed as library concepts, with a blocking netlayer for whole-frame
shuttling and the language-native async layer above it.

The carried value set spans the model's passable tree (ADR-0031): integers,
floats, booleans, bytes, strings, symbols, references, lists, sets, tagged
records, and keywords all marshal in the language's own types. Handoff arguments
and sturdy or broken targets are refused loudly with
`PANCAKE_ERR_UNSUPPORTED_VALUE`. For socket transport `libpancake` carries only
blocking, cleartext TCP (no TLS) alongside a socket-free in-process
netlayer (`pancake_inproc_*`, designator-addressed) for two-peer conversations in
one process. pancake's one encrypted netlayer, iroh, rides the separate artifact below.

## The iroh transport (optional, a separate artifact)

iroh's encrypted QUIC reaches the bindings as a **separate optional library**,
not folded into `libpancake`: it links a Rust sidecar
([ADR-0055](../docs/decisions/adr/ADR-0055-iroh-netlayer-sidecar.md)), and
keeping it out of `libpancake` is what keeps the core pure Zig and the gate
hermetic. `zig build iroh-abi` (needs `cargo`) builds `libpancake_iroh` — a
*superset* of the `libpancake` ABI that adds the `pancake_iroh_netlayer_*` and
`pancake_iroh_conn_*` families (see
[`include/pancake_iroh.h`](../include/pancake_iroh.h)). A binding that
wants iroh loads that one library instead and gains `connect_iroh` /
`connect_iroh_uri` / `listen_iroh` alongside the TCP `connect` / `listen`.

Addressing is the only difference a consumer sees. There is no `host:port`: a
partner is reached by its self-authenticating endpoint id plus comma-separated
direct-address hints, carried together as an `ocapn://<nodeid>.iroh?direct-addresses=…`
URI (the signed locator uses `"iroh"` as its transport, carries the node id as
its designator, and puts the address hints under `direct-addresses`). Above that, nothing changes — `connect_iroh`
returns the same `Connection`, drives the same in-process pump, and speaks the
same OCapN. The iroh FFI blocks (the endpoint runs its own runtime), so each
binding keeps its event loop free the native way: Deno non-blocking FFI, Python
`asyncio.to_thread`, Rust `spawn_blocking` over an `AsyncRead`/`AsyncWrite`
adapter, Racket `#:blocking?` FFI. The `examples/apps/rooms/` clients dial a
transport-neutral locator, so `zig build demo-rooms-iroh` runs the same
cross-language room over iroh; a binding joins when its runtime and the iroh
library are both present.

## Running

```sh
zig build bindings        # rust + deno + python + racket smokes
zig build rust-dogfood    # just the Rust consumer
```

`zig build bindings` requires `cargo`, `deno`, `python3`, and `racket` on PATH —
provided by [`../.devcontainer/`](../.devcontainer/). The libraries are built and
installed under `../zig-out/lib/` first; each consumer resolves the artifact it
uses relative to its own location.
