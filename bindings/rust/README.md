# bindings/rust

A Rust consumer of the Zig `libpancake` C ABI, linked through `build.rs`. See
[`../README.md`](../README.md) for the shipped C ABI surface and how the
bindings are gated.

## The API

[`src/lib.rs`](src/lib.rs) is the idiomatic Rust API over the C ABI. The raw
FFI lives in a private `sys` module and nothing in it escapes: what you use
is a `Peer` that releases itself on drop, real Rust enums for `Reference`,
`Argument`, and `Event`, `Result` for fallible calls, and owned values out of
`poll` with no manual free. [`src/actors.rs`](src/actors.rs) mirrors the
`Vat` local-or-far reference model in Rust shapes.

The base crate is dependency-free and sync — the `Peer` is sans-I/O and
drives from any runtime. The `async` feature is purely additive: it brings in
tokio and exposes `connect` / `listen` plus an application-surface
`Connection`, the same nine verbs every binding speaks.

## Gates

The crate is the dogfood consumer `zig build rust-dogfood` runs, so the
ergonomic surface stays honest against the real library.
`zig build rust-goblins-interop` drives the async surface
([`examples/goblins_interop.rs`](examples/goblins_interop.rs)) through the
keyed handshake, bootstrap fetch, and a call against a live Goblins vat.

```sh
zig build rust-dogfood           # build libpancake, run this crate's smoke tests
zig build rust-goblins-interop   # live Goblins conversation (needs racket + goblins)
```
