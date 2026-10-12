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
`Runtime::close` when you are done with it. The handshake budget is a
Runtime-wide setting: change it with `RuntimeConfig::with_handshake_timeout`.

An `iroh`, `noise-tcp`, `keyed-tcp`, `tcp`, or routed relay dial or listener
runs on the driver archive (`libglowcap_driver`, ADR-0112). The loop owns
socket or multiplexed readiness, handshake admission, pumping, and session
release. A quiescent `Host` supplied by the application transfers to that loop
before its first network operation. Byte-fed integrations install connectors.
Routed relay locators install the relay archive's provider into the same loop,
so there is one transport runtime.

`tcp::listen`, `tcp::keyed::listen`, and `tcp::noise::listen` return the same
`tcp::Server` surface. Its canonical `locator()` and `uri()` report what
partners dial. The sealed profile includes both the durable key and direct
address. `ListenerIdentity::Seed` preserves a keyed identity across restarts.
`ListenerIdentity::Host` shares an existing Host and its session directory.
`relay::keyed::listen` and `relay::noise::listen` return `relay::Server` over
the same loop-owned server lifecycle. Their locator carries the rendezvous
route instead of a direct socket address.

## Sessions and actors

A `Session` can fetch, publish, spawn, send, tell, and enliven. `send` returns a
`RemotePromise`, which can itself be the target of another send for promise
pipelining. `caretaker` creates a revocable forwarder. `attenuate` restricts a
reference to selected methods. Local sends, tells and proxy forwarding all run
through the Zig Host, which owns actor liveness and routing. Sends are admitted
when called, and awaiting observes their result. The Host supports promise
pipelining and projection for remote answers. Local answers must be awaited.
`RemotePromise::into_admitted` returns an immediate admission error before an
application publishes dependent state. An admitted promise still needs awaiting
to learn the remote result.
`Session::resolve` accepts either an object or a promise through the same opaque
reference. The Zig Host returns an independently owned object handle immediately
or observes the promise's settlement, so Rooms does not inspect reference
kinds. The wire-level `Session::listen` keeps its profile-specific promise
contract. A refused no-answer tell does not become an unrelated later call's
error. Cancelling the causal session may close
an admitted local call before its answer is projected.

`spawn_owned` gives an actor a shared Rust-owned local root: the last `Ref` clone
queues its release, independently of distributed GC. Remote exports keep their
own roots. Ordinary `spawn` requires explicit release.

Each transport module's `listen` and `Server::accept` provide the hosting side.
An accepted session delivers its partner's inbound only once you serve it:
publish whatever that session should answer, then call `session.serve()`,
spawning the returned future or awaiting it to observe the close. A session
held without serving parks its partner's first message. Actor behaviors are
ordinary Rust closures. A panic in a hosted closure breaks the answer instead
of unwinding through C.

A session can also run over a byte channel the application opened itself,
such as a WebSocket a page opened. `Session::accept_over` takes the accepting
half on a `Host`, and `Session::dial_over` takes the dialing half. Both work
over anything that reads and writes bytes. The keyed handshake has the same
time limit as a transport's own listen and dial.

Several sessions can share a `Host` through
`RuntimeConfig::providers([provider]).adopt_host(host)` and the listener's
`ListenerIdentity::Host(host)` option. The shared host carries one identity and
handles three-party introductions. Use
`send_redeeming` when you also need the direct exporter session returned as
`via`.

Inside a synchronous behavior, `current_session()` projects the session that
delivered the turn, including a redeemed exporter route. The returned
view can be retained for replies. Dropping it does not close the connection.
It returns `None` outside a callback or for an internal route without a Rust
session wrapper. Local eventual calls can carry a session too, so this context
does not mean the caller is remote.

`Host::application_state` shares one typed Rust application value across all
handles of a Host. It keeps application data alive through handle churn, so
applications can enforce one ledger across their directory owners. It adds no
protocol state or lifecycle hook. Stored data must not own that Host or its
sessions, since those owners would form a reference cycle. Initializers run
without a table borrow. Recursive initialization of the same type returns an
error, and an unwinding initializer leaves that type available for retry.
`same_host` compares the shared owner, independently of durable-key equality.

`Host::publish_durable` draws fresh entropy. Applications that retain a durable
registry use `Host::publish_durable_with_entropy` to restore a publication from
its original entropy. The Host derives the name and refuses collisions with live
publications. The application owns stored identity, revocation records, and
restoring the same authority. Removing a publication releases its name, so never
reassign retained entropy to different authority. Publication factories run once
and may move owned state into their behavior.

`Host::defer_turn` returns the sole resolver for a deferred reply. Dropping it
before settlement schedules a broken answer through the Host's progress loop,
including when it is dropped inside a behavior. The caller therefore never waits
for an answer whose owner is gone. Cleanup also succeeds if session shutdown
already retired that answer. Explicit fulfillment and break calls refuse an
already-consumed resolver. `Resolver::fulfill_value` can return owning-thread
capabilities through the original caller session, using ordinary handoff staging
for foreign authority. Failed preparation leaves the resolver available for
retry. `fulfill` is the capability-free data path.

`Session::closed().await` observes terminal retirement without requesting close
or taking the serve task. Multiple observers and observers arriving after
retirement receive the same terminal result. Cancelling an observer leaves the
connection running.

`Host::enliven_for_version` and `Host::fetch_at` can initiate a Runtime's first
network operation. They reuse the Host's session selection and return owned
capability occurrences, including cache hits. Each occurrence uses one shared
release guard. Final drop releases its application retain even without a Session
GC opt-in. Explicit capability release is also available and disarms that guard.

`Host::reference_session` retains an owned handle to a capability's live exporter.
`Session::relinquish` consumes that handle and observes close only when it is the
last owner of an application-owned connection. A dial the Host adopted stays
live independently of application handles. `Session::borrowed` produces a view
that does not keep the connection open, so one feature can retire its views
without closing a connection another feature or the Host still owns.
`Session::close` closes the named connection regardless of other handles.

The driver owns bounded listener admission. `tcp::ListenOptions` selects the
Host identity and the dialable `advertised_host` required for a wildcard bind. A
bind address is not a reachable route, so a wildcard is never accepted as a
signed Host route.

Rust sessions run on one Tokio current-thread `LocalSet` and are `!Send`. Keep a
session and its actors on that task.

## Browser and Wasm

The base binding supports `wasm32-unknown-unknown` with default features
disabled. Build its archives and generated layout expectations with
`zig build gen-rust-wasm-layouts`. `GLOWCAP_LIB_DIR` selects the Wasm archive
directory when consuming outside the checkout. The generated constants come
from the compiled Zig Wasm descriptor, and compile-time layout assertions and
runtime archive fingerprint checks stay enabled. The Rooms Node/Chromium
proof exercises Context allocation, typed locators and sturdyref conversion.
With `async`, the same Host, Session, reference and vow machinery runs on a
Tokio `LocalSet` polled by a browser executor. Driver providers and socket
features are excluded from this target. Use `RuntimeConfig::connectors` and
`Session::dial_over` / `accept_over` for embedder-owned byte channels. Browser
entropy comes from Web Crypto. Browser timers are cancelled when their futures
are dropped. Host and Session close use one monotonic clock domain. Default Wasm
contexts route Host allocations through Rust's global allocator.

`zig build rooms-rust-browser-host-test` exercises this boundary in Node and
Chromium, including the real Rooms directory client, callback capabilities,
large payloads, finite close and silent-partner refusal in both directions.
`Channel::stream` carries stream I/O. `Channel::packets` transfers message
ownership and an explicit `ChannelClose` barrier. The core selects
framing through `feed_packet` / `take_packet`. Rust preserves received message
boundaries and borrows outgoing managed frames through the write. Accepted
channels carry provider-authored address/key interpretation and optional
verified-channel proof. This pump dispatches on no concrete transport.

An admitted channel's close belongs to the Host task barrier. Session release,
`closed()` and the first `serve()` observation wait for resource retirement,
even if an earlier close observer is cancelled. Physical-close refusal reaches
both Session and Host shutdown observers without failing unrelated sessions
or their next operation. `serve()` also reports a previously retained
outbound failure instead of clean EOF. Admission and handshake
refusals close the transferred channel before returning their error.
Cancelling an unfinished handshake abandons its channel. Host shutdown also
interrupts handshakes waiting for a transport to open. Established sessions
retain their terminal-frame drain before physical retirement.
The `browser` feature supplies `browser::open_websocket`, `websocket`, and
`data_channel`. WebSocket reads transfer owned chunks. Incremental writes use
`Channel::byte_chunks` to keep the send buffer within its waterline. Reliable,
ordered RTCDataChannels preserve bounded messages and use their drain event.
Both adapters bound queued bytes and message count before copying an incoming
ArrayBuffer into Wasm. That single incoming copy crosses the platform boundary.
Outgoing sends borrow the managed frame through a synchronous browser call.
Their close barriers retain failure, wait for the browser close event or the
shared deadline, then unregister callbacks.

`browser::relay::connector()` composes keyed-relay and noise-relay from their
locator-carried rendezvous hints. `dial_url` validates and renders the route
without opening a socket. `accept` holds one registration for the supplied
Host identity, then accepts a paired caller within its finite budget. The
application owns seat replenishment and advertised reachability. The relay
supplies no key proof. The linked Host runs Noise for the sealed profile.

`browser::RtcPeer` owns the peer connection, one reliable ordered `ocapn` data
channel, and bounded SDP/ICE work. Supply the ICE configuration and carry its
signaling through an application-authenticated route. The browser checks the
SDP fingerprint during DTLS. The application must authenticate the association
between that SDP and the expected key before supplying Session identity proof.
`into_channel` joins admitted signaling work and transfers the entire close
barrier. An established data channel finishes closing before its parent peer
connection closes. The Host's task keeps owning that preparation, including
complete SDP transitions whose observers are dropped. Browser events record
state and wake that existing task, and spawn no Tokio work from a DOM
callback. Host shutdown cancels browser promise observations and waits for
their callbacks to retire, even when the browser leaves the original WebRTC
operation unsettled.

The Chromium scenario reaches the installed `rooms-web` directory over
a real WebSocket, opens two distinct rooms, and exchanges calls between two
Rust Hosts over local RTCDataChannels. It also checks cross-origin relay refusal
and callback retirement. Rust also creates and signals its own local RTC pair.
The proof checks dropped SDP observers, shutdown while ICE waits for SDP,
shutdown during createOffer, failure callbacks outside Tokio polling for both
roles, and parent/channel close ordering. The Rooms browser adapter also
exercises directory-carried signaling in both directions. Browser storage,
production page integration, transport pressure, and deadline expiry are not
covered. See the [Rooms build setup](../../apps/rooms/rust/README.md) for the required
Wasm tools.

## Features

| Feature | Adds | Default |
| --- | --- | --- |
| `tcp` | Blocking TCP netlayer handles. | yes |
| `inproc` | Blocking in-process netlayer handles. | yes |
| `onion` | Tor provider and raw netlayer handles through a Tor daemon you run. With `async`, also adds `onion::Server` and Session dial/listen helpers. | no |
| `async` | Tokio `Session`, `Host`, and managed `Runtime`. | no |
| `iroh` | Encrypted iroh transport and `iroh::Server`. It implies `async`. | no |
| `relay` | `keyed-relay`/`noise-relay` provider package and managed listeners. It implies `async`. | no |
| `webrtc` | Raw WebRTC multiplexed readiness, signaling, and try-I/O ABI. | no |

The core value and locator types are always available, including
`tcp::locator`, `tcp::keyed::locator`, `tcp::noise::locator`, and
`tcp::address_designator`. Constructing a TCP locator does not enable socket
I/O. Async builds link the
symbol-disjoint `libglowcap_host` and `libglowcap_driver` archives: the driver
exports only `glowcap_driver_*`, adopts the Host through
`glowcap_driver_take_host`, and starts with zero providers. The `tcp` feature
supplies the complete `tcp`/`keyed-tcp`/`noise-tcp` provider package from
`libglowcap_net_transport_tcp`. The loop tier installs it through the common
provider ABI. Blocking TCP handles remain available through that same feature.

`onion` needs a running Tor daemon. glowcap does not start, supervise, or
configure one, so `Config` names where an existing daemon listens. With
`async,onion`, `onion::listen` and `onion::connect` compose that provider into
the generic driver and yield ordinary Sessions. `onion::Netlayer` remains the
raw frame surface. The Rust binding check (`zig build rust-dogfood`) uses a
fake daemon and does not test live Tor.
Repository-level on-demand checks cross Tor with two glowcap peers, Goblins
in both directions, upstream conformance, service restoration, and Rooms. They
require Tor and outbound network access.

iroh requires `zig build iroh-abi`. Construct a `Runtime` with an iroh provider
and use its `connect` method. A TCP-only build links no iroh provider.

Each transport module's `Server::close()` stops listener admission and
preserves sessions already returned by `accept`.
`server.host().close(PendingWork::Cancel).await` is the terminal
barrier that releases those sessions, joins the driver loop, and releases the
endpoint. A directly owned `Stream` has its own `close().await` barrier.

The wire codec belongs to the host. `Host::with_codec(Codec::Capnp)?` creates
a host whose sessions negotiate Cap'n Proto. The default is Syrup. Host
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
policy. The crate's ordinary unit tests do not cover it.

For the shared API, read the [binding overview](../README.md). Maintainers of
the C pump and generated FFI should read
[Developing a binding](../DEVELOPING.md).

## Persistent resources

Enable the optional `loam` feature for `loam::{Store, Attachment, Content, Policy}`.
It links the portable Loam archive and the LMDB companion and reuses `Host`,
`Ref` and Session. Opening, creation and privileged restoration are blocking
startup operations. Host progress runs on a Tokio `LocalSet`. Submitted storage
runs on the blocking executor. Contexts survive until detach succeeds, and a
cancelled observer retains its work until physical retirement. Host close
retires quiescent attachments. Close the Store after its borrows finish.

The [lifecycle guide](../../docs/loam/c-and-rust.md) describes
create/share/edit/restart/reopen, receipt calls and indeterminate creation
recovery. `Resource::encode` is trusted local metadata, not an invokable
capability. Browser storage and wider graph/owner projections are outside this
profile. `zig build loam-rust-test` exercises the complete consumer lifecycle,
ownership and Clippy, including a Loam-only feature build.
