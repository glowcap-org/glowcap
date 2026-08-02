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

The wire codec is chosen for a host. `connect` and `listen` accept `#:codec`;
the default is `'syrup`, and both peers must agree before using `'capnp`.
Goblins interop uses CapTP 1.0 over Syrup.

A `keyed-relay` locator names a peer that opens no socket and holds inbound
connections at a relay under its key. Call `set-host-rendezvous-url!` with the
mapping from designator to the relay's rendezvous WebSocket URL and `connect`
opens the bridge over `net/rfc6455`, loaded only when such a dial runs.

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
Local time travel is available only on accepted sessions through
`#:time-travel?`; dialing sessions and iroh do not expose it.

## Checks

```sh
zig build racket-dogfood
zig build racket-test
zig build racket-goblins-interop
```

[`zig-smoke.rkt`](zig-smoke.rkt) exercises handshakes, pipelining, projections,
proxies, Cap'n Proto, garbage collection, and both TCP and in-process
transports. Racket must be on `PATH`; the devcontainer includes it.

For the shared API, read the [binding overview](../README.md). Maintainers of
the private FFI and pump should read
[Developing a binding](../DEVELOPING.md).
