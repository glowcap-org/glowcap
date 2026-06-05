# bindings/

Per-language consumers of the Zig `libpancake` C ABI. Each binding dogfoods
the C ABI as a real foreign-language consumer — the systemic safeguard
against wire-shape and ABI regressions that only surface through an actual
FFI consumer.

## The C ABI surface today

The shipped `pancake.h` exposes:

- **Peer / frame primitives:** `pancake_peer_new` /
  `pancake_peer_feed_borrowed` / `pancake_peer_feed_owned` / `pancake_peer_step`
  / `pancake_peer_take_outbound` / `pancake_peer_poll_event` plus frame/event
  release.
- **Bootstrap serving:** `pancake_peer_register_bootstrap_cap` (publish a local
  capability behind a swissnum for inbound fetch).
- **Per-thread last error:** `pancake_last_error` / `pancake_clear_last_error`
  re-expose the concrete socket cause behind a flat `PANCAKE_ERR_IO`.
- **Blocking `tcp-testing-only` endpoint handles:** `pancake_tcp_netlayer_new` /
  `_free` (an explicit handle owning the I/O backend), then
  `pancake_endpoint_tcp_testing_connect` / `_testing_listen` / `_testing_accept`
  / `_listener_port` / `_read_frame` / `_write_frame` / `_conn_close` /
  `_listener_close`. The host owns the peer and shuttles whole frames
  (`read_frame -> feed_owned -> step -> take_outbound -> write_frame`); framing
  is the active codec's one parser (codec selected via `PANCAKE_CODEC_*`). The
  C side never names a `std.Io` — the netlayer handle owns it explicitly, no
  hidden runtime. Cleartext, loopback-grade — TLS / QUIC layer above the same
  adapter (see
  [ADR-0030](../docs/decisions/adr/ADR-0030-netlayer-connection-and-memory-posture.md)).

The shared library still carries no TLS, crossed-hellos, or background run loop
(all deferred by name in ADR-0030).

Each binding ships a **Zig-ABI smoke consumer** that loads the installed shared
library, creates a peer, feeds a borrowed `op:abort` frame, and asserts the
surfaced event is an Abort:

| Binding | Smoke consumer | Pending (awaiting C ABI growth) |
| --- | --- | --- |
| [`rust/`](rust/) | `src/lib.rs` (`zig build rust-dogfood`) | — |
| [`deno/`](deno/) | `zig_smoke.ts` | the netlayer/handshake/scenario code under `src/` |
| [`python/`](python/) | `zig_smoke.py` | the netlayer/handshake/scenario code under `pancake/` |
| [`racket/`](racket/) | `zig-smoke.rkt` | the Goblins/CapTP shim under `racket/` |

The richer code each binding carries (full netlayers, scenario runners, the
Goblins captp shim) targeted the Rust workbench's three-cdylib FFI family
(runtime + net-tcp + net-iroh, with a `last_error` seam). It is preserved
here as **pending reference** — not wired, not deleted — until the Zig C ABI
grows the remaining surface (TLS / iroh transports, crossed-hellos).

## Running

```sh
zig build bindings        # rust + deno + python + racket smokes
zig build rust-dogfood    # just the Rust consumer (also part of `zig build check`)
```

`zig build bindings` requires `deno`, `python3`, and `racket` on PATH —
provided by [`../.devcontainer/`](../.devcontainer/). The shared library is
built and installed to `../zig-out/lib/libpancake.so` first; each consumer
resolves it relative to its own location.
