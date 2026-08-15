# Rust binding

This crate is an in-tree consumer of pancake's C ABI. It is not published
(`publish = false`); use it from a pinned checkout after running `zig build`.

Enable the `async` feature for the application session API:

```rust
use pancake::{tcp, Argument, ConnectOptions, PendingWork, Runtime, RuntimeConfig};

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

`Runtime` retains the Host and transport provider for all of its sessions. Call
`Runtime::close` when the composition is no longer needed.
The handshake budget is a Runtime-wide setting; use
`RuntimeConfig::with_handshake_timeout` when the default is not appropriate.

A bounded `tcp`, `keyed-tcp`, `noise-tcp`, `iroh`, or routed relay dial or listener rides
the driver archive (`libpancake_driver`, ADR-0112). The loop owns socket
or multiplexed readiness, handshake admission, pumping, and session release. A
quiescent `Host` supplied by the application transfers to that same loop before
its first network operation. Byte-fed integrations install explicit connectors;
routed relay locators install the relay archive's
provider into the same loop rather than creating a second transport runtime.

`tcp::listen`, `tcp::keyed::listen`, and `tcp::noise::listen` return the same
`tcp::Server` surface. Its canonical `locator()` and `uri()` report what
partners dial; the sealed profile includes both the durable key and direct
address. `ListenerIdentity::Seed` preserves a keyed identity across restarts;
`ListenerIdentity::Host` shares an existing Host and its session directory.

## Sessions and actors

A `Session` can fetch, publish, spawn, send, tell, and enliven. `send` returns a
`RemotePromise`, which can itself be the target of another send for promise
pipelining. `caretaker` creates a revocable forwarder; `attenuate` restricts a
reference to selected methods.

Each transport module's `listen` and `Server::accept` provide the hosting side.
Actor behaviors are ordinary Rust closures. A panic in a hosted closure breaks
the answer instead of unwinding through C.

Several sessions can share a `Host` through
`RuntimeConfig::providers([provider]).adopt_host(host)` and the listener's
`ListenerIdentity::Host(host)` option. The shared host carries
one identity and handles three-party introductions. Use
`send_redeeming` when you also need the direct exporter session returned as
`via`.

The native driver owns bounded listener admission. `tcp::ListenOptions`
selects the Host identity and the dialable `advertised_host` required for a
wildcard bind. Bind policy is not reachability, so a wildcard is never accepted
as a signed Host route.

Rust sessions run on one Tokio current-thread `LocalSet` and are `!Send`. Keep a
session and its actors on that task.

## Features

| Feature | Adds | Default |
| --- | --- | --- |
| `tcp` | Blocking TCP netlayer handles. | yes |
| `inproc` | Blocking in-process netlayer handles. | yes |
| `onion` | Tor provider and raw netlayer handles through a Tor daemon you run; with `async`, also adds `onion::Server` and Session dial/listen helpers. | no |
| `async` | Tokio `Session`, `Host`, and managed `Runtime`. | no |
| `iroh` | Encrypted iroh transport and `iroh::Server`; implies `async`. | no |
| `relay` | Native `keyed-relay`/`noise-relay` provider package; implies `async`. | no |
| `webrtc` | Raw WebRTC multiplexed readiness, signaling, and try-I/O ABI. | no |

The core value and locator types are always available. Async builds link the
symbol-disjoint `libpancake_host` and `libpancake_driver` archives: the driver
exports only `pancake_driver_*`, adopts the Host through
`pancake_driver_take_host`, and starts with zero providers. The `tcp` feature
supplies the complete `tcp`/`keyed-tcp`/`noise-tcp` provider package from
`libpancake_net_transport_tcp`; the loop tier installs it through the common
provider ABI. Blocking TCP handles remain available through that same feature.

`onion` needs a running Tor daemon: pancake never starts, supervises, or
configures one, so `Config` names where an existing daemon listens.
With `async,onion`, `onion::listen` and `onion::connect` compose that provider
into the generic driver and yield ordinary Sessions; `onion::Netlayer` remains
the raw frame surface. Its
checks talk to a fake daemon, so nothing has yet crossed the Tor network.

iroh requires `zig build iroh-abi`. Construct a `Runtime` with an iroh provider
and use its `connect` method; a TCP-only build links no iroh provider.

Each transport module's `Server::close()` stops listener admission and
preserves sessions already returned by `accept`.
`server.host().close(PendingWork::Cancel).await` is the terminal
barrier that releases those sessions, joins the native loop, and releases the
endpoint. A directly owned `Stream` has its own `close().await` barrier.

The wire codec belongs to the host. `Host::with_codec(Codec::Capnp)?` creates
a host whose sessions negotiate Cap'n Proto; the default is Syrup. Host
construction and publication verbs return `Result`, including entropy,
allocation, lifecycle, and native refusal diagnostics.

## Checks

```sh
zig build rust-dogfood
zig build rust-goblins-interop

cargo build --no-default-features
cargo build --no-default-features --features tcp
cargo build --features async
```

The iroh path has live checks for handoff, many connections, and redemption
policy. It is not covered by the crate's ordinary unit tests.

For the shared API, read the [binding overview](../README.md). Maintainers of
the C pump and generated FFI should read
[Developing a binding](../DEVELOPING.md).
