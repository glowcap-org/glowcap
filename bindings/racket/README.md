# Racket binding

This binding uses pancake's C ABI with Racket threads and ports. Pin a
checkout, run `zig build`, and use the modules from the tree.

```racket
(require "pancake.rkt"
         "pancake-tcp.rkt")

(define peer-key "<64 lowercase hex characters from the server>")
(define runtime (open-runtime #:providers (list (tcp-provider))))
(define session (runtime-connect runtime (noise-tcp-locator peer-key "127.0.0.1" 9099)))
(define greeter (session-fetch session "greeter"))
(printf "~a\n" (session-send session greeter 'greet "world"))
(session-close! session)
(runtime-close! runtime)
```

`pancake.rkt` provides sessions, hosts, native values, locators, and the actor
API. Its actor vocabulary follows Racket and Goblins style: `spawn`, `$`, `<-`,
`on`, `bcom`, and `methods`.

## Modules

| Module | Purpose |
| --- | --- |
| [`pancake.rkt`](pancake.rkt) | Sessions, hosts, actors, generic connection management, locators, and values. |
| [`pancake-iroh.rkt`](pancake-iroh.rkt) | Optional encrypted QUIC provider/connector and `listen-iroh`. |
| [`pancake-onion.rkt`](pancake-onion.rkt) | Tor-backed provider/connector, `listen-onion` / `connect-onion`, and raw onion netlayer handles. |
| [`pancake-relay.rkt`](pancake-relay.rkt) | Explicit `keyed-relay`/`noise-relay` providers, managed listeners, and keyed byte connector. |
| [`pancake-tcp.rkt`](pancake-tcp.rkt) | TCP locators, explicit provider/connector values, native listeners, and blocking netlayer handles. |
| [`pancake-inproc.rkt`](pancake-inproc.rkt) | Explicit in-process byte connector and blocking connections. |

The wire codec is chosen for a host. `open-runtime` and `listen` accept
`#:codec`; the default is `'syrup`, and both peers must agree before using
`'capnp`. Goblins interop uses CapTP 1.0 over Syrup.

A `keyed-relay` locator names a peer that opens no socket and holds inbound
connections at a relay under its key. Install the native provider explicitly
with `(relay-provider)`, or pass `(relay-connector)` when an application owns
the byte-fed Host. A `rendezvous-relay` hint is interpreted only by the relay
value selected by the application; `runtime-connect` never falls back from a
missing provider to a WebSocket.

`listen-keyed-relay` and `listen-noise-relay` register the Host's durable key
and return the same server shape as the TCP listeners. `server-uri` renders the
relay route partners use, and `accept` yields ordinary sessions.

## The native loop

Every provider-backed `runtime-connect` and `listen` ride the native loop posture:
`libpancake_host` supplies the Host and `libpancake_driver` supplies only the
loop family. The driver adopts the Host through `pancake_driver_take_host`,
starts with zero providers, and receives the TCP package from
`libpancake_net_transport_tcp` through the common provider ABI. The library owns
the socket, the readiness set, and every accepted session's pumping, and the
binding parks one green thread on the loop's readiness descriptor and steps. A
bare `iroh`, `noise-tcp`, `keyed-tcp`, `tcp`, or routed relay dial
mints one loop per connection, `listen` binds the loop's listener, and a dial
sharing a loop-backed server's host stages on that same loop. A supplied Host
is transferred into that loop transactionally, preserving its identity and
authority. A byte-fed dial requires a connector explicitly registered on the
Host; that connector is also the only byte-fed realization available to a
later handoff redeem.

`open-runtime` accepts `#:adopt-host` when an existing Host should transfer
into the Runtime. `runtime-close!` is then that Host's terminal shutdown
barrier.

`listen`, `listen-keyed-tcp`, and `listen-noise-tcp` return the same server
surface. `server-locator` is its canonical metadata, `server-uri` renders that
locator, and `server-port` extracts the provider's bound port. Pass `#:seed` to
preserve keyed identity across restarts, or `#:host` to have a supplied Host
own the same native loop.

## Hosted behavior rules

A hosted method runs on the pumping thread inside the current feed. It must not
drive that same host again or block waiting for work that only another green
thread can perform. Doing so can deadlock Racket CS while the callback is
atomic.

Return a value, `bcom`, or a forward. Hand longer work to another thread and
settle it through an eventual send.

## Current semantic limits

The actor API uses Goblins-shaped vocabulary (`spawn`, `$`, `<-`). An existing
Goblins program still needs pancake's module names and Host wiring.

An inner actor state change is not rolled back when an outer actor later fails.
Local time travel is available only on TCP listeners through the listener's
`#:time-travel?` policy; dialing sessions and iroh do not expose it. `listen`
and `listen-keyed-tcp` use the driver's admission policy. A wildcard bind requires
`#:advertised-host`, the Host route partners dial.

## Checks

```sh
zig build racket-dogfood
zig build racket-test
zig build racket-goblins-interop
```

[`zig-smoke.rkt`](zig-smoke.rkt) is the thin aggregate for independently
loadable scenario families under `test/zig-smoke/`; the package omits that test
tree. Together they exercise handshakes, pipelining, projections, proxies,
Cap'n Proto, garbage collection, and the TCP, in-process, and onion transports.
Racket must be on `PATH`; the devcontainer includes it. The onion section needs
no Tor: [`zig-smoke-fake-tor.rkt`](zig-smoke-fake-tor.rkt) answers the requests
the transport sends, and it runs as a child process because a blocking foreign
call stops every Racket thread in the place until it returns.

For the shared API, read the [binding overview](../README.md). Maintainers of
the private FFI and pump should read
[Developing a binding](../DEVELOPING.md).
