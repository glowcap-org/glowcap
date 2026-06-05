# bindings/racket

A Racket consumer of the Zig `libpancake` C ABI. See [`../README.md`](../README.md)
for the shipped C ABI surface and how the bindings are gated.

## Wired today

[`zig-smoke.rkt`](zig-smoke.rkt) is the consumer `zig build bindings` runs: it
loads the installed `libpancake`, creates a peer, feeds a borrowed `op:abort`
frame, and asserts the surfaced event is an Abort. That exercises the entire
shipped ABI — `pancake_peer_new` / `feed_borrowed` / `step` / `poll_event` plus
frame and event release — from a real foreign-language consumer.

```sh
zig build bindings        # builds libpancake, runs every binding smoke
```

Racket must be on `PATH` (provided by [`../../.devcontainer/`](../../.devcontainer/));
the build step resolves the shared library relative to `zig-out/`.

## Pending reference (not wired)

The richer code under [`racket/`](racket/) — a `racket/foreign` binding for a
typed FFI surface, a byte-counting Syrup framer, a TCP-bridge pump, and a
Goblins-API-compatible CapTP shim that lets a Spritely Goblins app run on
pancake over the wire — targets a larger C ABI than `libpancake` ships today
(peer/frame primitives only: no netlayer, codec selection, handshake, or
typed-value surface). It is preserved as reference, not deleted, and wires back
in as the C ABI grows the surface it needs. Until then it is not built or run,
and its file paths and APIs describe that planned surface rather than the
current one.

The dogfooding lessons that work surfaced are kept alongside it:

- [`LESSONS.md`](LESSONS.md) — FFI architecture opportunities the consumer revealed.
- [`SEAM-MATRIX.md`](SEAM-MATRIX.md) — the consumer-vs-ABI seam inventory.
