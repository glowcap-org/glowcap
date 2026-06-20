# bindings/

Per-language consumers of the pancake C ABI archives. Each binding dogfoods the
C ABI as a real foreign-language consumer. That is what catches wire-shape and
ABI regressions that only surface through an actual FFI consumer.

## The application surface (what you build against)

An application holds one thing: a `Connection`. It composes a peer, a vat, and
the language's async I/O into a single object, so a consumer never stitches
those layers together by hand. The application vocabulary is small and shared
across the bindings:

| Verb                           | What it does                                                                                                                                                                                           |
| ------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `connect(locator)`             | **The one dialer.** Dial a peer from its `ocapn://` locator, whatever the transport — a `tcp` locator needs nothing else, an `iroh` locator adds a reachability posture. There is no `host:port` dial. |
| `tcp_locator(host, port)`      | Build a `tcp` locator (`ocapn://host:port.tcp`) from a literal address, to pass to `connect`                                                                                                           |
| `listen(host, port)`           | Accept TCP connections, yield a `Connection` each                                                                                                                                                      |
| `listen_iroh()`                | Bind an iroh endpoint; its `uri` is what a partner dials with `connect` (optional iroh artifact)                                                                                                       |
| `conn.publish(name, behavior)` | Make a local actor fetchable by name (a swiss number)                                                                                                                                                  |
| `conn.fetch(name)`             | Fetch a partner's published capability by name; returns a `Ref`                                                                                                                                        |
| `conn.enliven(sturdyref)`      | Bring a durable `ocapn://…/s/<swiss>` sturdyref to life on the open session; returns a `Ref`, with a dedup cache (ADR-0012)                                                                            |
| `conn.spawn(behavior)`         | Create a local actor; returns a `Ref` that auto-marshals in args                                                                                                                                       |
| `conn.caretaker(ref)`          | Wrap any `Ref` (local or far) in a revocable forwarding proxy; returns the proxy `Ref` plus a `revoke` lever — calls forward until revoked, then break `Revoked` (ADR-0064)                              |
| `conn.attenuate(ref, verbs)`   | Wrap any `Ref` in a proxy that forwards only the allow-listed `verbs` and breaks every other call `Attenuated` (ADR-0064)                                                                                |
| `conn.send(ref, verb, args)`   | Call a method on a capability and await the reply                                                                                                                                                      |
| `conn.tell(ref, verb, args)`   | Fire-and-forget send (Goblins `<-np`): no answer, no reply. Use it for notifications and broadcasts.                                                                                                   |
| `conn.serve()`                 | Run the inbound event loop (resolves on close, rejects on error)                                                                                                                                       |
| `conn.with_gc()`               | Opt this connection into distributed GC, off by default: a fetched `Ref`'s finalizer releases its import to the partner when collected (ADR-0063)                                                       |
| `conn.close()`                 | End the connection                                                                                                                                                                                     |

A `Ref` is an opaque capability. Pass it as a `send` argument and it marshals to
the right wire reference automatically. Application code never constructs
`near`/`far` references and never manages export-position numbers.

Each language renders the surface in its own idiom. Deno returns native
`Promise`s and supports `using`. Python uses coroutines and `async with`. Rust
returns `impl Future` from a `!Send` `Connection`; create and use it on one task
inside a `LocalSet`. Racket keeps the Goblins verbs, including `spawn`, `$`,
`<-`, `on`, `bcom`, and `methods`, and adds `connect`, `conn-fetch`, and
`conn-send`. Native Zig speaks the same verbs through one owning
`driver.Connection`: `driver.connect` dials and `driver.listen` hosts (each
`accept` hands back a connection), `call` drives one request to its reply, and a
hosted connection runs under `serve` or one explicit `step` at a time. The
buffer-explicit spellings, `driver.connectTcp` and `driver.acceptTcp`, stay
public for a caller that owns the peer and buffers at the call site. A selector
a binding exposes follows the same discipline: profile and codec are spelled in
each language's idiom (a string union, a symbol, an enum), and a selector
parameter accepts every value the library supports, not a single hard-wired one.

Every binding hosts as well as dials. Deno and Python yield a `Connection` per
accepted partner from `listen`. Rust binds a `Server` whose `accept` returns
one. Racket's `(accept (listen host port))` returns the same `connection` that
`connect` does.

Receiving a three-party handoff is transparent on the application surface: a
binding's `Connection` redeems a `desc:handoff-give` itself — its node router
dials the named exporter with the connection's retained identity, withdraws the
gift, and resolves the `send`/`fetch` to an ordinary capability that later sends
route to the exporter — so application code calls a handed-off capability
through the same `send` it uses for any other, never touching the give or the
second connection. It is proven per binding against a live Goblins introducer by
the `deno-goblins-handoff`, `python-goblins-handoff`, `rust-goblins-handoff`,
and `racket-goblins-handoff` build steps.

Originating a handoff is transparent too, across every binding: when a published
actor returns a `Ref` whose home is a different connection than the one asking,
the binding deposits the gift on the home connection and answers with a signed
`desc:handoff-give` — no choreography in application code. This rests on one
identity and one gift registry per node: a node's `Server`, `connect`, and
redeem connections share a `Node` (read it as `server.node`), so a gift
deposited on one connection is withdrawable on another and a pancake node serves
direct redeems as the exporter. It is proven by the `deno-gifter-handoff`
(all-pancake, broker out of the path), the per-binding `deno-goblins-gift`,
`python-goblins-gift`, `rust-goblins-gift`, and `racket-goblins-gift` gates
(pancake as gifter, live Goblins recipient + exporter), and `demo-rooms-dm`
(rooms direct-message-by-introduction) build steps.

Promise pipelining is on the application surface itself: the handle a `send`
returns is a valid target for the next `send`, so a call addressed at an answer
that has not resolved yet costs one round trip instead of one per dependent link
(ADR-0007 serving, ADR-0065 questioner). Pass the vow back as the target — Rust's
`RemotePromise`, Python's and TypeScript's `RemotePromise`, Racket's
`conn-send-promise` result — and settle only the tail.

The raw peer (`conn.peer`) remains available beneath that surface for session
control or fixed-position interop with a partner that expects a known export
slot. The [`examples/apps/`](../examples/apps/) clients are built entirely on the
surface above.

One binding-specific shape remains, and it follows Rust's async model. Rust's
`tell` returns once the deliver is queued on the driver task, and that task
flushes it. The other bindings await the flush directly. Replies still behave
the same way in every binding. A `send` or `tell` to a `Ref` spawned by the same
connection resolves in process everywhere; Rust routes that hosted export to a
local turn on the driver task, the same as Deno and Python.

## The C ABI surface today

The `Connection` and actor layers above are pure composition over the C ABI. The
ABI itself stays small and C-shaped, and it ships as composable per-family
archives a consumer links à la carte (ADR-0059): `libpancake_ocapn` carries the
peer plus the shared vocabulary in `pancake_ocapn.h`, and each transport is its
own archive and header, `libpancake_net_transport_tcp`
(`pancake_net_transport_tcp.h`), `libpancake_net_transport_inproc`
(`pancake_net_transport_inproc.h`), and `libpancake_net_transport_iroh`
(`pancake_net_transport_iroh.h`). Together they expose these groups:

- **Allocation context.** A `PancakeContext` owns allocation policy for a handle
  family. Create one with `pancake_context_new` or
  `pancake_context_new_with_allocator`, and release it with
  `pancake_context_release`. The `*_in` constructors, such as
  `pancake_peer_new_in` and `pancake_tcp_netlayer_new_in`, allocate peers,
  netlayers, and every managed frame and buffer through that context. By default
  they use the library allocator; a host can supply `alloc` and `free`
  callbacks.
- **Peer and frame primitives.** A binding can create a peer, feed it borrowed
  or owned frames, step it, take outbound frames, poll events, and release
  returned frames and events explicitly. `pancake_peer_new` and
  `pancake_peer_new_in` create negotiating, authenticated v1.0 peers over Syrup;
  `pancake_peer_new_negotiated` and `_negotiated_in` carry an out-of-band
  negotiated profile and codec when the ends agreed on something else.
  `pancake_peer_new_raw_open` and `_raw_open_in` are the trusted/local
  direct-frame constructors: they yield an already-open, _unauthenticated_ peer
  for hosts that drive the engine from frames they already hold (test harnesses
  and in-process or local-socket loops), kept as a distinct name so the
  handshake-skipping path never hides behind the safe one (ADR-0059).
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
- **Sturdyref enliven (ADR-0012).** `pancake_peer_prepare_enliven` consults the
  session dedup cache and, on a miss, queues the bootstrap-fetch keyed by swiss
  number; `pancake_peer_record_enlivenment` caches the resolved far reference
  once it settles, so a repeat enliven short-circuits with no wire traffic. Each
  binding's `enliven()` rides this seam.
- **Typed OCapN driving surface (ADR-0031).** `pancake_peer_send_deliver` and
  `pancake_peer_send_resolve` construct calls and replies from fixed-layout
  `PancakeReference` and `PancakeArgument` structs, and
  `pancake_peer_send_gc_export` and `pancake_peer_send_gc_answer` emit the GC
  release verbs so a long-lived session does not strand table rows.
- **Distributed GC finalizers (ADR-0063).** `conn.with_gc()` opts a connection
  into off-by-default distributed GC: each far reference returned by `fetch`
  registers a language finalizer (Rust `Drop`, JS `FinalizationRegistry`, Python
  `weakref.finalize`, Racket `register-finalizer`) that, when the handle is
  collected, parks one `pancake_peer_send_gc_export` delta of 1 the connection's
  own loop drains to the wire. Scope is `fetch` results only — near refs,
  promises, sturdyrefs (the enliven dedup cache owns them), bootstrap, and
  redeemed handoff tokens are excluded — so the behavior is uniform across all
  four bindings.
- **Object-capability forwarders (ADR-0064).** `conn.caretaker(ref)` and
  `conn.attenuate(ref, verbs)` spawn an ordinary actor whose behavior returns the
  binding's forward value — `Turn.forward`, the binding-level shape of the Zig
  vat primitive — so it wraps *any* `Ref`, local or wire-imported, and a binding
  hands out a revocable or narrowed view of authority it does not own. The shared
  dispatch path tail-resolves the answer from the forwarded send: a local target
  near-calls (composing), a far target defers the caller's answer until the reply
  settles. Because the proxy is a plain actor it answers the host's own near-call
  exactly as it answers a partner's delivery. Each binding owns this in its serve
  loop; the C ABI stays the same low-level deliver/resolve surface.
  `pancake_peer_peek_event`, `pancake_peer_poll_event_deliver`, and
  `pancake_peer_poll_event_resolve` read inbound deliveries and resolutions as
  structured values; a value the typed surface cannot carry (e.g. a handoff
  argument) leaves the event queued, and the consumer drains it with the opaque
  `pancake_peer_poll_event`, reading the raw frame in the codec
  `pancake_peer_codec` reports. `pancake_peer_register_export` and
  `pancake_peer_register_import` name the served and called positions, and
  `pancake_peer_next_export` and `pancake_peer_next_answer` allocate fresh
  export and answer positions from the session's own counters, so a binding
  never mints a position that aliases a live one. This is what lets a binding
  drive OCapN directly instead of shuttling opaque frames.
- **Per-thread last error.** `pancake_last_error` and `pancake_clear_last_error`
  (in `libpancake_ocapn`) expose the concrete cause behind a flat error code.
  Each transport archive carries its own reader — `pancake_tcp_last_error` and
  `pancake_inproc_last_error` — because the archives are symbol-disjoint, so a
  TCP error is read through `pancake_tcp_last_error`, not the peer's reader.
- **Blocking TCP endpoint handles (cleartext; no TLS).** Carried by
  `libpancake_net_transport_tcp` (`pancake_net_transport_tcp.h`), the endpoint
  API is an explicit handle for the I/O backend: create and release the tcp
  netlayer, dial or listen, accept, read and write whole frames, read the
  listener port, and close the connection or listener. The host owns the peer.
  It reads a frame, feeds it to the peer, steps the peer, takes outbound frames,
  and writes them back. Framing uses the active codec's one parser, selected
  through `PANCAKE_CODEC_*`; `pancake_peer_new_negotiated` constructs a peer
  whose session speaks the same codec, so a Cap'n Proto conversation is
  reachable over the ABI end to end. The C side never names `std.Io`; the
  netlayer handle owns it explicitly, with no hidden runtime. This endpoint is
  cleartext and loopback-grade. A real transport such as TLS or QUIC would layer
  above the same adapter. See
  [ADR-0030](../docs/decisions/adr/ADR-0030-netlayer-connection-and-memory-posture.md).

The transport archives still carry no TLS and no background run loop.
Crossed-hellos detection lives above the endpoint handles. A host coordinates a
registry across connections and asks the peer to emit the typed abort; the C ABI
does not hide a runtime that does it for you.

The C ABI default peer posture is an authenticated v1.0 negotiation:
`pancake_peer_new` creates a negotiating peer and `pancake_peer_start_session`
signs canonical location bytes from caller-supplied seed material. Already-open
peers come from `pancake_peer_new_raw_open` / `_raw_open_in`, the trusted/local
direct-frame path (unauthenticated; see ADR-0059). The Deno, Python, Rust, and
Racket Goblins interop steps each drive the authenticated path over the C ABI.

Each binding is a real foreign-language consumer of the installed pancake
archives, and each one mirrors the à-la-carte archive set (ADR-0059): a
standalone **core** module over `libpancake_ocapn`, plus one composable module
per transport that loads or links only its own archive. Importing or enabling a
transport pulls in just that transport's archive, exactly as a C consumer links
archives or a Zig consumer imports modules, the core never loads a transport,
and one transport never loads another. Rust links the installed static archives;
Deno, Python, and Racket load the installed shared archives. The core module is
usable on its own, and a consumer composes only the transports a program reaches
for, so a TCP-only program never links or loads `libpancake_net_transport_iroh`.

Each binding ships an idiomatic API over the C ABI, and the raw FFI stays
private. A consumer touches a `Peer` that releases itself, native values as call
arguments, and typed events from the core, and reaches a per-transport module
for the blocking `Netlayer`/`Listener`/`Endpoint` that runs a peer over a real
socket. The dogfood consumer in each binding drives a real OCapN round-trip
through that API: it constructs a call, reads a delivery as structured values,
and runs a peer over a loopback socket, both synchronously and through the
language-native async layer.

| Binding              | Core module                                                                                                           | Per-transport modules                                                             | Dogfood consumer                        |
| -------------------- | --------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------- | --------------------------------------- |
| [`rust/`](rust/)     | crate root (`Peer`, `Reference`/`Argument`/`Event` enums)                                                             | `tcp`, `inproc`, `iroh` modules behind Cargo features                             | `cargo test`                            |
| [`ts/`](ts/)         | `mod.ts` / `@pancake/stack` (`Peer` class, discriminated-union values; one source for Deno + Bun + experimental Node) | `@pancake/stack/transport/{tcp,inproc}` plus the optional `@pancake/iroh` package | `stack/zig_smoke.ts` (Deno + Bun gates) |
| [`python/`](python/) | the `pancake` package (`Peer`, native Python values)                                                                  | `pancake.tcp`, `pancake.inproc`, `pancake.iroh`                                   | `zig_smoke.py`                          |
| [`racket/`](racket/) | `pancake.rkt` (`peer`, native Racket values, event structs)                                                           | `pancake-tcp.rkt`, `pancake-inproc.rkt`, `pancake-iroh.rkt`                       | `zig-smoke.rkt`                         |

Picking transports à la carte reads the same way in every binding, import or
enable the core, then add only the transports you want:

```ts
// JS (Deno/Bun/Node): core plus the in-process transport, nothing else
import { Peer } from "@pancake/stack";
import { Netlayer } from "@pancake/stack/transport/inproc";
```

```python
# Python: core plus the TCP transport
from pancake import Peer
from pancake.tcp import TcpNetlayer
```

```racket
;; Racket: require the core, then the transport module you want
(require "pancake.rkt")
(require "pancake-tcp.rkt")
```

```toml
# Rust: tcp + inproc are default features; add iroh opt-in
pancake = { version = "*", features = ["iroh"] }   # implies the async feature
```

Each binding keeps its raw FFI and its hand-mirrored ABI constants in clearly-internal
modules grouped per archive the way the C ABI is, idiomatic to its ecosystem —
Rust's private `sys` (`sys/{ocapn,tcp,inproc,iroh}.rs`) and `abi_constants`, the
JS binding's per-archive loaders and runtime FFI shim under
[`ts/stack/internal/ffi/`](ts/stack/internal/ffi/), Python's `_`-private
`_ffi_core`/`_ffi_tcp`/`_ffi_inproc`/`_ffi_iroh` modules inside the
[`pancake`](python/pancake/) package, Racket's per-archive
[`racket/private/`](racket/private/) `ffi-*` modules over a shared
`ffi-shared.rkt` that opens no library — so each public module reads as just the
ergonomic API it offers.

Each binding also exposes an async connection in its language-native idiom. It
drives the same sans-io peer over its own non-blocking sockets through
`pancake_peer_recv_stream`. There is no blocking C netlayer in that path and no
thread per call.

| Binding              | Async idiom                     | Async type                                                           |
| -------------------- | ------------------------------- | -------------------------------------------------------------------- |
| [`rust/`](rust/)     | tokio (opt-in `async` feature)  | `AsyncConnection` over `tokio::net::TcpStream`                       |
| [`ts/`](ts/)         | native promises (Deno/Bun/Node) | `AsyncConnection` over `node:net` (Deno uses its own native sockets) |
| [`python/`](python/) | `asyncio`                       | `AsyncConnection` over `asyncio` streams                             |
| [`racket/`](racket/) | green threads + ports           | `async-connection` over `tcp-connect`/`tcp-listen`                   |

One async connection owns one peer, because the peer is a single-owner state
machine. It lives on one task or thread as a connection actor. The peer calls do
no I/O and never block the event loop; only the socket reads and writes await.

The inbox each connection accumulates is bounded by the library, not by binding
code: a connection keeps reading only while `recv_stream` answers "partial
frame, read more", and a frame that cannot complete within the peer's
`max_frame_bytes` is refused with the typed `FRAME_TOO_LARGE` error the moment
that is knowable. That can be when its length prefix declares past the cap or
when its bytes have already crossed it (ADR-0041). Every binding's smoke pins
this, so a hostile partner cannot grow a binding's inbox without bound.

The outbound side is bounded by write discipline rather than a queue: every
binding awaits or blocks on its socket writes frame by frame (JS per-frame
`write`, Rust `write_all(...).await`, Python `write` plus an awaited `drain()`
per pump, Racket blocking `write-bytes`), so a partner that stops reading stalls
the connection's pump instead of growing a buffer. That is the same posture as
the Zig blocking pump: bounded memory, with the tradeoff that a write to a slow
reader can head-of-line-block that one connection. The Zig completion loop's
high-water read parking
([ADR-0042](../docs/decisions/adr/ADR-0042-outbound-high-water-backpressure.md))
is the many-connection alternative; every binding wraps the iroh loop surface of
that shape, each in its own idiom (see [boundaries](../docs/boundaries.md)).

Each async surface also speaks its runtime's native async sequences, so a
consumer reads events as a stream and awaits a send's result rather than polling
and registering callbacks. The `nextEvent`/`on` style still works underneath;
these are additive:

| Binding              | Event stream                           | Awaited send                      |
| -------------------- | -------------------------------------- | --------------------------------- |
| [`ts/`](ts/)         | `for await (const event of conn)`      | `await vat.send(ref, verb, args)` |
| [`python/`](python/) | `async for event in conn`              | `await vat.send(ref, verb, args)` |
| [`racket/`](racket/) | `(in-async-events conn)` sequence      | `(on vow handler)`                |
| [`rust/`](rust/)     | a task handle over `tokio::sync::mpsc` | `Vat::send(...).await` shape      |

The `examples/apps/rooms/` clients each build a small `Room` on this surface, so
the app above reads like an app in every language.

Each binding also exposes a Goblins-shaped **actor layer** in its own idiom,
built on the typed peer surface (no extra C ABI). A `Vat` holds local actors
and, when bound to a peer, routes eventual-sends to partner-hosted references
over the wire. `publish` binds a local actor to a peer export, so an inbound
deliver runs the actor and resolves the answer with its reply. A leading symbol
argument is the method verb. An actor is the language's native callable, such as
a Rust closure or a Python callable, not a foreign callback. That mirrors how
`pancake.actors` is native Zig.

| Binding              | Actor idiom                                                                                                                                          |
| -------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------- |
| [`racket/`](racket/) | **Goblins-faithful**: `(define (^name bcom arg …) …)` constructors, `methods`, `spawn`, `$` (near), `<-`/`<-np` (eventual), `on`, `bcom`, `with-vat` |
| [`rust/`](rust/)     | `actors::Vat` over `FnMut(&str, &[Argument])` closures                                                                                               |
| [`ts/`](ts/)         | `Vat` over `(verb, args) => Argument` callbacks                                                                                                      |
| [`python/`](python/) | `Vat` over `behavior(verb, args)` callables                                                                                                          |

The Racket layer is the reference shape because it reads like Spritely Goblins,
the way a Racket distributed-systems programmer expects. The model is uniform
across all four bindings and Zig's `pancake.actors`: a reference is local or
far, `$` is the synchronous near-call and only works locally, `<-` is the
location-transparent eventual-send that returns a promise, and an inbound
deliver to a published actor runs a turn and resolves the answer. Every binding
proves a far-send round-trip in its smoke by sending `<-` to a partner-hosted
actor and observing the answer settle the promise.

Each idiomatic layer maps the same value model. Integers, floats, booleans,
bytes, strings, symbols, references, and lists use the language's own types.
References use small constructors such as `Far(5)`, `far(5n)`, or `(far 5)`.
Polling returns typed `Deliver`, `Resolve`, and other events. Bootstrap serving
and TCP networking are exposed as library concepts, with a blocking netlayer for
whole-frame shuttling and the language-native async layer above it.

The carried value set spans the model's passable tree (ADR-0031): integers,
floats, booleans, bytes, strings, symbols, references, lists, sets, tagged
records, and keywords all marshal in the language's own types. Handoff arguments
and sturdy or broken targets are refused loudly with
`PANCAKE_ERR_UNSUPPORTED_VALUE`. For socket transport pancake carries only
blocking, cleartext TCP (no TLS) in `libpancake_net_transport_tcp`, alongside a
socket-free in-process netlayer in `libpancake_net_transport_inproc`
(`pancake_inproc_*`, designator-addressed) for two-peer conversations in one
process. pancake's one encrypted netlayer, iroh, rides the separate artifact
below.

## The iroh transport (optional, a separate artifact)

iroh's encrypted QUIC reaches the bindings as a **separate optional library**,
not folded into the pure-Zig archives: it links a Rust sidecar
([ADR-0055](../docs/decisions/adr/ADR-0055-iroh-netlayer-sidecar.md)), and
keeping it out of those archives is what keeps the core pure Zig and the gate
hermetic. `zig build iroh-abi` (needs `cargo`) builds
`libpancake_net_transport_iroh` — a _companion_ to the core archives, not a
superset: it exports only the `pancake_iroh_netlayer_*` and
`pancake_iroh_conn_*` families (see
[`include/pancake_net_transport_iroh.h`](../include/pancake_net_transport_iroh.h))
and shares no core symbol with `libpancake_ocapn`. A binding that wants iroh
loads `libpancake_net_transport_iroh` alongside the core set — the core archives
for the peer machinery, iroh for the transport — and gains `listen_iroh` for
hosting; a partner over iroh is dialed through the same `connect` as tcp.

The binding module layout mirrors that artifact split. The transport-neutral
application surface — `connect`, `listen`, and the async `Connection` — lives in
each binding's core module and rides the runtime's own sockets, so a program
that dials a `tcp` locator needs only the core. `connect` takes the locator plus
an optional `Reachability` posture: a `tcp` locator ignores it, an `iroh`
locator requires it (the posture is never guessed). The iroh-touching surface —
`listen_iroh`, the iroh server, and the iroh FFI — lives in a separate
per-transport module (the `@pancake/iroh` package, `pancake.iroh`,
`pancake-iroh.rkt`, Rust's `iroh` feature module). `connect` loads that module
lazily on the first `iroh` locator (Rust selects it at build time through the
opt-in `iroh` feature), so a program that only speaks TCP never imports the iroh
module or links `libpancake_net_transport_iroh`. Rust keeps `connect` and the
`Reachability` enum it takes in the core module so the dialer has one signature
whether or not iroh is compiled in — without the feature an `iroh` locator fails
with a rebuild hint rather than changing the call's shape.

Addressing is the only difference a consumer sees, and it is just a different
locator. There is no `host:port`: a partner is reached by its
self-authenticating endpoint id plus comma-separated direct-address hints,
carried together as an `ocapn://<nodeid>.iroh?direct-addresses=…` URI (the
signed locator uses `"iroh"` as its transport, carries the node id as its
designator, and puts the address hints under `direct-addresses`). Above that,
nothing changes — `connect` on that locator returns the same `Connection`,
drives the same in-process pump, and speaks the same OCapN. The iroh netlayer C
ABI has one I/O model (ADR-0057): an event-driven readiness loop, armed when the
netlayer is constructed. The public surface is a single readiness fd
(`pancake_iroh_netlayer_readiness_fd`) the host parks on with its own poller,
plus a non-blocking `pancake_iroh_netlayer_drain_ready` and the `try_accept` /
`try_connect` / `conn_try_read` / `conn_try_write` calls, with no blocking frame
surface. Every binding parks on that fd natively, each in its own idiom: Deno's
`IrohLoop` (a `node:net` socket on a dup'd fd), Python's `_IrohLoop` (asyncio
`add_reader`), Rust's `AsyncFd` task, and Racket's
`unsafe-file-descriptor->semaphore` park — no dedicated polling thread, no
busy-poll. Each is held to the same scale bar by a many-connection gate —
`zig build bindings-iroh-loop` runs `python-iroh-loop`, `rust-iroh-loop`, and
`racket-iroh-loop`, the binding siblings of `iroh-loop`. The
`examples/apps/rooms/` clients dial a transport-neutral locator, so
`zig build demo-rooms-iroh` runs the same cross-language room over iroh; a
binding joins when its runtime and the iroh library are both present.

Every binding also mints and redeems a three-party handoff **over iroh** through
its own surface, the gifter records the exporter's dialable iroh location as the
give's exporter location (`encode_peer_locator` + `set_exporter_locator`), and the
recipient redeems it transparently by dialing that endpoint directly. `zig build
bindings-iroh-handoff` runs `python-iroh-handoff`, `rust-iroh-handoff`, and
`racket-iroh-handoff`, each standing up exporter, gifter, and recipient across
three iroh endpoints in one process under the relay-less `Direct` posture (the
Deno binding proves the same path through `demo-rooms-dm-iroh`).

Both iroh reachability postures ship in every binding, not just Deno. The
`Direct` posture (dial the exporter's `direct-addresses`) is what the handoff
gates above exercise; the `Discovery` posture (dial by **node id alone** over n0
relays + DNS/pkarr) is carried by every `connect_iroh`, whose dial retries on a
shared settle/retry budget while the partner's pkarr record propagates. When a
give names its exporter by **node id alone** (no `direct-addresses`), the
recipient resolves it under its node's configured redeem posture — `Discovery`
by default, lowerable to `DiscoveryNoRelay` for a no-relay policy through each
binding's `set_redeem_reachability` knob (`setRedeemReachability` in TS, the
`redeem_reachability` property in Python, `set-node-redeem-reachability!` in
Racket); a hinted give always dials `Direct`. That the redeem honors the
configured posture is proven hermetically per binding by `zig build
bindings-iroh-redeem-posture` — each lowers its recipient to `local_discovery`
and redeems a hint-less give by id through an in-process book (the default
`Discovery` would need the network). Its
offline, deterministic dial-by-id form (`local_discovery`) is proven by the
`*-iroh-loop` gates; the live public-internet form is proven per binding by the
opt-in `zig build bindings-iroh-reachability` (`python-`/`rust-`/`racket-iroh-reachability`),
two `Discovery`-posture endpoints reaching each other by id alone — kept out of
`check` because publish-propagation timing is not hermetic.

## Running

```sh
zig build bindings        # rust + deno + bun + python + racket smokes
zig build rust-dogfood    # just the Rust consumer
```

`zig build bindings` requires `cargo`, `deno`, `bun`, `python3`, and `racket` on
PATH, provided by [`../.devcontainer/`](../.devcontainer/). The libraries are
built and installed under `../zig-out/lib/` first.

## Finding the archives

Every binding locates its archives through the same cascade, configure first,
then a development fallback, then the system search:

1. **`PANCAKE_LIB_DIR` (configure).** If the environment names a directory, the
   binding loads its archives from there. This is the one knob for tests, demos,
   CI, and a packager pointing at a chosen install —
   `PANCAKE_LIB_DIR=/path zig
   build …`, or set it before running a script
   directly.
2. **`zig-out/lib` (dev fallback).** Otherwise, when running in-tree, the
   binding resolves the repo's build output relative to its own location — what
   the gates exercise with no environment set.
3. **The bare library name (find).** Otherwise, the binding hands the loader the
   plain `lib<archive>.<suffix>` name and lets the OS dynamic-linker search
   resolve it from the system library path — the installed-library posture.

For the load-time bindings (the TypeScript, Python, and Racket FFIs) this runs
on each `dlopen`; the Deno gate passes `--allow-env` so the configure leg is
reachable. Rust links the core/tcp/inproc archives **statically**, so the
cascade is a build-time link-search path there; only the dynamically-loaded iroh
sidecar carries it forward as a runtime rpath. A hosted, versioned release of
the per-platform archives — pancake's "C release" — is not shipped yet; it would
drop a cached-download leg between configure and the dev fallback without
changing this order.
