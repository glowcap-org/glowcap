# bindings/python

A Python (`ctypes`, standard library only) consumer of the Zig `libpancake` C
ABI. See [`../README.md`](../README.md) for the shipped C ABI surface and how the
bindings are gated.

## Wired today

[`zig_smoke.py`](zig_smoke.py) is the consumer `zig build bindings` runs: it
loads the installed `libpancake`, creates a peer, feeds a borrowed `op:abort`
frame, and asserts the surfaced event is an Abort. That exercises the entire
shipped ABI — `pancake_peer_new` / `feed_borrowed` / `step` / `poll_event` plus
frame and event release — from a real foreign-language consumer.

```sh
zig build bindings        # builds libpancake, runs every binding smoke
```

The build step resolves the shared library relative to `zig-out/`; CPython
3.11+ on an LP64 platform is required.

## Pending reference (not wired)

The richer code under [`pancake/`](pancake/) — an env-driven multi-library
loader, per-library last-error slots, fixed-size tagged-union value marshalling,
a TCP/TLS/iroh netlayer, and a single-thread poll pump — targets a larger C ABI
than `libpancake` ships today (peer/frame primitives only: no netlayer, codec
selection, handshake, or `last_error`). It is preserved as reference, not
deleted, and wires back in as the C ABI grows the surface it needs. Until then
it is not built or run, and its file paths and APIs describe that planned
surface rather than the current one.
