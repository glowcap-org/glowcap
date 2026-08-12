# Rust binding

This crate is an in-tree consumer of pancake's C ABI. It is not published
(`publish = false`); use it from a pinned checkout after running `zig build`.

Enable the `async` feature for the application session API:

```rust
use pancake::{connect, tcp_locator, Argument};

let partner = tcp_locator("127.0.0.1", 9099);
let session = connect(&partner, None, None).await?;
let greeter = session.fetch("greeter").await?;

match session.send(&greeter, "greet", &["world".into()]).await {
    Ok(Argument::String(reply)) => println!("{reply}"),
    Ok(other) => println!("unexpected reply: {other:?}"),
    Err(reason) => eprintln!("the greeter refused: {reason:?}"),
}

session.close();
```

`connect` starts the inbound loop. Call `Session::serve` only when you want to
wait for shutdown.

A bounded `tcp`, `keyed-tcp`, `noise-tcp`, `iroh`, or routed relay dial or listener rides
the driver archive (`libpancake_driver`, ADR-0112). The loop owns socket
or multiplexed readiness, handshake admission, pumping, and session release. A
quiescent `Host` supplied by the application transfers to that same loop before
its first network operation. A bare relay locator may use the explicit
`rendezvous` WebSocket feature; routed relay locators install the relay archive's
provider into the same loop rather than creating a second transport runtime.

`listen_noise_tcp` binds the sealed server side and returns a
`NoiseTcpServer`; its `uri()` includes both the durable key and bound address.
Reuse its optional 32-byte seed to preserve that identity across restarts.

## Sessions and actors

A `Session` can fetch, publish, spawn, send, tell, and enliven. `send` returns a
`RemotePromise`, which can itself be the target of another send for promise
pipelining. `caretaker` creates a revocable forwarder; `attenuate` restricts a
reference to selected methods.

`listen` and `Server::accept` provide the hosting side. Actor behaviors are
ordinary Rust closures. A panic in a hosted closure breaks the answer instead
of unwinding through C.

Several sessions can share a `Host` through
`connect(locator, reachability, Some(host))` and `listen_with_host`. The shared
host carries one identity and handles three-party introductions. Use
`send_redeeming` when you also need the direct exporter session returned as
`via`.

The native driver owns bounded listener admission. `ListenOptions` carries
advertisement policy only: use the advertised listener variants, or set
`advertised_host`, for a wildcard bind. Bind policy is not reachability, so a
wildcard is never accepted as a signed Host route.

Rust sessions run on one Tokio current-thread `LocalSet` and are `!Send`. Keep a
session and its actors on that task.

## Features

| Feature | Adds | Default |
| --- | --- | --- |
| `tcp` | Blocking TCP netlayer handles. | yes |
| `inproc` | Blocking in-process netlayer handles. | yes |
| `onion` | Blocking Tor onion netlayer handles, through a Tor daemon you run. | no |
| `async` | Tokio `Session`, `Host`, `connect`, and `listen`. | no |
| `iroh` | Encrypted iroh transport and `IrohServer`; implies `async`. | no |
| `relay` | Native `keyed-relay`/`noise-relay` provider package; implies `async`. | no |
| `rendezvous` | WebSocket fallback for a bare relay locator; implies `async`. | no |
| `webrtc` | Raw WebRTC multiplexed readiness, signaling, and try-I/O ABI. | no |

The core value and locator types are always available. Async builds link the
symbol-disjoint `libpancake_host` and `libpancake_driver` archives: the driver
exports only `pancake_driver_*`, adopts the Host through
`pancake_driver_take_host`, and starts with zero providers. The `tcp` feature
supplies the complete `tcp`/`keyed-tcp`/`noise-tcp` provider package from
`libpancake_net_transport_tcp`; the loop tier installs it through the common
provider ABI. Blocking TCP handles remain available through that same feature.

`onion` needs a running Tor daemon: pancake never starts, supervises, or
configures one, so a `Netlayer` names where an existing daemon listens. Its
checks talk to a fake daemon, so nothing has yet crossed the Tor network.

iroh requires `zig build iroh-abi`. `connect` keeps the same signature with or
without the feature: a TCP locator ignores reachability, while an iroh locator
requires it. Without the feature, an iroh dial returns a rebuild hint.

`IrohServer::close()` stops listener admission and preserves sessions already
returned by `accept`. `server.host().close_async().await` is the terminal
barrier that releases those sessions, joins the native loop, and releases the
endpoint. A directly owned `IrohStream` has its own `close().await` barrier.

The wire codec belongs to the host. `Host::with_codec(Codec::Capnp)` creates a
host whose sessions negotiate Cap'n Proto; the default is Syrup.

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
