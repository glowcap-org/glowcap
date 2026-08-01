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

Rust sessions run on one Tokio current-thread `LocalSet` and are `!Send`. Keep a
session and its actors on that task.

## Features

| Feature | Adds | Default |
| --- | --- | --- |
| `tcp` | Blocking TCP netlayer handles. | yes |
| `inproc` | Blocking in-process netlayer handles. | yes |
| `async` | Tokio `Session`, `Host`, `connect`, and `listen`. | no |
| `iroh` | Encrypted iroh transport and `IrohServer`; implies `async`. | no |
| `webrtc` | Raw WebRTC endpoint readiness, signaling, and try-I/O ABI. | no |

The core value and locator types are always available. Transport features link
only their matching C archive.

iroh requires `zig build iroh-abi`. `connect` keeps the same signature with or
without the feature: a TCP locator ignores reachability, while an iroh locator
requires it. Without the feature, an iroh dial returns a rebuild hint.

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
