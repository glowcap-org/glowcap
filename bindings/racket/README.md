# bindings/racket

A Racket consumer of the pancake C ABI archives, shaped to mirror the à-la-carte
archive set (ADR-0059): one public module for the core, and one public module
per transport. A Racketeer composes the pieces they need —
`(require "pancake.rkt")` for the OCapN peer, plus the transport module they
want — exactly as a C consumer links archives or a Zig consumer imports modules.
See [`../README.md`](../README.md) for the shipped C ABI surface and how the
bindings are gated.

## Module map

Each public module's internal loader opens only its own archive, so requiring
the core links no transport, and requiring one transport links no other.

| Module                                     | Archive it loads                         | What it offers                                                                                                                                                                                                                                                                                       |
| ------------------------------------------ | ---------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [`pancake.rkt`](pancake.rkt)               | `libpancake_ocapn`                       | The core, usable alone: the `peer`, native-value marshalling, typed events, the Goblins-shaped vat (`spawn`, `$`, `<-`, `on`, `bcom`, `methods`), OCapN locator URIs, and the high-level `connection` surface (`connect`, `listen`, `accept`, `conn-*`) over Racket's own scheduler-aware TCP ports. |
| [`pancake-tcp.rkt`](pancake-tcp.rkt)       | `libpancake_net_transport_tcp`           | The explicit blocking TCP netlayer handles: `make-netlayer`, `netlayer-listen`, `netlayer-connect`, `listener-accept`, the `endpoint-*` whole-frame shuttle, and `tcp-last-error`.                                                                                                                   |
| [`pancake-inproc.rkt`](pancake-inproc.rkt) | `libpancake_net_transport_inproc`        | The socket-free in-process netlayer, addressed by a string designator: `make-inproc-netlayer`, `inproc-netlayer-listen`, `inproc-netlayer-connect`, `inproc-listener-accept`, the `inproc-endpoint-*` shuttle, and `inproc-last-error`.                                                              |
| [`pancake-iroh.rkt`](pancake-iroh.rkt)     | `libpancake_net_transport_iroh` (lazily) | The optional encrypted-QUIC netlayer: `listen-iroh`, the `iroh-server-*` surface, and the `IROH-REACH-*` postures. `connect` loads it on the first `iroh` locator, so a program that never speaks iroh neither links the library nor requires this module.                                           |

The core is the universal base. The transport modules build on it — they share
the `PancakeContext` pointer and the frame layout through the core's transport
seam, and they are symbol-disjoint — but they never depend on each other.

```racket
(require "pancake.rkt")        ; the OCapN peer, vat, and high-level connection
(require "pancake-tcp.rkt")    ; add the explicit C-ABI TCP netlayer, à la carte

(define p (make-peer/raw-open))
(peer-register-import! p 5)
(peer-send-deliver! p (far 5) (list 42 #"hi") #:answer 9)   ; native int, bytes
(peer-step! p)
(peer-take-outbound p)
;; ...and (peer-poll p) returns deliver-event / resolve-event / other-event
```

## The internal FFI split

The raw `ffi/unsafe` layer is never required by a consumer; it follows Racket's
`private/` convention and mirrors the C ABI's own module split:

- [`private/ffi-shared.rkt`](private/ffi-shared.rkt) — the shared frame,
  allocator, reference, argument, and event cstructs the archives agree on by
  layout. It opens no library, the Racket mirror of the C ABI's `c_abi/shared`
  leaf.
- [`private/ffi-core.rkt`](private/ffi-core.rkt) — opens `libpancake_ocapn` and
  binds the core `pancake_*` family.
- [`private/ffi-tcp.rkt`](private/ffi-tcp.rkt) — opens
  `libpancake_net_transport_tcp` and binds `pancake_tcp_*`.
- [`private/ffi-inproc.rkt`](private/ffi-inproc.rkt) — opens
  `libpancake_net_transport_inproc` and binds `pancake_inproc_*`.
- [`private/ffi-iroh.rkt`](private/ffi-iroh.rkt) — loads
  `libpancake_net_transport_iroh` lazily on first use, naming the build step
  (`zig build iroh-abi`, needs cargo) when it is absent.
- [`private/constants.rkt`](private/constants.rkt) — the generated ABI
  constants.

Each transport archive keeps its own thread-local last-error, read through that
archive's own reader (`tcp-last-error`, `inproc-last-error`), never the ocapn
family's `last-error`.

[`zig-smoke.rkt`](zig-smoke.rkt) is the consumer `zig build bindings` runs: it
drives a real OCapN round-trip through the core API, then composes the core with
each explicit transport module to shuttle a counter call over the in-process and
TCP netlayers. Racket must be on `PATH` (provided by
[`../../.devcontainer/`](../../.devcontainer/)); the build step resolves the
shared libraries relative to `zig-out/`.

```sh
zig build bindings        # builds the pancake archives, runs every binding consumer
zig build racket-dogfood  # just the Racket consumer
```
