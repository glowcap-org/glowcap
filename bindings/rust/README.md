# Rust binding

This crate is an in-tree consumer of glowcap's C ABI (`publish = false`). Pin
a checkout, run `zig build`, and use it from the tree.

Enable the `async` feature for the application session API:

```rust
use glowcap::{tcp, Argument, ConnectOptions, PendingWork, Runtime, RuntimeConfig};

let peer_key = "<64 lowercase hex characters from the server>";
let partner = tcp::noise::locator(peer_key, "127.0.0.1", 9099);
let runtime = Runtime::open(RuntimeConfig::providers([tcp::provider(tcp::Config::default())])).await?;
let session = runtime.connect(&partner, ConnectOptions::default()).await?;
let greeter = session.fetch("greeter").await?;

match session.send(&greeter, "greet", &["world".into()]).await {
    Ok(Argument::String(reply)) => println!("{reply}"),
    Ok(other) => println!("unexpected reply: {other:?}"),
    Err(reason) => eprintln!("the greeter refused: {reason:?}"),
}

session.close(PendingWork::Cancel).await?;
runtime.close(PendingWork::Cancel).await?;
```

`Runtime` holds the Host and transport provider for all of its sessions. Call
`Runtime::close` when you are done with it. The handshake budget is
Runtime-wide: set it with `RuntimeConfig::with_handshake_timeout`.

An `iroh`, `noise-tcp`, `keyed-tcp`, `tcp`, or routed relay dial or listener
runs on the driver archive (`libglowcap_driver`, ADR-0112). Its loop waits on
the sockets, accepts handshakes, moves bytes, and releases finished sessions. A
`Host` the application supplies must be idle, and it moves to that loop before
its first network operation. A routed relay locator adds the relay provider to
the same loop. An integration that feeds bytes itself installs connectors
instead.

`tcp::listen`, `tcp::keyed::listen`, and `tcp::noise::listen` return the same
`tcp::Server`. Its `locator()` and `uri()` report what partners dial, and a
`noise-tcp` locator includes both the durable key and the direct address.

- `ListenerIdentity::Seed` preserves a keyed identity across restarts.
- `ListenerIdentity::Host` shares an existing Host and its session directory.
- `relay::keyed::listen` and `relay::noise::listen` return `relay::Server` over
  the same loop-owned lifecycle. Their locator carries the rendezvous route
  instead of a direct socket address.

`tcp::ListenOptions` selects the Host identity and the dialable
`advertised_host` that a wildcard bind requires, because a bind address is not
a reachable route.

Rust sessions are `!Send`. Run them on one Tokio current-thread `LocalSet` and
keep a session and its actors on that task.

## Sessions and actors

A `Session` can fetch, publish, spawn, send, tell, and enliven.

- `send` returns a `RemotePromise`, which can be the target of another send for
  promise pipelining. Pipelining and indexing into the result work for
  remote answers. Local answers must be awaited.
- A send is checked and queued when you call it, and awaiting it gives the
  result. `RemotePromise::into_admitted` reports a refused send at once, before
  the application publishes anything that depends on it.
- `caretaker` creates a revocable forwarder. `attenuate` restricts a reference
  to selected methods.
- Local sends, tells, and proxy forwarding run through the Zig Host, which tracks
  which actors are alive and routes messages.
- `Session::resolve` accepts an object or a promise through the same opaque
  reference, so callers need not inspect reference kinds. The wire-level
  `Session::listen` follows the promise rules of the CapTP version in use.
- A refused `tell` never shows up as the error of a later, unrelated call.
  Cancelling the session that started a local call may close that call before
  its answer arrives.

`spawn_owned` gives an actor a shared Rust-owned local root: the last `Ref` clone
queues its release, independently of distributed GC. Ordinary `spawn` requires
explicit release.

### Hosting sessions

Each transport module's `listen` and `Server::accept` provide the hosting side.
An accepted session delivers its partner's inbound only once you serve it:

1. Publish whatever that session should answer.
2. Call `session.serve()`, then spawn the returned future or await it to
   observe the close.

A session held without serving parks its partner's first message. Actor
behaviors are ordinary Rust closures, and a panic in one breaks the answer
instead of unwinding through C.

A session can also run over a byte channel the application opened itself, such
as a WebSocket a page opened. `Session::accept_over` takes the accepting half
on a `Host`, `Session::dial_over` takes the dialing half, and both work over
anything that reads and writes bytes. The keyed handshake has the same time
limit as a transport's own listen and dial.

### Sharing a Host

Several sessions can share a `Host` through
`RuntimeConfig::providers([provider]).adopt_host(host)` and the listener's
`ListenerIdentity::Host(host)` option. The shared host carries one identity and
handles three-party introductions. Use `send_redeeming` when you also need the
direct exporter session returned as `via`.

`Host::application_state` shares one typed Rust value across all handles of a
Host and adds no protocol state or lifecycle hook.

- Stored data must not own that Host or its sessions, since those owners would
  form a reference cycle.
- Recursive initialization of the same type returns an error, and an unwinding
  initializer leaves that type available for retry.
- `same_host` compares the shared owner, independently of durable-key equality.

### Inside a behavior

`current_session()` returns the session that delivered the current turn, including a
redeemed exporter route. Retain the view for replies. It returns `None` outside
a callback, and a local eventual call can carry a session too, so it does not
prove the caller is remote.

`Host::defer_turn` returns the sole resolver for a deferred reply.

- Dropping the resolver before settlement schedules a broken answer through the
  Host's progress loop, so the caller never waits for an answer whose owner is
  gone. Cleanup also succeeds if session shutdown already retired that answer.
- Explicit fulfillment and break calls refuse an already-consumed resolver.
- `Resolver::fulfill_value` can return owning-thread capabilities through the
  original caller session, preparing the usual handoff for capabilities
  hosted by other peers. Failed preparation leaves the resolver available for retry.
  `fulfill` is the capability-free data path.

### Durable names

`Host::publish_durable` draws fresh entropy. Applications that retain a durable
registry use `Host::publish_durable_with_entropy` to restore a publication from
its original entropy, and the Host refuses collisions with live publications.
The application owns stored identity, revocation records, and restoring the same
behavior under the same name. Removing a publication releases its name, so never
reuse retained entropy for a different behavior. Publication factories run once and may move
owned state into their behavior.

### Observing and releasing

`Session::closed().await` waits for the session to end without asking it to
close or taking over serving. Every waiter, including one that arrives after
the end, gets the same result. Cancelling an observer leaves the
connection running.

`Host::enliven_for_version` and `Host::fetch_at` can make a Runtime's first
network operation. Each returns its own reference, even on a cache hit.
Dropping the last copy releases the application's hold, even when the session
has not opted into GC. Releasing it explicitly also works, and then the drop
does nothing.

`Host::reference_session` retains an owned handle to a capability's live
exporter.

- `Session::relinquish` gives up that handle, and waits for the close only
  when it was the last owner of a connection the application opened. A dial the Host adopted
  stays live independently of application handles.
- `Session::borrowed` produces a view that does not keep the connection open,
  so one feature can retire its views without closing a connection another
  feature or the Host still owns.
- `Session::close` closes the named connection regardless of other handles.

## Browser and Wasm

The base binding supports `wasm32-unknown-unknown` with default features
disabled. Build its archives and generated layout expectations with
`zig build gen-rust-wasm-layouts`. `GLOWCAP_LIB_DIR` selects the Wasm archive
directory when consuming outside the checkout. Compile-time layout assertions
and runtime archive fingerprint checks stay enabled.

With `async`, the same Host, Session, reference, and vow machinery runs on a
Tokio `LocalSet` polled by a browser executor. Driver providers and socket
features are excluded from this target.

- Use `RuntimeConfig::connectors` and `Session::dial_over` / `accept_over` for
  byte channels the application owns.
- Browser entropy comes from Web Crypto.
- Browser timers are cancelled when their futures are dropped.
- Host and Session close use one monotonic clock domain.
- Default Wasm contexts route Host allocations through Rust's global allocator.

`zig build rooms-rust-browser-host-test` exercises this boundary in Node and
Chromium.

### Channels

`Channel::stream` carries a byte stream. `Channel::packets` carries whole
messages, handing each one over, and closes with an explicit `ChannelClose`.
The core frames packets through `feed_packet` and `take_packet`. Rust keeps
each received message whole and lends outgoing frames to the write instead of
copying them. An accepted channel carries the provider's reading of its
address and key, and can carry proof that the channel was verified. The pump
never depends on a particular transport.

Once the Host takes a channel, it closes as part of the Host's task:

- Session release, `closed()`, and the first `serve()` observation wait for
  resource retirement, even if an earlier close observer is cancelled.
- A physical-close refusal reaches both Session and Host shutdown observers
  without failing unrelated sessions or their next operation.
- `serve()` reports a previously retained outbound failure instead of clean
  EOF.
- A refused channel or handshake closes the transferred channel before
  returning its error. Cancelling an unfinished handshake abandons its
  channel.
- Host shutdown interrupts handshakes waiting for a transport to open.
  Established sessions retain their terminal-frame drain before physical
  retirement.

### Browser transports

The `browser` feature supplies `browser::open_websocket`, `websocket`, and
`data_channel`.

- WebSocket reads transfer owned chunks. Incremental writes use
  `Channel::byte_chunks` to keep the send buffer within its waterline.
- Reliable, ordered RTCDataChannels preserve bounded messages and use their
  drain event.
- Both adapters bound queued bytes and message count before copying an incoming
  ArrayBuffer into Wasm, the one incoming copy. Outgoing sends borrow the
  managed frame through a synchronous browser call.
- Their close barriers retain failure, wait for the browser close event or the
  shared deadline, then unregister callbacks.

`browser::relay::connector()` composes keyed-relay and noise-relay from their
locator-carried rendezvous hints. `dial_url` validates and renders the route
without opening a socket. `accept` holds one registration for the supplied Host
identity, then accepts a paired caller within its finite budget. The application
owns seat replenishment and advertised reachability. The relay supplies no key
proof, and the linked Host runs Noise for the sealed profile.

`browser::RtcPeer` owns the peer connection, one reliable ordered `ocapn` data
channel, and bounded SDP and ICE work. Supply the ICE configuration and carry its
signaling through an application-authenticated route. The browser checks the SDP
fingerprint during DTLS. The application must authenticate the association
between that SDP and the expected key before supplying Session identity proof.

- `into_channel` joins accepted signaling work and transfers the entire close
  barrier. An established data channel finishes closing before its parent peer
  connection closes.
- The Host's task keeps owning that preparation, including complete SDP
  transitions whose observers are dropped.
- Browser events record state and wake that task. They spawn no Tokio work from
  a DOM callback.
- Host shutdown cancels browser promise observations and waits for their
  callbacks to retire, even when the browser leaves the original WebRTC
  operation unfinished.

The Chromium scenario reaches the installed `rooms-web` directory over a real
WebSocket and exchanges calls between two Rust Hosts over local
RTCDataChannels. Rust also signals its own local RTC pair, covering dropped SDP
observers, shutdown during ICE and createOffer, failure callbacks outside Tokio
polling, and close ordering. Browser storage, production page integration,
transport pressure, and deadline expiry are not covered. The
[Rooms build setup](../../apps/rooms/rust/README.md) lists the required Wasm
tools.

## Features

| Feature | Adds | Default |
| --- | --- | --- |
| `tcp` | Blocking TCP netlayer handles. | yes |
| `inproc` | Blocking in-process netlayer handles. | yes |
| `onion` | Tor provider and raw netlayer handles through a Tor daemon you run. With `async`, also adds `onion::Server` and Session dial/listen helpers. | no |
| `async` | Tokio `Session`, `Host`, and managed `Runtime`. | no |
| `iroh` | Encrypted iroh transport and `iroh::Server`. It implies `async`. | no |
| `relay` | `keyed-relay`/`noise-relay` provider package and managed listeners. It implies `async`. | no |
| `webrtc` | WebRTC provider with application signaling, and the raw readiness and try-I/O ABI. It implies `async`. | no |

The core value and locator types are always available, including
`tcp::locator`, `tcp::keyed::locator`, `tcp::noise::locator`, and
`tcp::address_designator`. Constructing a TCP locator does not enable socket
I/O. The `tcp` feature supplies the `tcp`, `keyed-tcp`, and `noise-tcp` provider
package and the blocking TCP handles.

`onion` needs a running Tor daemon. glowcap does not start, supervise, or
configure one, so `Config` names where an existing daemon listens. With
`async,onion`, `onion::listen` and `onion::connect` compose that provider into
the generic driver and yield ordinary Sessions. `onion::Netlayer` remains the
raw frame handle.

`zig build rust-dogfood` uses a fake daemon and does not test live Tor.
Repository-level on-demand checks cross Tor with two glowcap peers, Goblins in
both directions, upstream conformance, service restoration, and Rooms. They
need Tor and outbound network access.

iroh requires `zig build iroh-abi`. Construct a `Runtime` with an iroh provider
and use its `connect` method. A TCP-only build links no iroh provider.

WebRTC requires `zig build webrtc-abi`. Implement `webrtc::SignalingAuthority`
to carry the offer, the answer, and each ICE candidate, build a `Runtime` with
`webrtc::provider(signaling, config)`, and connect to a `webrtc::locator`. Each
signaling call names its `webrtc::Target`: the dialed peer, and the session
that introduced it when the dial follows a handed-over reference.

To accept offers, `webrtc::listen(signaling, config, options)` returns a
`webrtc::Server`. Hand each inbound offer to its `provide_offer` with the
offerer's designator. The library answers through the signaling object's `answer`,
and `accept` yields the keyed session, which names the offerer. A listening
Host dials too: build a `Runtime` with no providers that adopts
`server.host()`. Drive
the `Runtime` from a tokio `LocalSet`, because the signaling callbacks run on the
thread that steps the loop. A dial whose answer never arrives fails at the
handshake deadline, and one whose signaling fails is given up at the driver's
next step.

Closing a server:

- `Server::close()` on each transport module stops the listener accepting new connections
  and preserves sessions already returned by `accept`.
- `server.host().close(PendingWork::Cancel).await` is the terminal barrier. It
  releases those sessions, joins the driver loop, and releases the endpoint.
- A directly owned `Stream` has its own `close().await` barrier.

The wire codec belongs to the host. `Host::with_codec(Codec::Capnp)?` creates a
host whose sessions negotiate Cap'n Proto. The default is Syrup. Host
construction and publication verbs return `Result`, including entropy,
allocation, lifecycle, and refusal diagnostics.

## Checks

```sh
zig build rust-dogfood
zig build rust-goblins-interop

cargo build --no-default-features
cargo build --no-default-features --features tcp
cargo build --features async
```

The iroh path has live checks for handoff, many connections, and redemption
policy. The crate's ordinary unit tests do not cover it. The WebRTC dial and listen have
`zig build rust-webrtc-driver-provider`, which dials the Zig answerer and
accepts the Zig offerer.

For the shared API, read the [binding overview](../README.md). Maintainers of
the C pump and generated FFI should read
[Developing a binding](../DEVELOPING.md).

## Persistent resources

Enable the optional `loam` feature for `loam::{Store, Attachment, Content, Policy}`.
On desktop and server targets, it links the portable Loam archive and the
SQLite, LMDB, and in-memory companions, reusing `Host`, `Ref`, and Session.

- Opening, creation, and privileged restoration are blocking startup
  operations.
- Host progress runs on a Tokio `LocalSet`. Storage work runs on the
  blocking executor.
- Contexts survive until detach succeeds, and a cancelled observer retains its
  work until physical retirement.
- Host close retires quiescent attachments. Close the Store after its borrows
  finish.

The [lifecycle guide](../../docs/loam/c-and-rust.md) describes create, share,
edit, restart, reopen, receipt calls, and indeterminate creation recovery.
`Resource::encode` is trusted local metadata, not an invokable capability.
The same feature uses [IndexedDB in the browser](../../docs/loam/browser.md)
when compiled for Wasm. The lifecycle guide covers graph and owner views.
`zig build loam-rust-test` exercises the consumer lifecycle, ownership, and
Clippy, including a Loam-only feature build.
