# pancake ↔ Spritely Goblins — the 5-seam interop matrix

This directory proves that **pancake can substitute into canonical Spritely
Goblins at either of two seams — the OCapN/CapTP layer and the netlayer —
independently, in both directions, across every transport pancake ships.**
Everything that isn't the substituted seam is *unmodified* upstream Goblins
(vats, actors, promises, sturdyrefs, the Syrup codec, marshalling).

## The two seams

| Seam | Upstream surface | pancake substitute |
| --- | --- | --- |
| **OCapN / CapTP** | `(spawn-mycapn . netlayers)` from `goblins/ocapn/captp` | [`racket/captp.rkt`](racket/captp.rkt) — a drop-in `spawn-mycapn` backed by the pancake FFI peer |
| **netlayer** | a Goblins netlayer actor (`netlayer-name` / `our-location` / `setup` / `connect-to` → `read-message`/`write-message`) | a pancake-backed netlayer (below) |

## The five stacks

| # | OCapN/CapTP | Netlayer | What it proves | Status |
| --- | --- | --- | --- | --- |
| 1 | Spritely | Spritely | baseline — pure upstream Goblins | n/a (stock) |
| 2 | **pancake** | Spritely (Racket sockets) | pancake CapTP over a non-pancake transport | ✅ |
| 3 | **pancake** | **pancake** TCP+TLS | pancake at both seams, rustls transport | ✅ |
| 4 | Spritely | **pancake** iroh | pancake transport under stock Goblins CapTP | ✅ |
| 5 | **pancake** | **pancake** iroh | pancake at both seams, QUIC-over-iroh | ✅ |

Each ✅ is an echo cap round-tripping across the wire between the two peers.
Run them all:

```bash
bash reference/implementations/pancake-goblins/racket/run-seams.sh
# => ALL SEAMS GREEN
```

(The runner builds nothing; it needs the three cdylibs at `target/release/`
— `cargo build --release -p pancake-ffi-runtime -p pancake-ffi-net-tcp -p pancake-ffi-net-iroh`
— and the lazy-installed Racket+Goblins. Scripts live in [`racket/seams/`](racket/seams/).)

## The netlayer pieces

Two shapes, because the two seams meet the netlayer differently:

- **captp-side** (pancake CapTP drives the transport via a `transport-ops`
  byte vtable): [`pancake-tcp-netlayer.rkt`](racket/pancake-tcp-netlayer.rkt)
  (cleartext), [`pancake-tcp-tls-netlayer.rkt`](racket/pancake-tcp-tls-netlayer.rkt),
  [`pancake-iroh-netlayer.rkt`](racket/pancake-iroh-netlayer.rkt), and
  [`racket-socket-netlayer.rkt`](racket/racket-socket-netlayer.rkt) (pancake
  CapTP over Racket's own `racket/tcp`, framing via the `pancake-syrup-frame-probe` FFI).
- **Goblins-protocol** (stock Goblins CapTP drives the transport via
  `read-message`/`write-message`, which are just `syrup-read`/`syrup-write` —
  pancake frames *are* self-delimiting Syrup values, so the bridge is a thin
  port shim): [`pancake-iroh-goblins-netlayer.rkt`](racket/pancake-iroh-goblins-netlayer.rkt),
  [`pancake-tcp-tls-goblins-netlayer.rkt`](racket/pancake-tcp-tls-goblins-netlayer.rkt).

## Other consumers of the same C ABI

The same cdylib family backs fully-featured bindings in two more languages,
each verified to reach `SESSION_OPEN` over a loopback handshake:

- [`../pancake-deno/`](../pancake-deno/) — Deno FFI (`Deno.dlopen`).
- [`../pancake-python/`](../pancake-python/) — Python `ctypes`.

## Notes

- **Two-process, not single-process, for TLS/cleartext.** A single Racket
  process can't drive two *simultaneously-blocked* handshake calls (client
  `connect` + server `accept`); iroh's lazy `connect` is the exception. The
  TLS/socket proofs run host + client as separate processes (Python's
  `ctypes` sidesteps this by releasing the GIL, so its in-process TLS
  loopback works).
- **Scope.** These prove the *core* CapTP leaves at every seam (handshake,
  deliver, resolve / resolver-callback, bootstrap-fetch, cap-passing,
  abort/break). pancake's runtime implements the full wire surface
  (pipelining, `op:get`/`index`, distributed GC, three-vat handoff);
  exercising those *through the Racket shim* is bounded FFI-surface work, not
  protocol work.
