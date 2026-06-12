# Consuming pancake from C

This page is the route for anyone calling `libpancake` through its C ABI —
from C itself, or from any language with a C foreign-function interface. It
goes build, link, first program, ownership rules, and then points at the four
shipped bindings as worked references. The header itself,
[`include/pancake.h`](../include/pancake.h), documents every function's
ownership behavior individually; this page is the orientation those comments
assume.

## Build and link

One command builds everything:

```sh
zig build
```

That installs the artifacts under `zig-out/`: `zig-out/lib/libpancake.a` and
`libpancake.so` (plus the platform's versioned names), and
`zig-out/include/pancake.h`. The header is generated from the Zig source by
`zig build gen-header`, and `zig build check` fails if the committed copy is
stale, so the header you compile against cannot disagree with the library you
link.

Linking statically needs nothing beyond libc:

```sh
cc -o my_app my_app.c -Izig-out/include zig-out/lib/libpancake.a
```

For the shared library, link `-Lzig-out/lib -lpancake` and arrange your
platform's runtime path. From another language's build system, those are the
only two facts you need: one include directory, one library.

## The first program

Read [`examples/c/echo_peer.c`](../examples/c/echo_peer.c) before writing
anything. It is a complete program — about 190 lines — in which two peers
hold an echo conversation entirely in memory: the host publishes a capability
behind a name, the client fetches it and calls it, and the reply round-trips.
Every pattern a real consumer needs appears once: the
`recv_stream` / `step` / `take_outbound` pump, event routing with
`peek_event` and the typed polls, and a release call for everything the
library hands over. `zig build examples` compiles and runs it, so it cannot
drift from the header.

The other two C examples are single-topic:
[`examples/c/frame_view.c`](../examples/c/frame_view.c) shows the owned-frame
versus borrowed-view distinction, and
[`examples/c/context_alloc.c`](../examples/c/context_alloc.c) shows routing
all of a handle family's allocation through your own allocator with
`PancakeContext`.

## The shape of the ABI

A `PancakePeer` is a sans-I/O protocol state machine. It owns no socket and
never blocks: you feed it inbound bytes, you call `pancake_peer_step` to let
it work, and you drain the frames it wants sent. Your event loop — sockets,
threads, language runtime — stays entirely yours. For consumers that want the
batteries, the ABI also ships a blocking TCP layer (`pancake_tcp_connect`,
`pancake_tcp_listen`, `pancake_tcp_accept`) that pairs frame read/write
calls with the same peer. The same handle shape has a socket-free sibling, the
in-process layer (`pancake_inproc_connect`, `pancake_inproc_listen`,
`pancake_inproc_accept`): two peers wired by in-process pipes, addressed by a
string designator instead of `host:port` — the path a smoke test dials to run a
full OCapN conversation without touching a socket. Addresses themselves are
core OCapN vocabulary: `pancake_uri_parse_peer` / `pancake_uri_format_peer` (and
the sturdyref pair) convert an `ocapn://` URI to and from a `PancakeLocator`
read through the `pancake_locator_*` accessors, so a consumer dispatches on the
parsed `transport` and never hand-rolls a percent codec.

pancake's one encrypted netlayer, iroh, is opt-in and separate. `libpancake` is pure Zig and
cleartext-only; iroh's QUIC links a Rust sidecar
([ADR-0055](decisions/adr/ADR-0055-iroh-netlayer-sidecar.md)), so it ships as a
distinct optional library, `libpancake_iroh` (`zig build iroh-abi`, needs
cargo). That library is a *superset*: it carries this whole ABI plus a
`pancake_iroh_netlayer_*` / `pancake_iroh_conn_*` family with the same
frame-read/write shape as the TCP layer. A consumer that wants iroh links it
instead of `libpancake` and includes both
[`include/pancake_iroh.h`](../include/pancake_iroh.h) and `pancake.h`;
addressing moves from `host:port` to an endpoint id plus direct-address hints.

Every function returns an `int32_t` return code; `PANCAKE_OK` is zero,
errors are negative and named, and `pancake_last_error` carries a per-thread
diagnostic string for the call that just failed. Out-structs are written only
on `PANCAKE_OK` — on failure there is nothing to release.

Threading is single-owner by contract: serialize every call on a given peer
onto one thread or behind one lock. Distinct peers are independent.

## Ownership in one place

The header states each function's behavior next to its declaration; the whole
vocabulary is four rules.

1. **You give borrowed bytes.** Inputs you pass — `pancake_peer_recv_stream`
   bytes, a `PancakeFrame`'s pointer, a swiss number, an argument's string —
   are borrowed for that one call. The library copies what it must retain
   before returning; the pointer stays yours.
2. **You receive owned values, and you release them.** Anything the library
   fills for you to keep — a `PancakeManagedFrame` from `take_outbound`, a
   `PancakeDeliver` or `PancakeResolve` from a typed poll, a `PancakeEvent` —
   has a matching `pancake_*_release` function, and exactly one call to it.
3. **Handles release through their constructor's family.**
   `pancake_peer_new` pairs with `pancake_peer_release`; the same holds for
   contexts, netlayers, connections, and listeners. The `*_in` constructors
   allocate the whole handle family through a `PancakeContext` you supply and
   free it back through the same context, so a host can account every byte.
4. **One transfer is explicit.** `pancake_peer_feed_owned` is the single call
   that takes ownership *from* you, and it takes it even on failure: a
   refused frame is released through its own callback and your struct is
   cleared, so a late release is a harmless no-op. Only a NULL-pointer
   refusal leaves the frame yours. Its borrowed sibling,
   `pancake_peer_feed_borrowed`, dispatches during the call and retains
   nothing.

If a call's behavior ever seems to disagree with these rules, the comment on
its declaration in `pancake.h` is the contract.

## The bindings as worked answers

[`bindings/`](../bindings/README.md) holds four consumers of this exact
surface — Rust, Deno, Python, and Racket — each wrapping the same calls in
its language's idiom, each exercised by `zig build bindings`, and each
holding a live conversation with a real Goblins peer in its
`*-goblins-interop` gate. When you are unsure how a sequence of calls
composes, the binding nearest your language is a tested, runnable answer.
