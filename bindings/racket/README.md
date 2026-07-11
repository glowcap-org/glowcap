# bindings/racket

A Racket consumer of the pancake C ABI archives. The binding mirrors the
à-la-carte archive set (ADR-0059): one public module for the core, one per
transport. You compose the pieces you need: `(require "pancake.rkt")` for the
connection surface, then the transport module you want, the same way a C
consumer links archives or a Zig consumer imports modules. See
[`../README.md`](../README.md) for the shipped C ABI surface and how the
bindings are gated.

The binding exposes one tier: the `connection` over the byte-fed host archive
(`libpancake_driver`, ADR-0072). The raw `pancake_peer_*` family has no Racket
wrapper — it stays a C-consumer surface, covered by the Zig C-ABI tests and
the C examples. The wire codec is a host option: `connect` and `listen` take
`#:codec` (`'syrup` by default, `'capnp` for a Cap'n Proto session; both ends
must agree, exactly as on the C tier's `pancake_host_new`). The upstream
pre-spec profile is not on the binding surface.

## Module map

Each public module's internal loader opens only its own archive, so requiring
the core links no transport, and requiring one transport links no other.

| Module                                     | Archive it loads                         | What it offers                                                                                                                                                                                                                                                                                       |
| ------------------------------------------ | ---------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [`pancake.rkt`](pancake.rkt)               | `libpancake_ocapn` + `libpancake_driver` | The core: the `connection` surface (`connect`, `listen`, `accept`, `conn-*`) over the byte-fed host archive (`libpancake_driver`, ADR-0072) and Racket's own scheduler-aware TCP ports, the Goblins-shaped vat (`spawn`, `$`, `<-`, `on`, `bcom`, `methods`), native-value marshalling, typed errors, and OCapN locator URIs.                                                                          |
| [`pancake-tcp.rkt`](pancake-tcp.rkt)       | `libpancake_net_transport_tcp`           | The explicit blocking TCP netlayer handles: `make-netlayer`, `netlayer-listen`, `netlayer-connect`, `listener-accept`, the `endpoint-*` whole-frame shuttle, and `tcp-last-error`.                                                                                                                   |
| [`pancake-inproc.rkt`](pancake-inproc.rkt) | `libpancake_net_transport_inproc`        | The socket-free in-process netlayer, addressed by a string designator: `make-inproc-netlayer`, `inproc-netlayer-listen`, `inproc-netlayer-connect`, `inproc-listener-accept`, the `inproc-endpoint-*` shuttle, and `inproc-last-error`.                                                              |
| [`pancake-iroh.rkt`](pancake-iroh.rkt)     | `libpancake_net_transport_iroh` (lazily) | The optional encrypted-QUIC netlayer: `listen-iroh`, the `iroh-server-*` surface, and the `IROH-REACH-*` postures. `connect` loads it on the first `iroh` locator, so a program that never speaks iroh neither links the library nor requires this module.                                           |

The core is the universal base. The transport modules build on it (they share
the frame layout through the core's transport seam, and they are
symbol-disjoint) but they never depend on each other.

```racket
(require "pancake.rkt")        ; the connection surface and the vat

(define server (listen "127.0.0.1" 0))
(define conn (connect (tcp-locator "127.0.0.1" (server-port server))))
(define svc (conn-fetch conn "svc"))        ; a partner's published capability
(conn-send conn svc 'add 5)                 ; eventual-send, settled to a value
```

One rule inside a hosted behavior: a method runs on the pumping thread, inside
the enclosing feed, so it must neither drive the host (a `conn-fetch` or
`conn-send` on this node mid-turn is refused loud by the C tier's callback
latch, and the refusal breaks the method's own answer — the smoke pins this)
nor park the thread on something only another green thread can provide (Racket
CS may run the trampoline in atomic mode, where a blocking
`async-channel-get`-style wait deadlocks the place). Return a value, `bcom`, or
a forward; hand longer work to another thread and settle it through an
eventual-send.

## The internal FFI split

The raw `ffi/unsafe` layer is never required by a consumer; it follows Racket's
`private/` convention and mirrors the C ABI's own module split:

- [`private/ffi-shared.rkt`](private/ffi-shared.rkt): the shared frame,
  allocator, reference, argument, and event cstructs the archives agree on by
  layout. It opens no library, the Racket mirror of the C ABI's `c_abi/shared`
  leaf.
- [`private/ffi-ocapn.rkt`](private/ffi-ocapn.rkt): opens `libpancake_ocapn` and
  binds the library-level `pancake_*` family the binding consumes: version,
  last error, the managed-frame release, the locator URI grammar, and the
  exporter location-record encoder.
- [`private/ffi-driver.rkt`](private/ffi-driver.rkt): opens `libpancake_driver`
  and binds the byte-fed host's `pancake_host_*` family.
- [`private/ffi-tcp.rkt`](private/ffi-tcp.rkt): opens
  `libpancake_net_transport_tcp` and binds `pancake_tcp_*`.
- [`private/ffi-inproc.rkt`](private/ffi-inproc.rkt): opens
  `libpancake_net_transport_inproc` and binds `pancake_inproc_*`.
- [`private/ffi-iroh.rkt`](private/ffi-iroh.rkt): loads
  `libpancake_net_transport_iroh` lazily on first use, naming the build step
  (`zig build iroh-abi`, needs cargo) when it is absent.
- [`private/constants.rkt`](private/constants.rkt): the ABI constants,
  hand-mirrored from `pancake_ocapn.h` and `pancake_driver.h` and held to them
  by `zig build meta-check`.
- [`private/seam.rkt`](private/seam.rkt): the shared seam: the core machinery
  (`check-with`, `pin-immobile`, the frame cstructs, the connection construction
  verbs, and the argument codec) the transport companions and the actors
  companion build on. It re-provides `pancake.rkt`'s `seam` submodule, so none of
  it rides the public provide.

Each transport archive keeps its own thread-local last-error, read through that
archive's own reader (`tcp-last-error`, `inproc-last-error`), never the ocapn
family's `last-error`.

## The public surface, split by responsibility

`pancake.rkt` is a thin barrel: it requires the responsibility modules below and
re-provides their public surface unchanged, so `(require "pancake.rkt")` is one
import for a consumer. It also carries the `seam` submodule that re-provides the
binding-internal transport seam (`private/seam.rkt` re-provides it in turn).

- [`private/errors.rkt`](private/errors.rkt): the typed `exn:fail:pancake`, the
  per-thread last-error readers, and `check` / `check-with` / `raise-pancake`.
- [`private/value.rkt`](private/value.rkt): the reference, resolution, and event
  structs the surfaces exchange as native Racket values.
- [`private/codec.rkt`](private/codec.rkt): the native-value argument codec
  (`arg->c` / `args->c` / `arg<-c` / `args<-c` / `ref->c` / `bytes<-c`).
- [`private/vat.rkt`](private/vat.rkt): the Goblins-shaped vat's local half
  ONLY — actor state, the queued turn loop, local vows, `bcom`, and
  time-travel (`spawn`, `$`, `<-`, `on`, `methods`). Everything wire-shaped is
  the host's: a connection installs the far half, so `<-` to a far reference
  stays location-transparent. The semantics this half mirrors are pinned by
  the smoke's actor section and the `bench-goblins` app parity: a raising
  handler's staged `bcom` never installs, a listener fires once, and local
  `<-` turns run FIFO at `drive`. One boundary is narrower than Goblins and
  deliberate: there is no cross-actor turn transactionality — an outer turn
  erroring after an inner `$`'s `bcom` leaves the inner swap installed, where
  Goblins would roll it back. Time-travel is accept-side (server) only today:
  `accept` takes `#:time-travel?`; `connect` and the iroh surface do not.
- [`private/trampoline.rkt`](private/trampoline.rkt): the bridge between vat
  actors and the host's wire hosting — the `PancakeHostBehavior` trampoline that
  reads an actor's current closure per call (so `bcom` and `vat-restore!` retarget
  wire delivers), the turn verbs, and reply marshalling.
- [`private/locator.rkt`](private/locator.rkt): the OCapN locator URI grammar
  (`parse-locator`, `format-peer-uri`, `tcp-locator`).
- [`private/async.rkt`](private/async.rkt): the transport layer: the
  `async-transport` closures (Racket TCP ports here, iroh injected by its
  companion) and the per-connection inbox. Framing is the core's: the pump
  hands the inbox to `pancake_host_conn_feed_bytes` and keeps only the
  unconsumed tail.
- [`private/host.rkt`](private/host.rkt): the `node` over the byte-fed host
  handle (pancake's `mycapn`): the reentrant host lock, the connection
  registry, node-wide giftables, gift-id entropy, and the iroh redeem posture.
- [`private/connection.rkt`](private/connection.rkt): the high-level connection
  surface: the `connection`/`server` structs, the pump (feed, action drain,
  outbound writes), the dial executor a DIAL action names, and the `conn-*`
  application verbs.

[`zig-smoke.rkt`](zig-smoke.rkt) is the consumer `zig build bindings` runs: it
drives real OCapN conversations through the connection surface — keyed
handshakes, pipelining, projections, proxies, a Cap'n Proto session through
`#:codec`, distributed GC observed on the wire through a sniffing relay — then
composes the host tier with each explicit
transport module to shuttle a counter call over the in-process and TCP
netlayers. Racket must be on `PATH` (provided by
[`../../.devcontainer/`](../../.devcontainer/)); the build step resolves the
shared libraries relative to `zig-out/`.

```sh
zig build bindings        # builds the pancake archives, runs every binding consumer
zig build racket-dogfood  # just the Racket consumer
```
