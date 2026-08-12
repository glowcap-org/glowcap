# Racket binding

This binding uses pancake's C ABI with Racket threads and ports. It is not
published yet; use the modules from a pinned checkout after running
`zig build`.

```racket
(require "pancake.rkt")

(define sess (connect (tcp-locator "127.0.0.1" 9099)))
(define greeter (session-fetch sess "greeter"))
(session-send sess greeter 'greet "world")
(session-close! sess)
```

`pancake.rkt` provides sessions, hosts, native values, locators, and the actor
API. Its actor vocabulary follows Racket and Goblins style: `spawn`, `$`, `<-`,
`on`, `bcom`, and `methods`.

## Modules

| Module | Purpose |
| --- | --- |
| [`pancake.rkt`](pancake.rkt) | Sessions, hosting, actors, TCP connection management, and values. |
| [`pancake-tcp.rkt`](pancake-tcp.rkt) | Blocking TCP netlayer handles. |
| [`pancake-inproc.rkt`](pancake-inproc.rkt) | Blocking in-process connections. |
| [`pancake-iroh.rkt`](pancake-iroh.rkt) | Optional encrypted QUIC and `listen-iroh`. |
| [`pancake-relay.rkt`](pancake-relay.rkt) | Native `keyed-relay`/`noise-relay` provider composition. |

The wire codec is chosen for a host. `connect` and `listen` accept `#:codec`;
the default is `'syrup`, and both peers must agree before using `'capnp`.
Goblins interop uses CapTP 1.0 over Syrup.

A `keyed-relay` locator names a peer that opens no socket and holds inbound
connections at a relay under its key. A locator carrying a
`rendezvous-relay` hint installs the native relay provider into the driver
loop. A bare locator can instead use `set-host-rendezvous-url!`; that explicit
fallback opens a byte channel over `net/rfc6455`, loaded only when such a dial
runs.

## The native loop

Every native-provider `connect` and `listen` ride the native loop posture:
`libpancake_host` supplies the Host and `libpancake_driver` supplies only the
loop family. The driver adopts the Host through `pancake_driver_take_host`,
starts with zero providers, and receives the TCP package from
`libpancake_net_transport_tcp` through the common provider ABI. The library owns
the socket, the readiness set, and every accepted session's pumping, and the
binding parks one green thread on the loop's readiness descriptor and steps. A
bare `tcp`, `keyed-tcp`, `noise-tcp`, iroh, or routed relay dial
mints one loop per connection, `listen` binds the loop's listener, and a dial
sharing a loop-backed server's host stages on that same loop. A supplied Host
is transferred into that loop transactionally, preserving its identity and
authority. The byte-fed pump remains available for a bare relay locator's
explicit Host rendezvous fallback.

`listen-keyed-tcp` and `listen-noise-tcp` bind native-loop servers. Their URI
accessors carry the durable key designator and direct address; pass `#:seed` to
preserve the key across restarts. Pass `#:host` to have a supplied Host own the
same native loop.

## Hosted behavior rules

A hosted method runs on the pumping thread inside the current feed. It must not
drive that same host again or block waiting for work that only another green
thread can perform. Doing so can deadlock Racket CS while the callback is
atomic.

Return a value, `bcom`, or a forward. Hand longer work to another thread and
settle it through an eventual send.

## Current semantic limits

The actor API resembles Goblins, but it is not a compatibility layer. An
existing Goblins program will not run unchanged.

An inner actor state change is not rolled back when an outer actor later fails.
Local time travel is available only on TCP listeners through the listener's
`#:time-travel?` policy; dialing sessions and iroh do not expose it. `listen`
and `listen-keyed-tcp` use the driver's admission policy. A wildcard bind requires
`#:advertised-host`, because the bound interface is not a dialable Host route.

## Checks

```sh
zig build racket-dogfood
zig build racket-test
zig build racket-goblins-interop
```

[`zig-smoke.rkt`](zig-smoke.rkt) exercises handshakes, pipelining, projections,
proxies, Cap'n Proto, garbage collection, and the TCP, in-process, and onion
transports. Racket must be on `PATH`; the devcontainer includes it. The onion
section needs no Tor: [`zig-smoke-fake-tor.rkt`](zig-smoke-fake-tor.rkt) answers
the requests the transport sends, and it runs as a child process because a
blocking foreign call stops every Racket thread in the place until it returns.

For the shared API, read the [binding overview](../README.md). Maintainers of
the private FFI and pump should read
[Developing a binding](../DEVELOPING.md).
