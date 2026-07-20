# bindings/racket

A Racket consumer of the pancake C ABI archives. The binding mirrors the
à-la-carte archive set (ADR-0059): one public module for the core, one per
transport. You compose the pieces you need: `(require "pancake.rkt")` for the
session surface, then the transport module you want, the same way a C
consumer links archives or a Zig consumer imports modules. See
[`../README.md`](../README.md) for the shipped C ABI surface and how the
bindings are gated.

The binding exposes one tier: the CapTP `session` over the byte-fed host
archive (`libpancake_driver`, ADR-0072 / ADR-0079). The host owns an
`engine.Node` (the sans-io router). The raw `pancake_peer_*` family has no
Racket wrapper; it stays a C-consumer surface, covered by the Zig C-ABI tests
and the C examples. The wire codec is a host option: `connect` and `listen`
take `#:codec` (`'syrup` by default, `'capnp` for a Cap'n Proto session). Both
ends must agree, exactly as on the C tier's `pancake_host_new`. Host
`connect` / `listen` stay on Goblins CapTP `"1.0"`; the pancake-forward
`next` / `"pancake-next"` track is available as ABI constants
(`CAPTP-VERSION-NEXT`) for the raw negotiated-peer C surface, not as a Host
option. Goblins interop uses `"1.0"`.

## Module map

Each public module's internal loader opens only its own archive, so requiring
the core links no transport, and requiring one transport links no other.

| Module                                     | Archive it loads                         | What it offers                                                                                                                                                                                                                                                                                       |
| ------------------------------------------ | ---------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [`pancake.rkt`](pancake.rkt)               | `libpancake_ocapn` + `libpancake_driver` | The session surface (`connect`, `listen`, `accept`, `session-*`) over the byte-fed host and Racket's scheduler-aware TCP ports, plus the Goblins-shaped vat (`spawn`, `$`, `<-`, `on`, `bcom`, `methods`), native-value marshalling, typed errors, and OCapN locator URIs. |
| [`pancake-tcp.rkt`](pancake-tcp.rkt)       | `libpancake_net_transport_tcp`           | Blocking TCP netlayer handles: `make-netlayer`, `netlayer-listen`, `netlayer-connect`, `listener-accept`, the `endpoint-*` whole-frame shuttle, and `tcp-last-error`.                                                                                                                   |
| [`pancake-inproc.rkt`](pancake-inproc.rkt) | `libpancake_net_transport_inproc`        | The socket-free in-process netlayer, addressed by a string designator: `make-inproc-netlayer`, `inproc-netlayer-listen`, `inproc-netlayer-connect`, `inproc-listener-accept`, the `inproc-endpoint-*` shuttle, and `inproc-last-error`.                                                              |
| [`pancake-iroh.rkt`](pancake-iroh.rkt)     | `libpancake_net_transport_iroh` (lazily) | Optional encrypted-QUIC netlayer: `listen-iroh`, the `iroh-server-*` surface, and the `IROH-REACH-*` postures. `connect` loads it on the first `iroh` locator, so a program that never speaks iroh neither links the library nor requires this module.                                           |

The core is the universal base. The transport modules build on it (they share
the frame layout through the core's transport seam, and they are
symbol-disjoint) but they never depend on each other.

```racket
(require "pancake.rkt")        ; the session surface and the vat

;; Against a peer that publishes "greeter" (see site Start / CLI listen --publish).
(define sess (connect (tcp-locator "127.0.0.1" 9099)))
(define greeter (session-fetch sess "greeter")) ; a capability, by name
(session-send sess greeter 'greet "world")      ; eventual-send, settled to a value
(session-close! sess)
```

One rule inside a hosted behavior: a method runs on the pumping thread, inside
the enclosing feed, so it must neither drive the host nor park the thread on
something only another green thread can provide. A `session-fetch` or
`session-send` on this host mid-turn is refused loud by the C tier's callback
latch, and the refusal breaks the method's own answer (the smoke pins this).
Racket CS may run the trampoline in atomic mode, where a blocking
`async-channel-get`-style wait deadlocks the place. Return a value, `bcom`, or
a forward; hand longer work to another thread and settle it through an
eventual-send.

## The internal FFI split

The raw `ffi/unsafe` layer is never required by a consumer. It follows
Racket's `private/` convention and mirrors the C ABI's own module split: one
shared types leaf (`ffi-shared`), one archive resolve/open module
(`lib-resolve`, the ADR-0077 cascade), one loader per archive (`ffi-ocapn`,
`ffi-driver`, `ffi-tcp`, `ffi-inproc`, and a lazy `ffi-iroh` that names
`zig build iroh-abi` when the archive is absent), the hand-mirrored constants
(`constants.rkt`, held to the headers by `zig build meta-check`), and the
shared seam the transport and actors companions build on (`seam.rkt`). Each
loader's bound functions and out-cell wrappers are generated from the Zig
exports (the `ffi-*-gen.rkt` siblings, `zig build gen-binding-racket-ffi`,
held fresh by the check build); the hand loader owns the prose, the cstruct
declarations, and any wrapper too bespoke to derive. Each
transport archive keeps its own thread-local last-error, read through that
archive's own reader (`tcp-last-error`, `inproc-last-error`), never the ocapn
family's `last-error`.

## The public surface, split by responsibility

`pancake.rkt` is a thin barrel: it requires one `private/` module per
responsibility (errors, values, the argument codec, the vat, the wire
trampoline, locators, the transport layer, the host, host actions, far vows,
GC, dial, listen, the byte pump, and the session verbs) and re-provides their
public surface unchanged, so `(require "pancake.rkt")` is one import for a
consumer. It also carries the `seam` submodule that re-provides the
binding-internal transport seam.

Two vat boundaries are consumer-visible and deliberate, pinned by the smoke
and the `bench-goblins` app parity. There is no cross-actor turn
transactionality: an outer turn erroring after an inner `$`'s `bcom` leaves
the inner swap installed, where Goblins would roll it back. And time-travel
is accept-side (server) only today: `accept` takes `#:time-travel?`;
`connect` and the iroh surface do not.

[`zig-smoke.rkt`](zig-smoke.rkt) is the consumer `zig build bindings` runs. It
drives real OCapN conversations through the session surface: keyed handshakes,
pipelining, projections, proxies, a Cap'n Proto session through `#:codec`, and
distributed GC observed on the wire through a sniffing relay. It then composes
the host tier with each explicit transport module to shuttle a counter call over
the in-process and TCP netlayers. Racket must be on `PATH` (provided
by [`../../.devcontainer/`](../../.devcontainer/)). The build step typically
resolves archives from in-tree `zig-out/lib` (ADR-0077's in-tree discovery step), or from
`PANCAKE_LIB_DIR` / the versioned download cache when configured.

```sh
zig build bindings        # builds the pancake archives, runs every binding consumer
zig build racket-dogfood  # just the Racket consumer
```
