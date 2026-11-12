# glowcap for Racket

The `glowcap` package connects a Racket program to [OCapN](https://glowcap.org/protocol/) peers. It
calls their objects, hosts objects of its own, and passes references between peers, with glowcap's
C libraries doing the protocol work and Racket threads and ports carrying the program. The
[Racket guide](https://glowcap.org/bindings/racket/) walks through the round trip, listening, and
the Goblins-style actor API. Terms such as locator and sturdyref are defined in the
[glossary](https://github.com/glowcap-org/glowcap/blob/main/docs/capabilities.md#glossary).

## Install

```sh
raco pkg install glowcap
```

The package installs the `glowcap` collection. On first load it downloads the
C libraries of its version from its
[GitHub release](https://github.com/glowcap-org/glowcap/releases) and verifies
them against its checksum file. Automatic downloads need `curl`, GNU or BSD
`tar`, and `sha256sum` or `shasum` on `PATH`. Set `GLOWCAP_LIB_DIR` to an extracted C SDK's `lib/`
directory to use a local copy. In a checkout of the repository, run `zig build`
and `require` the modules from `bindings/racket/` by relative path instead.

## A first session

Start the [greeter server below](#run-the-greeter-server). This client
connects over encrypted Noise TCP to `127.0.0.1:9099`. Replace `peer-key` with
the server's public key, save this as `client.rkt`, and run `racket client.rkt`.

```racket
#lang racket/base

(require glowcap/glowcap
         glowcap/glowcap-tcp)

(define peer-key "<64 lowercase hex characters from the server>")
(define runtime (open-runtime #:providers (list (tcp-provider))))
(define session (runtime-connect runtime (noise-tcp-locator peer-key "127.0.0.1" 9099)))
(define greeter (session-fetch session "greeter"))
(printf "~a\n" (session-send session greeter 'greet "world"))
(session-close! session)
(runtime-close! runtime)
```

### Run the greeter server

Save this as `server.rkt` and run `racket server.rkt` in another terminal.
It prints an `ocapn://` URI. Copy its 64-character key into `peer-key` in the
client above. The server creates a fresh key each time it starts.

```racket
#lang racket/base

(require glowcap/glowcap
         glowcap/glowcap-tcp)

(define server (listen-noise-tcp "127.0.0.1" 9099))
(host-publish (server-host server) "greeter"
  (methods [(greet who) (format "Hello, ~a" who)]))
(printf "~a\n" (server-uri server))
(flush-output)
(let loop ()
  (define session (accept server))
  (dynamic-wind
    void
    (lambda () (session-serve session))
    (lambda () (session-close! session)))
  (loop))
```

`glowcap.rkt` provides sessions, hosts, values, locators, and the actor API.
Its actor vocabulary follows Racket and Goblins style: `spawn`, `$`, `<-`,
`on`, `bcom`, and `methods`.

- `host-publish-durable` publishes a behavior under a durable swiss number, the
  secret name a peer uses to fetch it later. The optional second argument is
  retained entropy, and the same bytes restore the same name on a Host
  reconstructed from the same seed.
- `session-wait-closed` waits for the session to end without closing it or
  starting `session-serve`. Breaking the waiting thread leaves the session
  running.

## Modules

| Module | Purpose |
| --- | --- |
| [`glowcap/glowcap`](https://github.com/glowcap-org/glowcap/blob/main/bindings/racket/glowcap.rkt) | Sessions, hosts, actors, locators, and values. |
| [`glowcap/glowcap-iroh`](https://github.com/glowcap-org/glowcap/blob/main/bindings/racket/glowcap-iroh.rkt) | Encrypted QUIC connections and `listen-iroh`. |
| [`glowcap/glowcap-webrtc`](https://github.com/glowcap-org/glowcap/blob/main/bindings/racket/glowcap-webrtc.rkt) | WebRTC dial and listen with signaling you supply. |
| [`glowcap/glowcap-onion`](https://github.com/glowcap-org/glowcap/blob/main/bindings/racket/glowcap-onion.rkt) | Tor connections through a daemon you run, with `listen-onion` and `connect-onion`. |
| [`glowcap/glowcap-relay`](https://github.com/glowcap-org/glowcap/blob/main/bindings/racket/glowcap-relay.rkt) | Keyed and Noise relay connections and listeners. |
| [`glowcap/glowcap-tcp`](https://github.com/glowcap-org/glowcap/blob/main/bindings/racket/glowcap-tcp.rkt) | Noise, keyed, and plain TCP connections and listeners. |
| [`glowcap/glowcap-inproc`](https://github.com/glowcap-org/glowcap/blob/main/bindings/racket/glowcap-inproc.rkt) | In-process connections. |

WebRTC needs signaling you supply with `make-webrtc-signaling`, to carry each
exchange's offer, answer, and candidates. `webrtc-provider` dials a `webrtc`
locator and `listen-webrtc` answers inbound offers. Each signaling procedure
takes the exchange id first. The calls that open a route also take a
`webrtc-target` naming the peer and the session that introduced it.

The wire codec is chosen for a host. `open-runtime` and every listener accept
`#:codec`. The default is `'syrup`, and both peers must agree before using
`'capnp`. Goblins interop uses CapTP 1.0 over Syrup.

A `keyed-relay` locator names a peer that opens no socket of its own. A relay
server holds its inbound connections under the peer's key. Install the provider with
`(relay-provider)`, or pass `(relay-connector)` when an application owns the
byte-fed Host. Only the relay value the application selected interprets a
`rendezvous-relay` hint. `runtime-connect` does not fall back to a WebSocket
when a provider is missing.

`listen-keyed-relay` and `listen-noise-relay` register the Host's durable key
and return the same server shape as the TCP listeners. `server-uri` renders the
relay route partners use, and `accept` yields ordinary sessions. They take the
TCP listeners' `#:seed`, `#:host`, `#:codec`, `#:captp-version`, and
`#:features` with the same meaning, plus `#:trust-pem` for the relay's
certificate. They also take `#:options`, with the refusal rule under
[The driver loop](#the-driver-loop).

## The driver loop

Every `runtime-connect` and `listen` that uses a transport provider runs on
glowcap's driver loop, one event loop in the C library that owns the sockets
and moves bytes for every accepted session. The binding parks one green thread
until the loop has work, then steps it.

- A bare `iroh`, `noise-tcp`, `keyed-tcp`, `tcp`, or routed relay dial creates
  one loop per connection. `listen` binds the loop's listener, and a dial that
  shares a loop-backed server's Host runs on that same loop.
- `(tcp-provider)` registers `noise-tcp` alone. Plain `tcp` and `keyed-tcp` send
  cleartext with no peer proof, so each is an explicit opt-in:
  `(make-tcp-config #:profiles (list TCP-PROFILE-TCP TCP-PROFILE-KEYED-TCP))`.
  A runtime without a locator's profile refuses the dial with
  `ERR-INVALID-ARGUMENT` and the transport-unavailable cause, so branch on
  `(route-failure-from-cause (exn:fail:glowcap-cause e))`. An empty list is
  refused with `ERR-INVALID-ARGUMENT` when the provider installs. The listen
  helpers register exactly their own profile and take `#:stream`.
- A supplied Host moves into the loop in one step, keeping its identity and
  capabilities.
- A byte-fed dial needs a connector registered on the Host. That connector is
  also the only byte-fed path a later handoff redeem can use.

`open-runtime` takes `#:seed`, `#:profile`, `#:codec`, `#:captp-version`,
`#:features`, and `#:local-turn-budget` to configure the Host it creates.
`#:adopt-host` transfers an existing Host into the Runtime instead and refuses
every one of those options, matching or not. `runtime-close!` then shuts down that Host
and waits for shutdown to finish.

`listen`, `listen-keyed-tcp`, and `listen-noise-tcp` return the same kind of
server. `server-locator` is its canonical locator, `server-uri` renders that
locator as text, and `server-port` returns the port the provider bound.

- Pass `#:seed` to keep a keyed identity across restarts, or `#:host` to have
  a supplied Host own the same loop. Passing both is refused.
- `#:codec`, `#:captp-version`, and `#:features` set the profile of a newly
  created Host. If you leave them out, a listener uses the supplied Host's
  profile, or otherwise the generated default. A value that conflicts with a
  supplied Host's profile is refused.
- `listen-iroh` and `listen-onion` take the same three keywords with the same
  rule.
- Every listener takes `#:options`, but only the TCP package defines any. The
  iroh, onion, and relay providers refuse anything but an empty value when the
  listener opens.

## Hosted behavior rules

A method you publish on a Host runs on the thread that steps the driver loop.
It must not call back into that same Host or block waiting for work that only
another green thread can perform, because that can deadlock Racket CS. Return a
value, `bcom`, or a forward. Hand longer work to another thread and settle it
through an eventual send (`<-`).

`runtime-host` and `session-host` return the Host behind a runtime or session.
It also runs actors with no session. `host-spawn` returns an owned
reference, `host-send` waits for the answer, and `host-tell` queues a
notification. `host-send-promise` returns the vow without waiting, and
`host-await` waits for it.

Inside a behavior, `host-spawn`, `host-tell`, and
`host-send-promise` join its turn. `host-send` and `host-await` wait for an
answer, so a behavior's call to either is refused before it queues anything.
A behavior that needs an answer defers its turn instead.

`(break-far-vows! (session-vat s) message)` breaks every vow still waiting on
the partner and keeps the session open. A session the driver loop owns refuses
it. `session-partner-abort` returns the `partner-abort` the partner sent
before ending the session, or `#f`, and stays readable after close.

`host-retain-reference` returns an independent occurrence of a held reference.
Releasing the source leaves that occurrence usable. `session-resolve` returns an
owned reference for a live object without wire traffic, or waits for a promise's
settled value. Retained and resolved references receive finalizer cleanup even
when Session GC is off. Use `host-release-reference!` or `session-release!` for
deterministic release.

For a deferred reply obtained with `host-defer-turn`, use `resolver-fulfill!`
or `resolver-break!` once the worker completes. A fulfilled value may contain
capabilities held by the Host. If the worker gives up, use
`resolver-abandon!`, which breaks a live answer and also succeeds when its
calling session has already retired the answer. Run these operations outside
the hosted callback. `host-defer-turn-if-answer` returns a resolver for calls
and `#f` for tells. A tell has no reply waiting on it, so the worker must keep
itself alive.

## Limits

An existing Goblins program needs glowcap's module names and Host wiring even
though the actor API uses the same words (`spawn`, `$`, `<-`).

- An inner actor state change is not rolled back when an outer actor later
  fails.
- Local time travel rewinds actor state to an earlier snapshot. It is
  available only on the TCP and onion listeners, through the listener's
  `#:time-travel?` policy. Dialing sessions, iroh, and the relay listeners do
  not expose it.
- `listen` and `listen-keyed-tcp` accept connections under the driver loop's
  limits.
- A wildcard bind requires `#:advertised-host`, the name or address partners
  dial.

## Learn more

- [Racket guide](https://glowcap.org/bindings/racket/): the round trip, listening, actors, and async.
- [Choosing a transport](https://glowcap.org/transports/choosing/), and the pages for
  [iroh](https://glowcap.org/transports/iroh/), [WebRTC](https://glowcap.org/transports/webrtc/),
  [Tor](https://glowcap.org/transports/onion/), and [relays](https://glowcap.org/relay/).
- [The API every binding shares](https://github.com/glowcap-org/glowcap/blob/main/bindings/README.md),
  and the [repository](https://github.com/glowcap-org/glowcap) for the C libraries and the other
  bindings.

glowcap is built with AI coding assistants. The maintainer directs the work and is answerable for
what lands, as [How glowcap is built](https://github.com/glowcap-org/glowcap/blob/main/PROVENANCE.md)
explains.
