# bindings/rust

A Rust consumer of the pancake C ABI archives, composed à la carte: the crate
mirrors pancake's symbol-disjoint archive set (ADR-0059) as composable modules
behind Cargo features, so a build links exactly the archives its features turn
on. The core OCapN peer always links `libpancake_ocapn`; each transport feature
links its own companion archive and compiles its module, through
[`build.rs`](build.rs). See [`../README.md`](../README.md) for the shipped C ABI
surface and how the bindings are gated.

## Feature matrix

| Feature  | Module                            | Archive linked                            | Default |
| -------- | --------------------------------- | ----------------------------------------- | ------- |
| (always) | crate root + `actors` + `Locator` | `libpancake_ocapn`                        | yes     |
| `tcp`    | [`tcp`](src/tcp.rs)               | `libpancake_net_transport_tcp`            | yes     |
| `inproc` | [`inproc`](src/inproc.rs)         | `libpancake_net_transport_inproc`         | yes     |
| `iroh`   | [`iroh`](src/iroh.rs)             | `libpancake_net_transport_iroh` (dynamic) | no      |
| `async`  | `Connection`, `AsyncConnection`   | none — native tokio                       | no      |

`tcp` and `inproc` are on by default, so a plain `cargo build` (and
`zig build rust-dogfood`) links the same set the dogfood always has. The core is
usable standalone: `cargo build --no-default-features` links only
`libpancake_ocapn` and compiles no transport FFI. A single transport composes on
top of it: `cargo build --no-default-features --features tcp` links the core
plus the TCP archive and nothing else. The transport modules build on the core
(they share its `Context` and type layout) but never on each other.

`iroh` is opt-in and implies `async` (the tokio driver it rides); it needs the
companion library built by `zig build iroh-abi`. The `async` feature adds the
tokio-driven `Connection` over native sockets and links no transport archive of
its own, so it composes with whichever transport archives are enabled, the
example clients enable it with `default-features = false`, paying for the core
archive plus their tokio driver and no blocking transport archive at all.

## The API

[`src/lib.rs`](src/lib.rs) is the idiomatic Rust API over the C ABI. The raw FFI
lives in the private [`src/sys/`](src/sys) module, grouped per archive the way
the C ABI is — [`sys/ocapn.rs`](src/sys/ocapn.rs) is the always-linked core (its
constant mirror is [`src/abi_constants.rs`](src/abi_constants.rs)), and
[`sys/tcp.rs`](src/sys/tcp.rs), [`sys/inproc.rs`](src/sys/inproc.rs), and
[`sys/iroh.rs`](src/sys/iroh.rs) declare each transport's externs behind its
feature. Nothing in it escapes: what you use is a `Peer` that releases itself on
drop, real Rust enums for `Reference`, `Argument`, and `Event`, `Result` for
fallible calls, and owned values out of `poll` with no manual free. Argument
lists read as plain Rust values — build them with `Into`
(`&[42.into(), "hi".into(), (&cap).into()]`) and read them back with the
`as_i64` / `as_str` / `as_bytes` / `as_reference` accessors — so a call site
never spells out an enum variant. [`src/actors.rs`](src/actors.rs) mirrors the
`Vat` local-or-far reference model in Rust shapes.

The `tcp` and `inproc` modules are the blocking frame shuttles over their
archives: a `Netlayer` owns the I/O backend, `listen`/`connect` bind and dial,
and an `Endpoint` reads and writes one whole CapTP frame at a time. Each routes
its diagnostics through its own archive's thread-local last-error
(`pancake_tcp_last_error`, `pancake_inproc_last_error`), never the ocapn
family's `last_error`.

The base crate is dependency-free and sync — the `Peer` is sans-I/O and drives
from any runtime. The `async` feature is purely additive: it brings in tokio and
exposes `connect` / `listen` plus an application-surface `Connection`, the same
nine verbs every binding speaks. `connect(uri, reachability)` is the one dialer,
with one signature whether or not iroh is compiled in — a `tcp` locator ignores
the reachability (pass `None`), an `iroh` locator requires it, and without the
feature an `iroh` locator fails with a rebuild hint — so a call site never
changes when iroh is turned on. The core driver
([`src/connection.rs`](src/connection.rs)) carries that dialer and the
`Reachability` posture; the optional `iroh` feature links
`libpancake_net_transport_iroh` and adds the iroh-touching surface
(`connect_iroh`, `listen_iroh`, `IrohServer`) in [`src/iroh.rs`](src/iroh.rs),
which mints connections through the same driver — so a tcp-only build references
no iroh symbol. The iroh module routes its diagnostics through
`pancake_iroh_last_error`.

## Gates

The crate is the dogfood consumer `zig build rust-dogfood` runs, so the
ergonomic surface stays aligned with the real library.
`zig build rust-goblins-interop` drives the async surface
([`examples/goblins_interop.rs`](examples/goblins_interop.rs)) through the keyed
handshake, bootstrap fetch, and a call against a live Goblins vat.

```sh
zig build rust-dogfood           # build the pancake archives, run this crate's smoke tests
zig build rust-goblins-interop   # live Goblins conversation (needs racket + goblins)
```

The à-la-carte composition is checkable directly with cargo:

```sh
cargo build --no-default-features                 # core only, proves the core stands alone
cargo build --no-default-features --features tcp  # core + one transport
cargo build                                       # default: core + tcp + inproc
zig build iroh-abi && cargo build --features iroh # opt-in iroh companion links
```
