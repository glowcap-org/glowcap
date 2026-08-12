# Language bindings

pancake has bindings for Rust, TypeScript, Python, and Racket. They are part of
this repository and are not published packages yet. Pin a checkout, run
`zig build`, and follow the README for your language.

| Language | Start here | Runtime |
| --- | --- | --- |
| Rust | [`rust/README.md`](rust/README.md) | Tokio for the async session API. |
| TypeScript | [`ts/README.md`](ts/README.md) | Deno, Bun, and browser WebAssembly. |
| Python | [`python/README.md`](python/README.md) | Python 3.11+ with `asyncio`. |
| Racket | [`racket/README.md`](racket/README.md) | Racket threads and ports. |

All four wrap the same C ABI and present the same application model. A
`Session` represents one CapTP partner. A `Host` shares one identity and
handoff registry across several sessions. A binding `Ref` (C
`PancakeReference`) is the host-scoped capability; Zig owning APIs name the
same row `driver.Capability`.

## Shared API

Names follow each language's conventions, but the operations are the same:

| Operation | Purpose |
| --- | --- |
| `connect(locator)` | Dial an `ocapn://` peer and return a session. |
| `listen(address)` | Accept partners and return one session per connection. |
| `session.listen(ref)` | Subscribe to the listen notification for a held far capability; 1.0 accepts far promises and live far objects, while pancake-next accepts only far promises. |
| `fetch(name)` | Fetch a capability published by the partner. |
| `publish(name, behavior)` | Make a local behavior fetchable by name. |
| `spawn(behavior)` | Create a local actor and return its capability. |
| `send(ref, verb, args)` | Call a capability and return a promise for its answer. |
| `tell(ref, verb, args)` | Send without asking for an answer. |
| `serve()` | Keep handling inbound calls until the session closes. |
| `close()` | Close the session. |

The native fronts (Rust, Python, Racket, and TypeScript on Deno) load the
symbol-disjoint `libpancake_host` and `libpancake_driver` archives. The Host
archive owns the application family; the driver owns sockets or multiplexed
readiness, handshake admission, pumping, and generic dial/listen/events. A new
driver loop starts with zero transports. The TCP archive supplies one provider
package for `tcp`, `keyed-tcp`, and `noise-tcp`; the optional iroh archive
supplies its provider package. Provider retain/release is the native transport
lifetime authority. An idle Host that is not yet pumping can move into the
loop before its first native network operation, so bindings do not keep a
second transport registry or admission path.

Wasm and runtimes that cannot drive native FFI keep the byte-fed Host, as do
explicitly embedder-supplied channels such as keyed-relay WebSockets. This is
an owned integration choice, not a fallback after native dispatch fails. A
listener close stops new admission and preserves sessions already returned to
the application. Binding a wildcard interface (`0.0.0.0` or `::`) requires an
explicit advertised host; a bind address selects local interfaces and is not
implicitly a dialable signed locator.

The bindings also expose sturdyref enlivenment, promise pipelining,
attenuation, revocation, and opt-in distributed garbage collection. A `Ref` is
opaque. Pass it as an argument and the binding chooses the correct wire
reference; application code never manages import or export numbers.

## A call can introduce another peer

Three-party handoff is part of the ordinary call path. If a result names a
capability hosted by another peer, the host opens or reuses the required
session and settles the call with the live capability.

`send_redeeming` (named according to each language's style) is for the less common case
where the caller also needs the direct exporter session for session-specific
operations or peer identity. The capability itself remains Host-scoped.

Promises can be call targets before they settle. A chain of dependent sends can
therefore cross the network in one round trip. Await the last promise when the
intermediate results are not otherwise needed.

## Closing sessions and hosts

Closing a session ends one connection. Closing a host first stops its listeners
from admitting new sessions, then ends every session it owns, including
connections it opened while redeeming handoffs.

An ordinary `connect(locator)` creates a private host, so closing that session
also cleans up its host. When several sessions share a host supplied by the
application, the application must close the host separately.

| Language | Host shutdown |
| --- | --- |
| Rust | `Host::close()` requests terminal close for every clone; `close_async().await` is the completion barrier for the native loop or Host-owned byte-channel tasks and native release. |
| TypeScript | `host.release()` requests close and retires callback registration immediately; `await host.releaseAsync()` waits for the native loop or Host-owned byte-channel work and native release. |
| Python | `host.release()` requests callback-safe close; `await host.release_async()` waits for in-flight Host-owned dial work before native release. |
| Racket | `host-release!` stops the native loop or byte-channel workers before releasing native state; callback-time release is parked until the turn returns. |

## Where the languages differ

- Rust sessions are `!Send`. Create and use them on one Tokio `LocalSet`.
- Rust's `tell` returns after queueing the delivery; the other bindings wait
  for that write to flush.
- Rust reports a session abort through the promises it breaks rather than an
  error returned by `serve()`.
- The cap is 1024 in TypeScript, Python, and Rust for outcomes no caller has
  awaited yet. After that, the oldest result is dropped and a late await fails.
  Racket waits at the call site and needs no queue.
- Racket keeps its native actor vocabulary: `spawn`, `$`, `<-`, `on`, `bcom`,
  and `methods`.
- Only TypeScript currently has a recurring check in which Goblins dials the
  binding as a server. All four bindings dial Goblins and exercise both
  application-facing handoff roles.

A `send` or `tell` to an actor spawned by the same session stays in process in
every binding.

## Transports

Plain TCP and in-process connections are built with the core bindings. iroh and
onion are optional archives (iroh links a Rust sidecar; onion needs a Tor you
run). A TCP-only program does not load them. Rust, Python, and Racket expose
WebRTC's optional native C companion as raw FFI, including multiplexed readiness
and try-I/O. TypeScript instead uses the browser's `RTCPeerConnection` and does
not load that companion. Its browser package is the only application-level
WebRTC adapter; the native bindings do not yet wrap the raw family into their
shared `Host` API.

TypeScript's raw onion transport runs through Deno's off-thread FFI. Bun's FFI
does not currently provide that execution contract, so onion operations refuse
there instead of blocking Bun's event loop behind a promise-shaped API.

Applications still call `connect(locator)`. The locator selects the transport;
there is no second dial API for iroh.

## Building and checking

```sh
zig build bindings
```

The complete binding check needs Cargo, Deno, Bun, Python, and Racket. The
devcontainer includes them. Focused build steps are listed in each language
README.

Binding maintainers should read [Developing a binding](DEVELOPING.md).
Packagers and release operators should read
[Finding and publishing the C archives](PACKAGING.md).
