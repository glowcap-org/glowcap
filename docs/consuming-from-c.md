# Consuming pancake from C

This is the route for anyone calling pancake's C ABI, whether from C itself or
from any language with a C foreign-function interface. It walks through building
and linking, then a first complete program and the ownership rules, and finally
points at the four shipped bindings as worked references. The C ABI ships as a
set of composable per-family archives you link à la carte (ADR-0059):
`libpancake_ocapn` carries the sans-io peer and the shared vocabulary, each
transport is its own archive, and the byte-fed host tier is its own archive
(`libpancake_driver`). The per-archive headers document every
function's ownership behavior next to its declaration, and
[`include/pancake_ocapn.h`](../include/pancake_ocapn.h) is the one to read
first. This page is the orientation those comments assume.

## Build and link

One command builds everything:

```sh
zig build
```

That installs the archives under `zig-out/lib/` (each in static `.a` and shared
`.so` form, plus the platform's versioned names) and their headers under
`zig-out/include/`:

| Archive                           | Header                           | What it carries                                                                                  |
| --------------------------------- | -------------------------------- | ------------------------------------------------------------------------------------------------ |
| `libpancake_ocapn`                | `pancake_ocapn.h`                | the sans-io peer, contexts, frames, events, URIs: the shared vocabulary every consumer needs    |
| `libpancake_driver`               | `pancake_driver.h`               | the byte-fed host tier (`pancake_host_*`): a multi-connection node you feed and drain yourself, with publish/fetch/send, vows, and the three-party handoff inside the library (ADR-0072) |
| `libpancake_net`                  | —                                | the net-core base; links in the chain, exports nothing on its own                                |
| `libpancake_net_transport_tcp`    | `pancake_net_transport_tcp.h`    | the blocking TCP layer (`pancake_tcp_*`): the frame boundary plus the owning `PancakeTcpSession` |
| `libpancake_net_transport_inproc` | `pancake_net_transport_inproc.h` | the socket-free in-process layer (`pancake_inproc_*`)                                            |
| `libpancake_net_transport_iroh`   | `pancake_net_transport_iroh.h`   | encrypted QUIC (`pancake_iroh_*`); optional, links the Rust sidecar                             |

Each header is generated from its Zig source: `pancake_ocapn.h` by
`zig build gen-header-ocapn`, the transport headers by
`zig build gen-header-net-transport-tcp` and `gen-header-net-transport-inproc`,
and `pancake_driver.h` by `zig build gen-header-driver`. `zig build check`
fails if a committed copy is stale, so the header you compile against cannot
disagree with the archive you link.

You link only the archives you use. A TCP consumer takes the chain
`ocapn + net + tcp`; statically, that needs nothing beyond libc:

```sh
cc -o my_app my_app.c -Izig-out/include \
   zig-out/lib/libpancake_net_transport_tcp.a \
   zig-out/lib/libpancake_net.a \
   zig-out/lib/libpancake_ocapn.a
```

For the shared archives, link
`-Lzig-out/lib -lpancake_net_transport_tcp
-lpancake_net -lpancake_ocapn` and
set your platform's runtime path. From another language's build system, all you
need are one include directory and the archive set your transport calls for. The
archives are symbol-disjoint, so they compose without a duplicate-symbol
collision; `examples/c/compose_transports.c` links `ocapn + tcp + inproc` at
once as the standing proof.

## The first program

Read [`examples/c/echo_peer.c`](../examples/c/echo_peer.c) before you write
anything. It is a complete program in which two peers hold an echo conversation
entirely in memory: the host publishes a capability behind a name, the client
fetches it and calls it, and the reply round-trips. Every pattern a real
consumer needs appears once: the `recv_stream` / `next_event` / `take_outbound`
pump, and a release call for everything the library hands over. `zig build
examples` compiles and runs it, so it cannot drift from the header.

The other two C examples are single-topic:
[`examples/c/frame_view.c`](../examples/c/frame_view.c) shows the owned-frame
versus borrowed-view distinction, and
[`examples/c/context_alloc.c`](../examples/c/context_alloc.c) shows routing all
of a handle family's allocation through your own allocator with
`PancakeContext`.

## The shape of the ABI

A `PancakePeer` is a sans-I/O protocol state machine. It owns no socket and
never blocks: you feed it inbound bytes, take the events it surfaces, and drain
the frames it wants sent. Your event loop (sockets, threads, language runtime)
stays entirely yours. For consumers that want the batteries, the ABI also ships
a blocking TCP layer (`pancake_tcp_connect`, `pancake_tcp_listen`,
`pancake_tcp_accept`) that pairs frame read/write calls with the same peer.

Taking an event is one call. `pancake_peer_next_event` drives the peer to idle
and hands back the next event fully projected: a deliver or a resolve arrives as
structured values, and anything the typed surface cannot carry arrives as its
originating wire frame. Release each event with `pancake_any_event_release`.
`pancake_peer_step` is the manual gear underneath it, for a host that wants to
advance one unit of work at a time.

A consumer that only wants to dial a peer, fetch a capability, and call it does
not have to run that pump at all. `libpancake_net_transport_tcp` also ships an
owning `PancakeTcpSession`, the C spelling of the Zig `driver.Connection`
(ADR-0062): `pancake_tcp_session_connect` dials and completes the keyed
handshake, `pancake_tcp_session_fetch(name)` yields a `PancakeReference`,
`pancake_tcp_session_call(target, verb, args)` delivers and pumps until the
answer settles into a `PancakeSettled`, and `pancake_tcp_session_release` tears
it down. It reuses `pancake_ocapn.h`'s `PancakeReference` / `PancakeArgument`
value vocabulary by layout; `PancakeSettled` itself is the owning session's
outcome, declared in `pancake_net_transport_tcp.h` beside its only producer. The
session is a client: it pairs with an actor-runtime host (a Zig `driver.Server`,
a binding, or a Goblins vat), the same hosting half the Zig `Connection` dials.
The sans-io peer below it is the right primitive when _you_ own the loop and the
host. `test/c_abi/tcp_session_test.zig` is the worked round trip.

The same handle shape has a socket-free sibling, the in-process layer
(`pancake_inproc_connect`, `pancake_inproc_listen`, `pancake_inproc_accept`).
Two peers are wired by in-process pipes and addressed by a string designator
instead of `host:port`, the path a smoke test dials to run a full OCapN
conversation without touching a socket.

Addresses themselves are core OCapN vocabulary:
`pancake_uri_parse_peer` / `pancake_uri_format_peer` (and the sturdyref pair)
convert an `ocapn://` URI to and from a `PancakeLocator` read through the
`pancake_locator_*` accessors, so a consumer dispatches on the parsed
`transport` and never hand-rolls a percent codec.

pancake's one encrypted netlayer, iroh, is opt-in and separate. The pure-Zig
archives are cleartext-only; iroh's QUIC links a Rust sidecar
([ADR-0055](decisions/adr/ADR-0055-iroh-netlayer-sidecar.md)), so it ships as a
distinct optional library, `libpancake_net_transport_iroh`
(`zig build iroh-abi`, needs cargo). Like the other transport archives it is a
_companion_, not a superset: it exports only a `pancake_iroh_netlayer_*` /
`pancake_iroh_conn_*` family (with the same frame-read/write shape as the TCP
layer) and shares no core symbol with `libpancake_ocapn`. A consumer that wants
iroh adds `libpancake_net_transport_iroh` to its link line and includes
[`include/pancake_net_transport_iroh.h`](../include/pancake_net_transport_iroh.h),
which `#include`s `pancake_ocapn.h` and reuses its frame/context types by
layout. Addressing moves from `host:port` to an endpoint id plus direct-address
hints; iroh-call diagnostics read through `pancake_iroh_last_error` (its own
per-thread slot).

Every function returns an `int32_t` return code. `PANCAKE_OK` is zero, errors
are negative and named, and `pancake_last_error` carries a per-thread diagnostic
string for the call that just failed. Out-structs are written only on
`PANCAKE_OK`, so on failure there is nothing to release.

Threading is single-owner by contract: serialize every call on a given peer onto
one thread or behind one lock. Distinct peers are independent.

The surface is the size it is on purpose. Each function is one of three things
and never a fourth: a distinct protocol operation, the primitive a binding
actually consumes, or a named easy path over an explicit one. The structural
shape is gated so it cannot bloat unnoticed: one allocator twin per constructor,
one error channel per archive, one freeing verb per handle.
[ADR-0059](decisions/adr/ADR-0059-composable-c-abi-archives.md) records that bar
and why the obvious "one config-struct constructor" shortcut is rejected.

## Ownership in one place

The header states each function's behavior next to its declaration; the whole
vocabulary is four rules.

1. **You give borrowed bytes.** Inputs you pass (`pancake_peer_recv_stream`
   bytes, a `PancakeFrame`'s pointer, a swiss number, an argument's string) are
   borrowed for that one call. The library copies what it must retain before
   returning; the pointer stays yours.
2. **You receive owned values, and you release them.** Anything the library
   fills for you to keep (a `PancakeManagedFrame` from `take_outbound`, a
   `PancakeAnyEvent` from `next_event`, a `PancakeEvent`) has a matching
   `pancake_*_release` function, and you call it exactly once.
3. **Handles release through their constructor's family.** `pancake_peer_new`
   pairs with `pancake_peer_release`; the same holds for contexts, netlayers,
   connections, and listeners. The `*_in` constructors allocate the whole handle
   family through a `PancakeContext` you supply and free it back through the
   same context, so a host can account every byte.
4. **One transfer is explicit.** `pancake_peer_feed_owned` is the single call
   that takes ownership _from_ you, and it takes it even on failure: a refused
   frame is released through its own callback and your struct is cleared, so a
   late release is a harmless no-op. Only a NULL-pointer refusal leaves the
   frame yours. Its borrowed sibling, `pancake_peer_recv_borrowed`, dispatches
   during the call and retains nothing.

If a call's behavior ever seems to disagree with these rules, the comment on its
declaration in the archive's header (`pancake_ocapn.h` for the peer surface, the
transport header for a transport call) is the contract.

## The bindings as worked answers

[`bindings/`](../bindings/README.md) holds four consumers of this exact surface
(Rust, Deno, Python, and Racket), each wrapping the same calls in its
language's idiom, each exercised by `zig build bindings`, and each holding a
live conversation with a real Goblins peer in its `*-goblins-interop` gate. When
you are unsure how a sequence of calls composes, the binding nearest your
language is a tested, runnable answer.
