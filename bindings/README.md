# bindings/

This directory holds the per-language consumers of the pancake C ABI archives.
Each one exercises the C ABI as a real foreign-language consumer, which catches
the wire-shape and ABI regressions that surface only through an actual FFI
caller.

## The application surface (what you build against)

An application holds one thing: a `Session`. It composes a CapTP partner, a vat,
and the language's async I/O into a single object, so a consumer never stitches
those layers together by hand. A `Host` is the multi-session CapTP product those
sessions share. It carries one identity, one gift registry, and an
`engine.Node`. The application vocabulary is small and shared across the
bindings:

| Verb | What it does |
| ------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `connect(locator)` | Dial a peer from its `ocapn://` locator. A `tcp` locator needs nothing else; a `keyed-tcp` locator needs its `direct-addresses` hint; an `iroh` locator adds a reachability posture. There is no bare `host:port` dial. Internally, `connect` parses once and dispatches through `dial_parsed_locator` / `open_dialed_locator` (C ABI `pancake_host_session_open_dialed_locator`). |
| `tcp_locator(host, port)` | Build a `tcp` locator (`ocapn://host:port.tcp`) from a literal address through `socket_addr_designator` (IPv6 bracketing), to pass to `connect` |
| `keyed_tcp_locator(key, host, port)` | Build a `keyed-tcp` locator: the designator is the listener's Ed25519 key in hex, and `host`/`port` ride the `direct-addresses` hint (ADR-0075) |
| `listen(bind_host, port)` | Accept TCP connections, yield a `Session` each |
| `listen_keyed_tcp(bind_host, port, seed?)` | Bind a keyed-tcp listener whose designator is the public half of `seed` (or a fresh seed). Host identity, designator, and session key are the same value (ADR-0075). |
| `listen_iroh()` | Bind an iroh endpoint; its `uri` is what a partner dials with `connect` (optional iroh artifact) |
| `session.publish(name, behavior)` | Make a local actor fetchable by name (a swiss number) |
| `session.fetch(name)` | Fetch a partner's published capability by name; returns a `Ref` |
| `session.enliven(sturdyref)` | Bring a durable `ocapn://…/s/<swiss>` sturdyref to life on the open session; returns a `Ref`, with a dedup cache (ADR-0012) |
| `session.spawn(behavior)` | Create a local actor; returns a `Ref` that auto-marshals in args |
| `session.caretaker(ref)` | Wrap any `Ref` (local or far) in a revocable forwarding proxy; returns the proxy `Ref` plus a `revoke` lever: the proxy forwards until revoked, then breaks every call `Revoked` (ADR-0064) |
| `session.attenuate(ref, verbs)` | Wrap any `Ref` in a proxy that forwards only the allow-listed `verbs` and breaks every other call `Attenuated` (ADR-0064) |
| `session.send(ref, verb, args)` | Call a method on a capability and await the reply |
| `session.tell(ref, verb, args)` | Fire-and-forget send (Goblins `<-np`): no answer, no reply. Use it for notifications and broadcasts. |
| `session.serve()` | Run the inbound event loop (resolves on close, rejects on error) |
| `session.with_gc()` | Opt this session into distributed GC, off by default: a fetched `Ref`'s finalizer releases its import to the partner when collected (ADR-0063) |
| `session.close()` | End the session |

A `Ref` is an opaque capability. Pass it as a `send` argument and it marshals to
the right wire reference automatically. Application code never constructs
`near`/`far` references and never manages export-position numbers.

Each language renders the surface in its own idiom. Deno returns native
`Promise`s and supports `using`. Python uses coroutines and `async with`. Rust
returns `impl Future` from a `!Send` `Session`; create and use it on one task
inside a `LocalSet`. Racket keeps the Goblins verbs, including `spawn`, `$`,
`<-`, `on`, `bcom`, and `methods`, and adds `connect`, `session-fetch`, and
`session-send`. Native Zig speaks the same verbs through one owning `driver.Session`, spelled
in [architecture](../docs/architecture.md). A selector a binding exposes follows
the same discipline: profile and codec are spelled in each language's idiom (a
string union, a symbol, an enum), and a selector parameter accepts every value
the library supports, not a single hard-wired one.

Every binding hosts as well as dials. Deno and Python yield a `Session` per
accepted partner from `listen`. Rust binds a `Server` whose `accept` returns
one. Racket's `(accept (listen bind_host port))` returns the same `session` that
`connect` does.

Receiving a three-party handoff is transparent on the application surface.
`connect`, `fetch`, and `send` are the whole contract. The give and the second
connection never reach application code. Originating one works the same way.
Returning a `Ref` whose home is a different connection deposits the gift and
answers with a signed `desc:handoff-give`. The shipped behavior, build checks, and
host-tier mechanism live in [`docs/shipped.md`](../docs/shipped.md). Each
binding proves both halves against live Goblins through the `*-goblins-handoff`
and `*-goblins-gift` steps, plus the all-pancake `deno-gifter-handoff` and
`demo-rooms-dm` paths.

Promise pipelining is on the application surface itself. The handle a `send`
returns is a valid target for the next `send`. A call addressed at an answer that
has not resolved yet costs one round trip instead of one per dependent link.
That is the serving side in ADR-0007 and the questioner side in ADR-0065. Pass
the vow back as the target. Rust, Python, and TypeScript use `RemotePromise`;
Racket uses the `session-send-promise` result. Settle only the tail.

All four bindings ship the session tier alone over the byte-fed host archive
(`pancake_host_*`, ADR-0072). Their raw `pancake_peer_*` wrappers are gone. The
raw family stays a C-consumer surface covered by the Zig C-ABI tests and the C
examples. The [`examples/apps/`](../examples/apps/) clients are built entirely on
the surface above.

A few binding-specific shapes remain, each following its language's own model.
Rust's `tell` is synchronous: it returns once the deliver is queued on the
host, and the scheduled action drain flushes it, in order with the sends around
it; the other bindings await the flush directly. Rust's `serve()` also has no error surface of its own. A session abort shows up
through the vows it breaks, not through the serve task. Replies still behave the
same way in every binding. A `send` or `tell` to a `Ref` spawned by the same
session resolves in process everywhere. A settled outcome nobody awaited yet is
retained per host in a FIFO capped at 1024 in TypeScript, Python, and Rust.
Past the cap the oldest outcome is dropped and a late await fails with a
`CLOSED`-class gone-outcome error. Racket's blocking design awaits at the call
site, so it never parks an outcome. Three C verbs are C-consumer surface the
bindings skip by design: `conn_partner_abort`, `turn_send`, and `turn_tell`.
Each binding reads the partner abort through `conn_last_abort`'s typed detail.
Its trampoline composes turn-time sends through the same `conn_send` and
`conn_tell` it uses everywhere else.

## The C ABI surface today

The `Session` and actor layers above are pure composition over the C ABI. The
ABI itself stays small and C-shaped, and it ships as composable per-family
archives a consumer links à la carte (ADR-0059): `libpancake_ocapn` carries the
peer plus the shared vocabulary in `pancake_ocapn.h`, and each transport is its
own archive and header, `libpancake_net_transport_tcp`
(`pancake_net_transport_tcp.h`), `libpancake_net_transport_inproc`
(`pancake_net_transport_inproc.h`), and `libpancake_net_transport_iroh`
(`pancake_net_transport_iroh.h`). One more archive sits above the peer. `libpancake_driver` (`pancake_driver.h`) is
the byte-fed multi-session CapTP host (`pancake_host_*`, ADR-0072). It is the
shared runtime a binding drives instead of reimplementing the host tier per
language. Hosted objects ride the vat's foreign-behavior contract, so no
separate bare-vat archive ships (see
[`docs/boundaries.md`](../docs/boundaries.md)).
Together the archives expose these groups:

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
- **Distributed GC finalizers (ADR-0063).** `session.with_gc()` opts a session
  into off-by-default distributed GC: each far reference returned by `fetch`
  registers a language finalizer (Rust `Drop`, JS `FinalizationRegistry`, Python
  `weakref.finalize`, Racket `register-finalizer`) that, when the handle is
  collected, parks one `pancake_host_gc_release` delta of 1 that the connection's
  own loop drains. The host resolves the node-unique token to its home connection
  and the release rides the wire as `op:gc-exports`. Scope is `fetch` results
  only. Near refs, promises, and sturdyrefs are excluded. The enliven dedup cache
  owns sturdyrefs, and bootstrap is excluded too. The behavior is uniform across
  all four bindings.
- **Object-capability forwarders (ADR-0064).** `session.caretaker(ref)` and
  `session.attenuate(ref, verbs)` spawn an ordinary actor whose behavior returns
  the binding's forward value (`Turn.forward`, the binding-level shape of the
  Zig vat primitive). The proxy wraps any `Ref`, local or wire-imported. A
  binding can hand out a revocable or narrowed view of authority it does not
  own. The shared dispatch path tail-resolves the answer from the forwarded
  send. A local target near-calls and composes. A far target defers the
  caller's answer until the reply settles. Because the proxy is a plain actor,
  it answers the host's own near-call exactly as it answers a partner's
  delivery. Each binding owns this in its serve loop. The C ABI stays the same
  low-level deliver and resolve surface.
- **Typed event pump (the waist: the narrow event surface every binding
  shares).** `pancake_peer_next_event` is the one call a
  consumer's event loop needs. It drives the engine to idle. A settlement
  cascade surfaces in full, so there is no "step, then re-poll" rule to learn.
  It then hands back the next event fully projected. A deliver or resolve
  arrives as structured values, handoff give included. Every other kind, and
  any value the typed surface cannot carry, arrives as its originating wire
  frame in the codec `pancake_peer_codec` reports. The pump-then-poll rule and
  the typed-or-opaque routing live in the waist, so no binding re-derives
  either. The non-consuming `pancake_peer_peek_event` and the opaque,
  non-driving `pancake_peer_poll_event` remain for a caller that wants to look
  or drain by hand. `pancake_peer_register_export` and
  `pancake_peer_register_import` name the served and called positions.
  `pancake_peer_next_export` and `pancake_peer_next_answer` allocate fresh
  export and answer positions from the session's own counters. A binding never
  mints a position that aliases a live one. This is what lets a binding drive
  OCapN directly instead of shuttling opaque frames.
- **Per-thread last error.** `pancake_last_error` and `pancake_clear_last_error`
  (in `libpancake_ocapn`) expose the concrete cause behind a flat error code.
  Each transport archive carries its own reader (`pancake_tcp_last_error`,
  `pancake_inproc_last_error`, and `pancake_iroh_last_error`) because the
  archives are symbol-disjoint, so a
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
Crossed-hellos detection lives above the endpoint handles: the transport
archives do not do it for you. The byte-fed host archive (`pancake_host_*`) owns
the tiebreak registry across CapTP sessions and asks the peer to emit the typed
abort (ADR-0068).

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
archives or a Zig consumer imports modules. The core never loads a transport,
and one transport never loads another. Rust links the installed static archives;
Deno, Python, and Racket load the installed shared archives. The core module is
usable on its own, and a consumer composes only the transports a program reaches
for, so a TCP-only program never links or loads `libpancake_net_transport_iroh`.

Each binding ships an idiomatic API over the C ABI, and the raw FFI stays
private. A consumer touches native values as call arguments and typed replies
from the session surface, and reaches a per-transport module for the
blocking `Netlayer`/`Listener`/`Endpoint` that shuttles frames over a real
socket. Each binding's consumer check exercises the C ABI through a real OCapN round-trip
through that API: it publishes and fetches capabilities, sends and observes
replies, and runs a session over a loopback socket through the
language-native async layer.

| Binding | Core module | Per-transport modules | Binding check consumer |
| -------------------- | --------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------- | --------------------------------------- |
| [`rust/`](rust/) | crate root (the `Session`/`Host` surface over the byte-fed host, `Reference`/`Argument` enums) | `tcp`, `inproc`, `iroh` modules behind Cargo features | `cargo test` |
| [`ts/`](ts/) | `mod.ts` / `@pancake/stack` (the `Session`/`Host` surface over the byte-fed host; one source for Deno + Bun, and for the browser through [`@pancake/web`](ts/web/README.md)'s wasm adapter) | `@pancake/stack/transport/{tcp,inproc}` plus the optional `@pancake/iroh` package; the browser channel is WebSocket | `dogfood/zig_smoke.ts` (Deno + Bun checks), `web-peer-test` (browser peer) |
| [`python/`](python/) | the `pancake` package (the `Session`/`Host` surface over the byte-fed host, native Python values) | `pancake.tcp`, `pancake.inproc`, `pancake.iroh` | `zig_smoke.py` |
| [`racket/`](racket/) | `pancake.rkt` (the `session` surface, native Racket values, event structs) | `pancake-tcp.rkt`, `pancake-inproc.rkt`, `pancake-iroh.rkt` | `zig-smoke.rkt` |

Picking transports à la carte reads the same way in every binding. Import or
enable the core, then add only the transports you want:

```ts
// JS (Deno/Bun): core plus the in-process transport, nothing else
import { Session } from "@pancake/stack";
import { Netlayer } from "@pancake/stack/transport/inproc";
```

```python
# Python: core plus the TCP transport
from pancake import connect, listen
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

Each binding keeps its raw FFI and its ABI constants in clearly-internal
modules grouped per archive the way the C ABI is, idiomatic to its ecosystem.
Three bindings declare struct layouts symbolically (ctypes, `define-cstruct`,
`#[repr(C)]`); TypeScript's FFI has no struct types, so its mirror (constant
values, struct sizes, and field offsets) is *generated* from the Zig source of
truth (`bindings/ts/stack/internal/abi.ts`, `zig build gen-ts-abi`, held by
`gen-ts-abi-check` inside `check`), never hand-derived. The internal modules sit
where the C ABI's own split puts them: Rust's private `sys`
(`sys/{ocapn,driver,tcp,inproc,iroh}.rs`) and `abi_constants`, the JS binding's
per-archive loaders and runtime FFI shim under
[`ts/stack/internal/ffi/`](ts/stack/internal/ffi/), Python's `_`-private
`_ffi_ocapn`/`_ffi_tcp`/`_ffi_inproc`/`_ffi_iroh` modules inside the
[`pancake`](python/pancake/) package, and Racket's per-archive
[`racket/private/`](racket/private/) `ffi-*` modules over a shared
`ffi-shared.rkt` that opens no library. Each public module then reads as just the
ergonomic API it offers.

Each binding also runs its connections in its language-native async idiom over
its own non-blocking sockets, feeding the byte-fed host through
`pancake_host_session_feed_bytes`. There is no blocking C netlayer in that path
and no thread per call.

| Binding | Async idiom | Async type |
| -------------------- | ------------------------------- | ---------------------------------------------------------------------- |
| [`rust/`](rust/) | tokio (opt-in `async` feature) | `Session` over `tokio::net::TcpStream`, on a `LocalSet` |
| [`ts/`](ts/) | native promises (Deno/Bun) | `Session.serve()` over `node:net` (Deno uses its own native sockets) |
| [`python/`](python/) | `asyncio` | `Session.serve()` over `asyncio` streams |
| [`racket/`](racket/) | green threads + ports | `async-connection` over `tcp-connect`/`tcp-listen` |

One async `Session` is one CapTP partner on a `Host`. It lives on one task or
thread. Host verbs do no I/O and never block the event loop; only the socket
reads and writes await.

The inbox each connection accumulates is bounded by the library, not by binding
code. A connection keeps reading only while `recv_stream` or `conn_feed_bytes`
answers "partial frame, read more". A frame that cannot complete within the
peer's `max_frame_bytes` is refused with the typed `FRAME_TOO_LARGE` error the
moment that is knowable. That can be when its length prefix declares past the
cap or when its bytes have already crossed it (ADR-0041). Every binding's smoke
pins this, so a hostile partner cannot grow a binding's inbox without bound.

The outbound side is bounded by write discipline rather than a queue. Every
binding awaits or blocks on its socket writes frame by frame (JS per-frame
`write`, Rust `write_all(...).await`, Python `write` plus an awaited `drain()`
per pump, Racket blocking `write-bytes`). A partner that stops reading stalls
the connection's pump instead of growing a buffer. That matches the Zig blocking
pump posture: bounded memory, with the tradeoff that a write to a slow reader
can head-of-line-block that one connection. The Zig completion loop's high-water
read parking
([ADR-0042](../docs/decisions/adr/ADR-0042-outbound-high-water-backpressure.md))
is the many-connection alternative. Every binding wraps the iroh loop surface of
that shape, each in its own idiom (see [boundaries](../docs/boundaries.md)).

Each async surface also speaks its runtime's native async shapes, so a
consumer runs a serve loop and awaits a send's result rather than polling and
registering callbacks:

| Binding | Serve loop | Awaited send |
| -------------------- | -------------------------------------- | ---------------------------------- |
| [`ts/`](ts/) | `session.serve()` (a resolved-on-close promise) | `await session.send(ref, verb, args)` |
| [`python/`](python/) | `session.serve()` (a completes-on-close task) | `await session.send(ref, verb, args)` |
| [`racket/`](racket/) | `(session-serve sess)` on a green thread | `(session-send sess ref verb args)` |
| [`rust/`](rust/) | `session.serve()` (a completes-on-close future) | `session.send(&ref, verb, args).await` |

The `examples/apps/rooms/` clients each build a small `Room` on this surface, so
the app above reads like an app in every language.

Each binding also exposes a Goblins-shaped **actor layer** in its own idiom. An
actor is the language's native callable. It might be a Rust closure or a Python
callable. It is never a foreign object model. An inbound deliver to a published
actor runs it and resolves the answer with its reply. A leading symbol argument
is the method verb. All four bindings host actors on the driver vat behind the
byte-fed host, through one shared behavior trampoline per process. That mirrors
how `pancake.actors` is native Zig.

| Binding | Actor idiom |
| -------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------- |
| [`racket/`](racket/) | **Goblins-faithful**: `(define (^name bcom arg …) …)` constructors, `methods`, `spawn`, `$` (near), `<-`/`<-np` (eventual), `on`, `bcom`, `with-vat` |
| [`rust/`](rust/) | `session.spawn` over `FnMut(&str, &[Argument])` closures (hosted on the driver vat) |
| [`ts/`](ts/) | `session.spawn` over `(verb, args) => AppValue` callbacks (hosted on the driver vat) |
| [`python/`](python/) | `session.spawn` over `behavior(verb, args)` callables (hosted on the driver vat) |

The Racket layer is the reference shape because it reads like Spritely Goblins,
the way a Racket distributed-systems programmer expects. The model is uniform
across all four bindings and Zig's `pancake.actors`: a reference is local or
far, the eventual-send is location-transparent and returns a vow, and an
inbound deliver to a published actor runs a turn and resolves the answer.
Every binding proves a far-send round-trip in its smoke by eventual-sending to
a partner-hosted actor and observing the answer settle the vow.

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

## The embedder contract (`pancake_host_*`)

A binding that rides the byte-fed host implements one choreography. The library
cannot enforce the full loop at runtime, so each binding keeps it in named
modules. A **pump module** (`ts/stack/pump.ts`, `python/pancake/_pump.py`,
`rust/src/pump.rs`, `racket/private/pump.rkt`) owns the connection byte path: keyed
handshake, feed, flush, serve, and `last_abort`. An **action module**
(`ts/stack/action.ts`, `python/pancake/_action.py`, `rust/src/action.rs`,
`racket/private/action.rkt`) parks and executes via `pancake_host_pump_drain`.
Sync arms park only; async I/O runs after the C loop returns.

The host owns vow tables, mid-turn park, and the drain loop as `kickActions` /
`kick_actions`. Every binding tunes selective session limits through the same C
knobs (`setSessionLimits`, `set_session_limits`, `host-set-session-limits!`).
Discovery dial budgets share that spine too (ADR-0082). Rust also exposes
mint-time codec and local-turn budget through `HostOptions`.

Python owning modules (pump, promise, trampoline, action, gc) call Session and
Host through binding-internal seams (`raw`, `host`, `gc`, `hosted`,
`park_release`, `settle_vow`, and the rest). They never use underscore
reach-ins. `zig build meta-check` enforces that rule.

Racket keeps `drain-host-actions!` in `action.rkt` on purpose. Under a sync host
lock it returns `drain-effects` (parked writes plus deferred fires) for
`with-host-drain` in `session.rkt` to run after unlock. That is a third spelling
next to the async Host kick, not Host-shaped ownership. Moving the switch into
`host.rkt` would tighten coupling between session, host, and action without
collapsing the lock and fire split.

Decode, typed `HostAction`, and the exhaustive `dispatch*` inventory come from
one `arms` table in `tools/gen/binding/host_action.zig`
(`zig build gen-binding-host-action`; `gen-binding-host-action-check` rides
`check`) into `internal/host_action.ts`, `_host_action_gen.py`,
`host_action_gen.rs`, and `host-action-gen.rkt`. Executor arm bodies stay
hand-written for language I/O; each binding's `action` module must call the
generated dispatch.

Each binding also keeps a named **promise** module (`promise.ts`, `_promise.py`,
`promise.rs`, `promise.rkt`) for the `RemotePromise` / `session-vow` handle,
`index` and `untag` projection (including the host vow projection FFI), the
shared fetch and enliven path (mint, await, classify), and the far-send promise
factory (`promiseFor`, `_promise_for`, `send_promise`, `sendFar`, `_send_far`,
`session-far-send`).

Each binding keeps a named **gc** module (`gc.ts`, `_gc.py`, `gc.rs`, `gc.rkt`)
for ADR-0063 opt-in distributed GC (`withGc`, `trackImport`, `drainGc`; Session
binds and opts in only).

Each binding keeps a named **dial** module (`dial.ts`, `_dial.py`, `dial.rs`,
`dial.rkt`) for the unified dial executor (`plan_dial`, `connect`, redeem).

Each binding keeps a named **listen** module (`listen.ts`, `_listen.py`,
`listen.rs`, `listen.rkt`) for `Server`, `listen`, and keyed-tcp hosting.
Session keeps mint wrappers (`establish*`) and CapTP verbs. The keyed handshake
loop lives in pump.

Each binding keeps a named **trampoline** module (`trampoline.ts`,
`_trampoline.py`, `trampoline.rs`, `trampoline.rkt`) for the one
`PancakeHostBehavior` callback, local Forward chase (bounded by
`PANCAKE_MAX_LOCAL_FORWARD_HOPS`), local send and tell arms plus far-tell mint
(TS and Python; Racket folds far tell into `session-far-send`), near and far
send and tell dispatch (`dispatchSend`, `_dispatch_send`, `dispatch-send`; Rust
tell dispatch on `SessionShared`), ADR-0064 caretaker/attenuate factories,
spawn/publish hosting (`spawnHosted`, `_spawn_hosted`,
`register-hosted-actor!`, including actor registration; Rust keeps spawn and
publish on `SessionShared`), mid-turn latch, and reply keep.

Rust also keeps a named **session_shared** module (`session_shared.rs`) for
`Ref`, `Caretaker`, and `SessionShared`.

`examples/c/host_embedder_pump.c` is the compiled checklist: feed plus FLUSH
drain via `pancake_host_pump_drain`, feed-refusal and `last_abort`, EOF and
`break_far_vows`.

`zig build meta-check` fails if a pump, action, promise, gc, dial, listen, or
trampoline module disappears, if a mid-turn park marker disappears, if a
generated decode import disappears, if a session dial or listen re-export
disappears, or if that C reference disappears. The embedder-spine module split is complete.

A Zig-facing `embedder_pump` helper (`src/c_abi/driver/embedder_pump.zig`) and
the opt-in C export `pancake_host_pump_drain` drain through
`pancake_host_next_action`. ADR-0072's fifth and sixth amendments keep the
pull-queue normative. Every binding action module calls the wrapper. Bindings
keep owning their async and sync loop idioms: park in sync arms, await or fire
after.

`include/pancake_driver.h`'s preamble carries the same contract in C-consumer
form; this is the binding author's checklist, written once so four
implementations cannot drift.

- **The one loop rule.** After any top-level `pancake_host_*` call returns OK,
  drain via `pancake_host_pump_drain` (or an equivalent pull of
  `pancake_host_next_action` until `WOULD_BLOCK`), honoring each action:
  `DIAL` (ticket only: borrow the pending view with
  `pancake_host_pending_dial` into a `PancakePendingDial`, open your own
  connection from its transport/designator, drive its session open, and report
  `dialed` or `dial_failed` with the ticket),
  `FLUSH` (drain that connection's `take_outbound` and write the frames),
  `NEED_GIFT_ID` (32 random bytes into `provide_gift_id`), `SETTLE`/`FAIL`
  (route the outcome to whatever awaits the vow the action's `ticket` names).
  Nothing enforces the drain. An ignored action strands the dial, flush,
  handoff, or settlement it carries. Binding action modules must use the
  shared C wrapper. `zig build meta-check` bans a hand-rolled
  `pancake_host_next_action` pop loop there.
- **CapTP product names (ADR-0079).** A binding `Host` is the multi-session
  CapTP product (`pancake_host_*` in `pancake_driver.h`). A binding `Session` is
  the one-partner application object. Map multi-session CapTP work to the host
  tier, not the peer waist. Binding `Node` and binding `Connection` types are
  gone; `net.Connection` is the framed byte stream only.
- **Bytes in, frames out.** Feed raw inbound bytes through `conn_feed_bytes` and
  keep only the unconsumed tail. The core owns frame delimiting for both codecs,
  including the `FRAME_TOO_LARGE` cap. Never hand-roll a frame scanner in the
  binding. That is hostile-input parsing the core already does once. The
  handshake needs no special pump either. Consumption stops at the frame that
  opens the session, so application frames a fast partner coalesced behind its
  hello stay in your tail until you have published and fed again.
- **Feed failure choreography.** A failed feed leaves a typed `op:abort` on the
  outbound queue. Capture `conn_last_abort` or last-error, then run the shared
  action drain (`kick_actions` or `with-host-drain`) so the abort and any
  CLOSE or FAIL queued with it leave through the same FLUSH spine as a steady
  write, not a private `take_outbound` path. Then surface the typed error and
  release.
- **EOF means break.** When the transport reports the connection gone, call
  `conn_break_far_vows` before releasing, so pending vows settle broken with
  the partner's retained abort diagnostic instead of hanging.
- **Mid-turn session release parks.** A behavior that closes its own connection
  inside a hosted turn must not call `pancake_host_session_release` under the
  callback latch. Park the release and drain it after the turn (TypeScript,
  Python, Rust, and Racket; enforced by `zig build meta-check`).
- **The dial executor's posture.** A give whose locator carries direct-address
  hints dials direct. A hint-less iroh give resolves under the binding's
  configured redeem posture. Posture is the binding's knob. It never crosses the
  ABI.
- **Keep the exporter served.** After `dialed`, keep pumping the new exporter
  connection: the withdraw and its resolution ride it immediately.
- **GC releases run on the pumping thread.** A language finalizer only parks
  the token; the drain happens at the head of the next verb on the pumping
  thread, never from the finalizer thread itself.
- **Callback legality.** Callbacks fire on the pumping thread inside the
  enclosing verb. Inside one, the enqueueing verbs are legal (`conn_send`,
  `conn_tell`, the `vow_*` and `turn_*` verbs, `gc_release`,
  `set_exporter_location`) and their effects land when the verb unwinds; the
  host-driving verbs (`feed*`, `take_outbound`, `next_action`,
  `dialed`/`dial_failed`/`provide_gift_id`, `open_*`, publish/spawn,
  `fetch`/`enliven`, `break_far_vows`, release) are refused.
- **Vow outcomes are drain-routed, and the mint IS the registration.** Every
  vow-minting verb (`conn_send`, the `vow_*` pipeline verbs, `conn_fetch`,
  `conn_enliven`) returns the vow id. The outcome arrives as that vow's
  `SETTLE` or `FAIL` action. There is no listener to register and no
  register-before-feed race to lose. Keep a vow-id table filled at mint and
  route each completion to it in the drain. A popped action's value and message
  views are host-owned until the next `next_action`, so copy them out in the
  drain.
- **Struct mirrors are generated or pinned.** TypeScript's struct mirror is
  generated (`zig build gen-ts-abi` covers the ocapn and driver archives
  together, held by `gen-ts-abi-check`). The Racket, Python, and Rust FFI struct
  definitions are hand-mirrored. Each pins its mirror against the header's
  documented sizes and offsets. Rust pins at compile time (`src/sys/driver.rs`'s
  `const` assert block). Python and Racket pin at import time (`_ffi_driver.py`,
  `ffi-shared.rkt`). A C-side layout change that is not swept into a mirror
  fails that binding loudly instead of misparsing the first popped action.

## The iroh transport (optional, a separate artifact)

iroh's encrypted QUIC reaches the bindings as a **separate optional library**,
not folded into the pure-Zig archives: it links a Rust sidecar
([ADR-0055](../docs/decisions/adr/ADR-0055-iroh-netlayer-sidecar.md)), and
keeping it out of those archives is what keeps the core pure Zig and the in-tree
build check self-contained. `zig build iroh-abi` (needs `cargo`) builds
`libpancake_net_transport_iroh`, a _companion_ to the core archives, not a
superset: it exports only the `pancake_iroh_netlayer_*` and
`pancake_iroh_conn_*` families (see
[`include/pancake_net_transport_iroh.h`](../include/pancake_net_transport_iroh.h))
and shares no core symbol with `libpancake_ocapn`. A binding that wants iroh
loads `libpancake_net_transport_iroh` alongside the core set (the core archives
for the peer machinery, iroh for the transport) and gains `listen_iroh` for
hosting; a partner over iroh is dialed through the same `connect` as tcp.

The binding module layout mirrors that artifact split. The transport-neutral
application surface (`connect`, `listen`, and the async `Session`) is re-exported
from each binding's barrel from named `dial` / `listen` / `session` modules and
rides the runtime's own sockets, so a program that dials a `tcp` locator needs
only the core. `connect` takes the locator plus
an optional `Reachability` posture: a `tcp` locator ignores it, an `iroh`
locator requires it (the posture is never guessed). The iroh-touching surface
(`listen_iroh`, the iroh server, and the iroh FFI) lives in a separate
per-transport module (the `@pancake/iroh` package, `pancake.iroh`,
`pancake-iroh.rkt`, Rust's `iroh` feature module). `connect` loads that module
lazily on the first `iroh` locator (Rust selects it at build time through the
opt-in `iroh` feature), so a program that only speaks TCP never imports the iroh
module or links `libpancake_net_transport_iroh`. Rust keeps `connect` and the
`Reachability` enum it takes in the core barrel (`dial.rs`) so the dialer has one
signature whether or not iroh is compiled in. Without the feature an `iroh`
locator fails with a rebuild hint rather than changing the call's shape.

Addressing is the only difference a consumer sees, and it is just a different
locator. There is no `host:port`: a partner is reached by its
self-authenticating endpoint id plus comma-separated direct-address hints,
carried together as an `ocapn://<nodeid>.iroh?direct-addresses=…` URI (the
signed locator uses `"iroh"` as its transport, carries the node id as its
designator, and puts the address hints under `direct-addresses`). Above that,
nothing changes: `connect` on that locator returns the same `Session`,
drives the same in-process pump, and speaks the same OCapN. The iroh netlayer C
ABI has one I/O model (ADR-0057): an event-driven readiness loop, armed when the
netlayer is constructed. The public surface is a single readiness fd
(`pancake_iroh_netlayer_readiness_fd`) the host parks on with its own poller,
plus a non-blocking `pancake_iroh_netlayer_drain_ready` and the `try_accept` /
`try_connect` / `conn_try_read` / `conn_try_write` calls, with no blocking frame
surface. Every binding parks on that fd natively, each in its own idiom: Deno's
`IrohLoop` (a `node:net` socket on a dup'd fd), Python's `_IrohLoop` (asyncio
`add_reader`), Rust's `AsyncFd` task, and Racket's
`unsafe-file-descriptor->semaphore` park. No dedicated polling thread, no
busy-poll. Every binding's loop is held to the same scale bar by a
many-connection build check: `zig build bindings-iroh-loop` runs
`deno-iroh-loop`, `python-iroh-loop`, `rust-iroh-loop`, and `racket-iroh-loop`,
the binding siblings of `iroh-loop`. The
`examples/apps/rooms/` clients dial a transport-neutral locator, so
`zig build demo-rooms-iroh` runs the same cross-language room over iroh; a
binding joins when its runtime and the iroh library are both present.

Every binding also mints and redeems a three-party handoff over iroh through its
own surface. Hinted gives dial the exporter's `direct-addresses` under the
relay-less `Direct` posture (`zig build bindings-iroh-handoff`:
`deno-`, `python-`, `rust-`, and `racket-iroh-handoff`). A give that names the
exporter by node id alone is redeemed under the recipient's configured redeem
posture. `Discovery` is the default. Each binding can lower it to
`DiscoveryNoRelay` through its own knob (`setRedeemReachability` in TS,
`redeem_reachability` in Python, `set-host-redeem-reachability!` in Racket).
Self-contained posture proof:
`bindings-iroh-redeem-posture`. Offline dial-by-id uses `*-iroh-loop`. Live
dial-by-id over n0 uses `bindings-iroh-reachability` (opt-in, out of `check`).
The full shipped story is in [`docs/shipped.md`](../docs/shipped.md).

## Running

```sh
zig build bindings        # rust + deno + bun + python + racket smokes
zig build rust-dogfood    # just the Rust consumer
```

`zig build bindings` requires `cargo`, `deno`, `bun`, `python3`, and `racket` on
PATH, provided by [`../.devcontainer/`](../.devcontainer/). The libraries are
built and installed under `../zig-out/lib/` first.

## Finding the archives

Every binding locates its archives through the same publishable cascade
([ADR-0077](../docs/decisions/adr/ADR-0077-publishable-c-abi-resolve.md)):
configure first, then a versioned download cache, then an optional in-tree
development fallback, then the system search. The machine contract is
[`c-abi-resolve.json`](c-abi-resolve.json); an identical copy ships inside each
binding package so a published crate / wheel / npm package / Racket collection
(or a future separate binding repo) can resolve natives without a Zig checkout.
Download is **language-native** in each binding. The operator script
[`../tools/c-abi/fetch-c-abi.sh`](../tools/c-abi/fetch-c-abi.sh) is for humans and CI only.
Bindings do not shell out to it.

1. **`PANCAKE_LIB_DIR` (configure).** If the environment names a directory, the
   binding loads its archives from there and never downloads. This is the one
   knob for tests, demos, CI, and a packager pointing at a chosen install:
   set `PANCAKE_LIB_DIR=/path` before `zig build` or before running a script
   directly.
2. **Abi-versioned download cache.** Otherwise, when a cache already holds the
   archives for this `abi_version` and host target, that directory wins.
   Markers differ by link style: Rust looks for the static
   `libpancake_ocapn.a`; Python / TypeScript / Racket look for the shared
   `libpancake_ocapn.so` / `.dylib` / `.dll`. If the cache is cold and no
   in-tree `zig-out/lib` is discoverable, the binding may soft-fail a *network*
   download of `pancake-c-v{version}-{target}.tar.gz` from the `v*` GitHub
   release (`PANCAKE_RELEASE_BASE_URL`, default
   `https://github.com/jimisaacs/pancake/releases/download`). Hygiene and
   security refusals always fail closed: non-HTTPS without
   `PANCAKE_ALLOW_INSECURE`, checksum miss/mismatch, and zip-slip / link
   members hard-fail regardless of `PANCAKE_STRICT`. The contract
   field `releases_published` is the prerelease valve: when it is `false`,
   loaders skip that network attempt unless `PANCAKE_DOWNLOAD=1`. When it is
   `true`, they fetch unless `PANCAKE_SKIP_DOWNLOAD=1`. `PANCAKE_DOWNLOAD=1`
   also refreshes the cache even when in-tree `zig-out/lib` already has the
   markers (including before the first public release). Before extract the
   binding **requires** `SHA256SUMS` and verifies the exact tarball entry,
   then extracts **only** the `lib/` prefix (no path traversal / link
   members). Transfers are size-capped and HTTPS-only
   (`PANCAKE_ALLOW_INSECURE=1` is the escape hatch). Cache base is
   `PANCAKE_CACHE_DIR`, else `$XDG_CACHE_HOME/pancake/c-abi`, else
   `~/.cache/pancake/c-abi/{version}/{target}/lib`, else the process temp dir.
   Version comes from `include/pancake_ocapn.h` when a pancake checkout is
   discoverable, otherwise from the package-shipped contract's `abi_version`.
   `PANCAKE_STRICT=1` makes a failed *network* fetch fail closed instead of
   soft-failing (missing curl/tar, download error, lock timeout).
   Truthy env values are `1`, `true`, and `yes` (case-insensitive, trimmed).
   Host targets match `zig build release-pack` (`x86_64-linux`, …); see
   [`../tools/c-abi/c-abi-host-aliases.json`](../tools/c-abi/c-abi-host-aliases.json). Rust uses
   `CARGO_CFG_TARGET_ARCH` / `CARGO_CFG_TARGET_OS` (already those names);
   the other ports normalize host aliases (`amd64`/`x64`, `arm64`,
   `darwin`/`macosx`). Published release-pack OS list today is linux + macos
   only; Windows consumers need `PANCAKE_LIB_DIR` or in-tree `zig-out` until a
   Windows release matrix leg exists. That leg is blocked on portable
   `release-pack`, the iroh `.a` link path, and Windows TCP with `std.Io` (see
   ADR-0077). Formula pins for URL, cache, and `want_fetch` live in
   [`../tools/c-abi/c-abi-resolve-cases.json`](../tools/c-abi/c-abi-resolve-cases.json) and are checked
   by `meta_check`.
3. **`zig-out/lib` (dev fallback).** Otherwise, when a pancake checkout is
   discoverable (in-tree binding checks), the binding uses that build output. That is
   what the build checks cover with no environment set. Published packages skip
   this rung.
4. **The bare library name (find).** Otherwise, Unix bindings may hand the
   loader a bare `lib<archive>.<suffix>` name (OS search path) with a warning.
   Windows refuses bare DLL names (search-order plant risk) on every shared-lib
   port (Python, TypeScript, and Racket) and requires `PANCAKE_LIB_DIR` or a
   populated cache instead; `meta_check` holds that refuse message.

For the load-time bindings (the TypeScript, Python, and Racket FFIs) this runs
on each `dlopen`; the Deno binding check passes `--allow-env` so the configure leg is
reachable. Rust links the core/tcp/inproc archives **statically**, so the
cascade is a build-time link-search path there; only the dynamically-loaded iroh
sidecar carries it forward as a runtime rpath. The per-platform archive sets
are packaged by `zig build release-pack` and, when `releases_published` is
true, published from a version tag by the release workflow
(`.github/workflows/release.yml`), each tarball named by `pancake_abi_version`
and its target. `workflow_dispatch` builds the same artifacts without creating
a GitHub release.

### Publishing C archives (flip checklist)

Until `releases_published` is flipped, cold-cache resolves do not hit the
network, and a `v*` tag does not call `gh release create`. `zig build
release-pack` stages a checksummed per-target tarball under
`zig-out/release/`. Shared-library soname symlinks are dereferenced so the
archive contains only regular files, which is ADR-0077 extract hygiene. To
publish:

1. Confirm `zig build release-pack` succeeds on each published OS/arch.
2. Set `releases_published: true` in [`c-abi-resolve.json`](c-abi-resolve.json)
   and copy it into every path listed under `package_copies`.
3. Tag `v{abi_version}` matching `include/pancake_ocapn.h` and the contract.
4. Push the tag; confirm the release workflow publishes (not
   `publish disabled (releases_published is false)`).
5. Smoke a cold-cache resolve against the live URL. Before the flip, rehearse
   fetch with `PANCAKE_DOWNLOAD=1` only.

Do not flip `releases_published` before the GitHub release assets exist.
Cold-cache clients would otherwise fetch 404s.
