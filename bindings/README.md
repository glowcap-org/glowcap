# bindings/

Per-language consumers of the Zig `libpancake` C ABI. Each binding dogfoods
the C ABI as a real foreign-language consumer — the systemic safeguard
against wire-shape and ABI regressions that only surface through an actual
FFI consumer.

## The C ABI surface today

The shipped `pancake.h` exposes the peer/frame primitives only:
`pancake_peer_new` / `pancake_peer_feed_borrowed` / `pancake_peer_feed_owned`
/ `pancake_peer_step` / `pancake_peer_take_outbound` / `pancake_peer_poll_event`
plus frame/event release. There is no netlayer, `last_error`, codec-selection,
or handshake surface yet.

Each binding therefore ships a **Zig-ABI smoke consumer** that loads the
installed shared library, creates a peer, feeds a borrowed `op:abort` frame,
and asserts the surfaced event is an Abort:

| Binding | Smoke consumer | Pending (awaiting C ABI growth) |
| --- | --- | --- |
| [`rust/`](rust/) | `src/lib.rs` (`zig build rust-dogfood`) | — |
| [`deno/`](deno/) | `zig_smoke.ts` | the netlayer/handshake/scenario code under `src/` |
| [`python/`](python/) | `zig_smoke.py` | the netlayer/handshake/scenario code under `pancake/` |
| [`racket/`](racket/) | `zig-smoke.rkt` | the Goblins/CapTP shim under `racket/` |

The richer code each binding carries (netlayers, scenario runners, the
Goblins captp shim) targeted the Rust workbench's three-cdylib FFI family
(runtime + net-tcp + net-iroh, with a `last_error` seam). It is preserved
here as **pending reference** — not wired, not deleted — until the Zig C ABI
grows the surface it needs.

## Running

```sh
zig build bindings        # rust + deno + python + racket smokes
zig build rust-dogfood    # just the Rust consumer (also part of `zig build check`)
```

`zig build bindings` requires `deno`, `python3`, and `racket` on PATH —
provided by [`../.devcontainer/`](../.devcontainer/). The shared library is
built and installed to `../zig-out/lib/libpancake.so` first; each consumer
resolves it relative to its own location.
