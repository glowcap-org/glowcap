# bindings/rust

This crate is a Rust consumer of the pancake C ABI archives, composed à la
carte. It mirrors pancake's symbol-disjoint archive set (ADR-0059) as composable
modules behind Cargo features, so a build links exactly the archives its
features turn on. The core value and locator vocabulary always links
`libpancake_ocapn`. The byte-fed host tier always links `libpancake_driver`
(ADR-0072). Each transport feature links its own companion archive and compiles
its module through [`build.rs`](build.rs). See [`../README.md`](../README.md)
for the shipped C ABI surface, the embedder contract this crate implements, and
how the bindings are gated.

## Feature matrix

| Feature  | Module                                     | Archive linked                            | Default |
| -------- | ------------------------------------------ | ----------------------------------------- | ------- |
| (always) | crate root + `Locator`                     | `libpancake_ocapn` + `libpancake_driver`  | yes     |
| `tcp`    | [`tcp`](src/tcp.rs)                        | `libpancake_net_transport_tcp`            | yes     |
| `inproc` | [`inproc`](src/inproc.rs)                  | `libpancake_net_transport_inproc`         | yes     |
| `iroh`   | [`iroh`](src/iroh.rs)                      | `libpancake_net_transport_iroh` (dynamic) | no      |
| `async`  | `Session`, `Host`, `connect`/`listen`   | none: native tokio                        | no      |

`tcp` and `inproc` are on by default, so a plain `cargo build` (and
`zig build rust-dogfood`) links the same set the binding check always has. The core is
usable standalone: `cargo build --no-default-features` links only the core
archives and compiles no transport FFI. A single transport composes on top of
it: `cargo build --no-default-features --features tcp` links the core plus the
TCP archive and nothing else. The transport modules build on the core (they
share its `Context` and type layout) but never on each other.

`iroh` is opt-in and implies `async` (the tokio driver it rides). It needs the
companion library built by `zig build iroh-abi`. The `async` feature adds the
tokio-driven `Session` over native sockets and links no transport archive of
its own, so it composes with whichever transport archives are enabled. The
example clients enable it with `default-features = false`, paying for the core
archives plus their tokio driver and no blocking transport archive at all.

## The API

[`src/lib.rs`](src/lib.rs) is the idiomatic Rust API over the C ABI. The raw FFI
lives in the private [`src/sys/`](src/sys) module, grouped per archive the way
the C ABI is. [`sys/ocapn.rs`](src/sys/ocapn.rs) is the always-linked core (its
constant mirror is [`src/abi_constants.rs`](src/abi_constants.rs)).
[`sys/driver.rs`](src/sys/driver.rs) is the byte-fed host archive; its
hand-mirrored `#[repr(C)]` `PancakeHostAction` is pinned by a `const`
size/offset assert block, so a mirror that drifts from its documented layout
fails the build. [`sys/tcp.rs`](src/sys/tcp.rs),
[`sys/inproc.rs`](src/sys/inproc.rs), and [`sys/iroh.rs`](src/sys/iroh.rs)
declare each transport's externs behind its feature. Nothing in `sys` escapes.
What you use is the application surface every pancake binding speaks: real Rust
enums for `Reference` and `Argument`, `Result` for fallible calls, and owned
values out of every await with no manual free. Argument lists read as plain
Rust values. Build them with `Into`
(`&[42.into(), "hi".into(), (&cap).into()]`) and read them back with the
`as_i64` / `as_str` / `as_bytes` / `as_list` accessors, so a call site never
spells out an enum variant.

The `async` feature carries that application surface. Round-trip shape (tcp;
site tabs add iroh). `connect` already starts the inbound loop; call
`Session::serve` only to await shutdown:

```rust
use pancake::{connect, tcp_locator, Argument};

let partner = tcp_locator("127.0.0.1", 9099);
let session = connect(&partner, None, None).await?;
let greeter = session.fetch("greeter").await?; // a capability, by name
match session
    .send(&greeter, "greet", &["world".into()])
    .await
{
    Ok(Argument::String(reply)) => println!("{reply}"),
    Ok(other) => println!("unexpected reply: {other:?}"),
    Err(reason) => eprintln!("the greeter refused: {reason:?}"),
}
session.close();
```

`connect(uri, reachability, host)` is the one dialer. `listen` and
`Server::accept` host. A `Session` fetches, publishes, spawns, sends, and tells.
`send` returns a `RemotePromise` that pipelines as the target of a later send
and projects with `index`/`untag`. `caretaker` and `attenuate` wrap any `Ref` in
a revocable or narrowed proxy. `Host::publish_giftable` publishes host-wide for
three-party handoffs, and `send_redeeming` answers one: it returns the reply
alongside `via`, the direct exporter connection that reply routes to, so a
reply capability can be hosted on the connection the redeemed capability
actually lives on. The host archive owns routing, redemption, and gift
origination. The crate implements the embedder contract: it pumps raw bytes
through `pancake_host_session_feed_bytes`, honors the host's action queue (dial,
flush, gift-id entropy, vow settlements), and hosts every actor closure through
one shared behavior trampoline. A panic in that trampoline settles the answer
broken instead of unwinding across the C frame. Everything runs on one tokio
current-thread `LocalSet`. The handles are `!Send` by construction.

A `Host` is minted per session by default and shared explicitly for the handoff
shapes: `connect(locator, reachability, Some(host))` and `listen_with_host` key
several sessions with one identity and gift registry. The wire codec is a Host
property. `Host::with_codec(Codec::Capnp)` mints a Host whose every session
negotiates Cap'n Proto, so both ends of a shared-Host dial always agree and
there is no per-call codec knob to conflict with it. `HostOptions` sets the
local-turn budget at mint time. `Host::set_session_limits` tunes selective
session limits after mint (ADR-0082).

The `tcp` and `inproc` modules are the blocking frame shuttles over their
archives. A `Netlayer` owns the I/O backend. `listen`/`connect` bind and dial.
An `Endpoint` reads and writes one whole CapTP frame at a time. Each routes its
diagnostics through its own archive's thread-local last-error
(`pancake_tcp_last_error`, `pancake_inproc_last_error`), never the ocapn
family's `last_error`. The host tier likewise reads `pancake_host_last_error`.

`connect(uri, reachability, host)` has one signature whether or not iroh is
compiled in. A `tcp` locator ignores the reachability (pass `None`). An `iroh`
locator requires it. Without the feature, an `iroh` locator fails with a rebuild
hint. A call site never changes when iroh is turned on. The dialer and
`Reachability` posture live in [`src/dial.rs`](src/dial.rs).
[`src/session.rs`](src/session.rs) owns `Session` verbs and mint/handshake. The
optional `iroh` feature links `libpancake_net_transport_iroh` and adds the
iroh-touching surface (`listen_iroh`, `IrohServer`; dial via `connect(locator, …)`)
in [`src/iroh.rs`](src/iroh.rs), which establishes connections through the same
byte-fed pump, so a tcp-only build references no iroh symbol. The iroh module
routes its diagnostics through `pancake_iroh_last_error`.

## Build checks

The crate is the binding check consumer `zig build rust-dogfood` runs, so the
ergonomic surface stays aligned with the real library.
`zig build rust-goblins-interop` drives the async surface
([`interop/goblins_interop/rust_client.rs`](../../interop/goblins_interop/rust_client.rs))
through the keyed handshake, `enliven` + dedup, and a call against a live
Goblins vat.

```sh
zig build rust-dogfood           # build the pancake archives, run this crate's smoke tests
zig build rust-goblins-interop   # live Goblins client-direction interop (needs racket + goblins)
```

The à-la-carte composition is checkable directly with cargo:

```sh
cargo build --no-default-features                 # core only, proves the core stands alone
cargo build --no-default-features --features tcp  # core + one transport
cargo build                                       # default: core + tcp + inproc
zig build iroh-abi && cargo build --features iroh # opt-in iroh companion links
```

The crate's unit tests run under `--features async` (that is what
`zig build rust-dogfood` drives), so the `iroh` module has no unit coverage of
its own. Its proof is the live example checks (`rust-iroh-handoff`,
`rust-iroh-loop`, `rust-iroh-redeem-posture`), which link the sidecar and run
real endpoints.
