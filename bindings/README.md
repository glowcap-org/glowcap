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
handoff registry across several sessions.

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

The bindings also expose sturdyref enlivenment, promise pipelining,
attenuation, revocation, and opt-in distributed garbage collection. A `Ref` is
opaque. Pass it as an argument and the binding chooses the correct wire
reference; application code never manages import or export numbers.

## A call can introduce another peer

Three-party handoff is part of the ordinary call path. If a result names a
capability hosted by another peer, the host opens or reuses the required
connection and settles the call with the live capability.

`send_redeeming` (named according to each language's style) is for the less common case
where the caller also needs the direct exporter session for session-specific
operations or peer identity. The capability itself remains Host-scoped.

Promises can be call targets before they settle. A chain of dependent sends can
therefore cross the network in one round trip. Await the last promise when the
intermediate results are not otherwise needed.

## Closing sessions and hosts

Closing a session ends one connection. Closing a host ends every session it
owns, including connections it opened while redeeming handoffs.

An ordinary `connect(locator)` creates a private host, so closing that session
also cleans up its host. When several sessions share a host supplied by the
application, the application must close the host separately.

| Language | Host shutdown |
| --- | --- |
| Rust | `Host::close`; close intent is terminal for every clone, with native release deferred only until an active callback returns. |
| TypeScript | `host.release()` |
| Python | `host.release()` |
| Racket | `host-release!` |

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

Plain TCP and in-process connections are built with the core bindings. iroh is
optional because it links a Rust sidecar. A TCP-only program does not load it.
Rust, Python, and Racket expose WebRTC's optional native C companion as raw FFI,
including endpoint readiness and try-I/O. TypeScript instead uses the browser's
`RTCPeerConnection` and does not load that companion. Its browser package is the
only application-level WebRTC adapter; the native bindings do not yet wrap the
raw family into their shared `Host` API.

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
