# bindings/

Per-language consumers of the Zig `libpancake` C ABI. Each binding dogfoods
the C ABI as a real foreign-language consumer — the systemic safeguard
against wire-shape and ABI regressions that only surface through an actual
FFI consumer.

## The application surface (what you build against)

An application holds one thing: a `Connection`. It composes a peer, a vat, and the
language's async I/O into a single object, so a consumer never stitches those
layers together by hand. The whole common surface is seven verbs, the same in
every binding:

| Verb | What it does |
| --- | --- |
| `connect(host, port)` | Dial a server, return a `Connection` |
| `listen(host, port)` | Accept connections, yield a `Connection` each |
| `conn.publish(name, behavior)` | Make a local actor fetchable by name (a swiss-number) |
| `conn.fetch(name)` | Fetch a partner's published capability by name; returns a `Ref` |
| `conn.spawn(behavior)` | Create a local actor; returns a `Ref` that auto-marshals in args |
| `conn.send(ref, verb, args)` | Call a method on a capability and await the reply |
| `conn.tell(ref, verb, args)` | Fire-and-forget send (Goblins `<-np`): no answer, no reply — the right call for a notification or broadcast |
| `conn.serve()` | Run the inbound event loop (resolves on close, rejects on error) |
| `conn.close()` | End the connection |

A `Ref` is an opaque capability: pass it as a `send` argument and it marshals to
the right wire reference automatically — you never construct `near`/`far`
references or manage export-position numbers. Each language renders the surface in
its own idiom: Deno returns native `Promise`s and supports `using`; Python is
coroutines with `async with`; Rust returns `impl Future` from a `!Send`
`Connection` (create and use it on one task inside a `LocalSet`); Racket keeps the
Goblins verbs (`spawn`, `$`, `<-`, `on`, `bcom`, `methods`) and adds `connect`/
`fetch`. Native Zig gets the same surface as `driver.ConnectedVat`
(`driver.connectTcp`), explicit about allocation and I/O (one `step()` per pump).

The raw peer (`conn.peer`) remains available beneath the seven verbs — the
graduated, low-level path for handoff, promise pipelining, session control, and
fixed-position interop with a partner that expects a known export slot. No example
application needs it; the [`examples/apps/`](../examples/apps/) clients are built
entirely on the surface above.

## The C ABI surface today

The `Connection` and actor layers above are pure composition over the C ABI; the
ABI itself is unchanged. The current `pancake.h` exposes:

- **Allocation context:** `pancake_context_new_default` /
  `pancake_context_new_with_allocator` / `pancake_context_release`. A context
  owns allocation policy for a handle family; the `*_in` constructors
  (`pancake_peer_new_in`, `pancake_tcp_netlayer_new_in`) allocate peers,
  netlayers, and every managed frame and buffer they own through that context —
  the library allocator by default, or host `alloc`/`free` callbacks.
- **Peer / frame primitives:** `pancake_peer_new` /
  `pancake_peer_feed_borrowed` / `pancake_peer_feed_owned` / `pancake_peer_step`
  / `pancake_peer_take_outbound` / `pancake_peer_poll_event` plus frame/event
  release.
- **Sans-I/O stream input:** `pancake_peer_recv_stream` frames *and* dispatches
  one frame from a raw byte-stream buffer, reporting how many bytes it consumed
  (or `PANCAKE_ERR_WOULD_BLOCK` for a partial frame). The peer never blocks and
  owns no socket, so a binding drives it from its own event loop — this is what
  lets each binding run async over its language-native networking.
- **Bootstrap serving:** `pancake_peer_register_bootstrap_cap` (publish a local
  capability behind a swissnum for inbound fetch).
- **Typed OCapN driving surface (ADR-0031):** `pancake_peer_send_deliver` /
  `_send_resolve` construct a call/reply from fixed-layout `PancakeReference` /
  `PancakeArgument` structs; `pancake_peer_peek_event` +
  `pancake_peer_poll_event_deliver` / `_poll_event_resolve` read an inbound
  delivery/resolution as structured values; `_register_export` / `_register_import`
  name the positions served or called. This is what lets a binding *drive* OCapN
  rather than shuttle opaque frames.
- **Per-thread last error:** `pancake_last_error` / `pancake_clear_last_error`
  re-expose the concrete socket cause behind a flat `PANCAKE_ERR_IO`.
- **Blocking `tcp-testing-only` endpoint handles:** `pancake_tcp_netlayer_new` /
  `_release` (an explicit handle owning the I/O backend), then
  `pancake_endpoint_tcp_testing_connect` / `_testing_listen` / `_testing_accept`
  / `_listener_port` / `_read_frame` / `_write_frame` / `_conn_close` /
  `_listener_close`. The host owns the peer and shuttles whole frames
  (`read_frame -> feed_owned -> step -> take_outbound -> write_frame`); framing
  is the active codec's one parser (codec selected via `PANCAKE_CODEC_*`). The
  C side never names a `std.Io` — the netlayer handle owns it explicitly, with no
  hidden runtime. It is cleartext and loopback-grade. A real transport like TLS or
  QUIC would layer above the same adapter (see
  [ADR-0030](../docs/decisions/adr/ADR-0030-netlayer-connection-and-memory-posture.md)).

The shared library still carries no TLS, crossed-hellos, or background run loop
(all deferred by name in ADR-0030).

The C ABI constructs an **open PreSpec session**, where `pancake_peer_new` calls
`engine.Peer.init`. It does not yet expose a negotiating-peer constructor or a
way to drive the keyed `op:start-session` handshake, so a binding converses with
another PreSpec pancake peer, not with a live Goblins vat — the keyed handshake
and the Goblins V1.0 resolver-callback translation are exercised today only by the
in-Zig `zig build goblins-interop` step. A binding that needs to talk to Goblins
is past what the C ABI exposes; a negotiating constructor plus handshake driving
over the C ABI is the next step toward "any language converses with Goblins."

Each binding is a real foreign-language consumer of the installed pancake
artifacts. Rust links the installed static library; Deno, Python, and Racket load
the installed shared library. Each binding ships an **idiomatic, language-native
API** over the *whole* C ABI — the raw FFI is private; what a consumer touches is
a `Peer` that releases itself, native values as call arguments, typed events, and
a `Netlayer`/`Listener`/`Conn` for running a peer over a real TCP socket. The
dogfood consumer in each drives a real OCapN round-trip through that API
(construct a call, read a delivery as structured values, and run a peer over a
loopback socket — synchronously and through the language-native async layer):

| Binding | Idiomatic API | Dogfood consumer |
| --- | --- | --- |
| [`rust/`](rust/) | `src/lib.rs` (`Peer`, `Reference`/`Argument`/`Event` enums) | `cargo test` |
| [`deno/`](deno/) | `pancake.ts` (`Peer` class, discriminated-union values) | `zig_smoke.ts` |
| [`python/`](python/) | `pancake.py` (`Peer`, native Python values) | `zig_smoke.py` |
| [`racket/`](racket/) | `pancake.rkt` (`peer`, native Racket values, event structs) | `zig-smoke.rkt` |

Each binding also exposes an **async connection** in its language-native idiom,
driving the same sans-io peer over its own non-blocking sockets via
`pancake_peer_recv_stream` — no blocking C netlayer, no thread-per-call:

| Binding | Async idiom | Async type |
| --- | --- | --- |
| [`rust/`](rust/) | tokio (opt-in `async` feature) | `AsyncConnection` over `tokio::net::TcpStream` |
| [`deno/`](deno/) | native promises | `AsyncConnection` over `Deno.connect`/`Deno.listen` |
| [`python/`](python/) | `asyncio` | `AsyncConnection` over `asyncio` streams |
| [`racket/`](racket/) | green threads + ports | `async-connection` over `tcp-connect`/`tcp-listen` |

One async connection owns one peer (the peer is a single-owner state machine), so
it lives on one task/thread — a connection actor. The peer calls are instant and
never block the event loop; only the socket reads/writes await.

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
wire; `publish` binds a local actor to a peer export, so an inbound deliver runs
the actor and resolves the answer with its reply (a leading symbol argument is the
method verb). An actor is the language's native callable — a Rust closure, a
Python callable — not a foreign callback, the same way `pancake.actors` is native
Zig.

| Binding | Actor idiom |
| --- | --- |
| [`racket/`](racket/) | **Goblins-faithful**: `(define (^name bcom arg …) …)` constructors, `methods`, `spawn`, `$` (near), `<-`/`<-np` (eventual), `on`, `bcom`, `with-vat` |
| [`rust/`](rust/) | `actors::Vat` over `FnMut(&str, &[Argument])` closures |
| [`deno/`](deno/) | `Vat` over `(verb, args) => Argument` callbacks |
| [`python/`](python/) | `Vat` over `behavior(verb, args)` callables |

The Racket layer is the reference — it reads like Spritely Goblins, the way a
Racket distributed-systems programmer expects. The seam is uniform across all
four (and Zig's `pancake.actors`): a reference is local or far, `$` is the
synchronous near-call (local only), `<-` is the location-transparent
eventual-send returning a promise, and an inbound deliver to a published actor
runs a turn and resolves the answer. Every binding proves a far-send round-trip
(`<-` to a partner-hosted actor, the answer settling the promise) in its smoke.

Each idiomatic layer maps the same way: integers/floats/booleans/bytes/strings/
symbols/references/lists in the language's own types, references via constructors
(`Far(5)` / `far(5n)` / `(far 5)`), a `poll` that returns a typed `Deliver` /
`Resolve` / other event, bootstrap serving, and TCP networking (a blocking
netlayer for whole-frame shuttling, plus the language-native async layer above).
The carried value set spans the model's passable tree (ADR-0031): integers, floats,
booleans, bytes, strings, symbols, references, lists, sets, tagged records, and
keywords all marshal in the language's own types. Handoff arguments and
sturdy/broken targets are refused loudly (`PANCAKE_ERR_UNSUPPORTED_VALUE`). The
shared library still carries no production transport beyond `tcp-testing-only`.

## Running

```sh
zig build bindings        # rust + deno + python + racket smokes
zig build rust-dogfood    # just the Rust consumer
```

`zig build bindings` requires `cargo`, `deno`, `python3`, and `racket` on PATH —
provided by [`../.devcontainer/`](../.devcontainer/). The libraries are built and
installed under `../zig-out/lib/` first; each consumer resolves the artifact it
uses relative to its own location.
