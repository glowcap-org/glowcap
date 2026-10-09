# Racket binding

This binding uses glowcap's C ABI with Racket threads and ports. Pin a
checkout, run `zig build`, and use the modules from the tree.

```racket
(require "glowcap.rkt"
         "glowcap-tcp.rkt")

(define peer-key "<64 lowercase hex characters from the server>")
(define runtime (open-runtime #:providers (list (tcp-provider))))
(define session (runtime-connect runtime (noise-tcp-locator peer-key "127.0.0.1" 9099)))
(define greeter (session-fetch session "greeter"))
(printf "~a\n" (session-send session greeter 'greet "world"))
(session-close! session)
(runtime-close! runtime)
```

`glowcap.rkt` provides sessions, hosts, native values, locators, and the actor
API. Its actor vocabulary follows Racket and Goblins style: `spawn`, `$`, `<-`,
`on`, `bcom`, and `methods`. `host-publish-durable` mints a durable swiss name;
the optional second argument is retained entropy, and the same bytes restore
the same name on a Host reconstructed from the same seed.
`session-wait-closed` waits for retirement without requesting close or starting
`session-serve`; breaking the waiting thread leaves the session running.

## Modules

| Module | Purpose |
| --- | --- |
| [`glowcap.rkt`](glowcap.rkt) | Sessions, hosts, actors, generic connection management, locators, and values. |
| [`glowcap-iroh.rkt`](glowcap-iroh.rkt) | Optional encrypted QUIC provider/connector and `listen-iroh`. |
| [`glowcap-onion.rkt`](glowcap-onion.rkt) | Tor-backed provider/connector, `listen-onion` / `connect-onion`, and raw onion netlayer handles. |
| [`glowcap-relay.rkt`](glowcap-relay.rkt) | Explicit `keyed-relay`/`noise-relay` providers, managed listeners, and keyed byte connector. |
| [`glowcap-tcp.rkt`](glowcap-tcp.rkt) | TCP locators, explicit provider/connector values, native listeners, and blocking netlayer handles. |
| [`glowcap-inproc.rkt`](glowcap-inproc.rkt) | Explicit in-process byte connector and blocking connections. |

The wire codec is chosen for a host. `open-runtime` and every listener accept
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
relay route partners use, and `accept` yields ordinary sessions. They take the
TCP listeners' `#:seed`, `#:host`, `#:codec`, `#:captp-version`, and
`#:features` with the same meaning, plus `#:trust-pem` for the relay's
certificate. They also take `#:options`, but the relay package defines no
per-listen options, so any value other than an empty one is refused when the
listener opens rather than dropped.

## The native loop

Every `runtime-connect` and `listen` that uses a transport provider runs on
glowcap's native loop. `libglowcap_host` supplies the Host, and
`libglowcap_driver` supplies only the loop. The driver adopts the Host through
`glowcap_driver_take_host`, starts with no providers, and receives the TCP
package from `libglowcap_net_transport_tcp` through the common provider ABI.

- The library owns the socket, the readiness set, and the pumping of every
  accepted session. The binding parks one green thread on the loop's readiness
  descriptor and steps the loop.
- A bare `iroh`, `noise-tcp`, `keyed-tcp`, `tcp`, or routed relay dial creates
  one loop per connection. `listen` binds the loop's listener, and a dial that
  shares a loop-backed server's Host runs on that same loop.
- A supplied Host moves into the loop in one step, keeping its identity and
  authority.
- A byte-fed dial needs a connector registered on the Host explicitly. That
  connector is also the only byte-fed path a later handoff redeem can use.

`open-runtime` accepts `#:adopt-host` when an existing Host should transfer
into the Runtime. `runtime-close!` is then that Host's terminal shutdown
barrier.

`listen`, `listen-keyed-tcp`, and `listen-noise-tcp` return the same kind of
server. `server-locator` is its canonical locator, `server-uri` renders that
locator as text, and `server-port` returns the port the provider bound.

- Pass `#:seed` to keep a keyed identity across restarts, or `#:host` to have
  a supplied Host own the same native loop.
- `#:codec`, `#:captp-version`, and `#:features` set the profile of a newly
  created Host. If you leave them out, a listener uses the supplied Host's
  profile, or otherwise the generated default. A value that conflicts with a
  supplied Host's profile is refused, never silently replaced.
- `listen-iroh` and `listen-onion` take the same three keywords with the same
  rule.
- Every listener takes `#:options`, but only the TCP package defines any. The
  iroh, onion, and relay providers refuse anything but an empty value when the
  listener opens.

## Hosted behavior rules

A hosted method runs on the pumping thread inside the current feed. It must not
drive that same host again or block waiting for work that only another green
thread can perform. Doing so can deadlock Racket CS while the callback is
atomic.

Return a value, `bcom`, or a forward. Hand longer work to another thread and
settle it through an eventual send.

For a deferred reply obtained with `host-defer-turn`, use `resolver-fulfill!`
or `resolver-break!` once the worker completes. If the worker gives up, use
`resolver-abandon!`: it breaks a live answer and also succeeds when its calling
session has already retired the answer. Run these operations outside the
hosted callback.
`host-defer-turn-if-answer` returns a resolver for calls and `#f` for tells.
The worker must retain its own lifetime when a tell supplies no reply custody.

## Current semantic limits

The actor API uses Goblins-shaped vocabulary (`spawn`, `$`, `<-`). An existing
Goblins program still needs glowcap's module names and Host wiring.

An inner actor state change is not rolled back when an outer actor later fails.
Local time travel is available only on the TCP and onion listeners through the
listener's `#:time-travel?` policy; dialing sessions, iroh, and the relay
listeners do not expose it. `listen`
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
