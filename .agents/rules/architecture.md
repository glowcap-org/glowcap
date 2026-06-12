---
description: "Zig pancake architecture guardrails: codec-neutral model, authoritative session, sync no-I/O core."
globs: src/**/*.zig, test/**/*.zig, bench/**/*.zig, examples/**/*.zig, examples/**/*.c, include/**/*.h, build.zig, README.md, docs/**/*.md, AGENTS.md
---

# pancake — Architecture Guardrails

## Protocol Authority

OCapN behavior, Spritely Goblins fixtures, and Zig-local protocol scenarios are
the conformance authority. The Rust, Deno, Python, and Racket bindings are
C ABI dogfood consumers, never the oracle for Zig semantics.

## Runtime Shape

```text
Frame -> Codec view -> Session state -> Outgoing Message -> Codec -> Frame
```

Session state owns authority. Codecs parse/render bytes; they do not decide
whether references, answers, exports, imports, or releases are valid.

Export positions are minted only by the session's allocator
(`Peer.exportNextObject`; `pancake_peer_next_export` over the ABI). A
counter kept outside the session eventually collides with the same counter's
resolver/bootstrap exports and silently aliases a live object.

## Core Boundary

The portable core stays deterministic, sync, and no-I/O:

- no sockets;
- no hidden scheduler;
- no background tasks;
- no `std.Io` in core protocol modules;
- no adapter policy inside codecs/session/engine.

Adapters may use `std.Io`, transports, callbacks, and host scheduling. They do
not add CapTP semantics that the core lacks.

## Layer Ownership

- `foundation`: bytes, IDs, frame ownership.
- `ocapn/`: the OCapN / CapTP protocol itself — the four layers that *are* the
  protocol (everything else adds none). They live under `src/ocapn/` and are
  reached as `pancake.ocapn.<layer>`:
  - `ocapn/model`: codec-neutral semantic types.
  - `ocapn/codec`: encode/decode and borrowed semantic views.
  - `ocapn/session`: validation and authoritative tables.
  - `ocapn/engine`: caller-owned `Peer`, `step`, inbound dispatch, outbound drain.
- `actors`: Goblins-shaped local objects — a sync, no-I/O `Vat` (spawn,
  near-call `$`, eventual-send `<-`, promises) above the engine; adds no CapTP
  semantics the engine lacks.
- `net_adapter`: the one place `std.Io` enters — folds the one parser over a
  stream and binds the TCP socket. Not part of the no-I/O core.
- `driver`: the native application surface above both `actors` and `net_adapter`;
  `ConnectedVat` binds a vat to a live `net_adapter.Connection` over a
  caller-owned `engine.Peer`. Adds no CapTP semantics.
- `c_abi`: C-shaped vocabulary only. Every handle frees through exactly one
  `pancake_*_release`; a `*_close` is a shutdown lever and never frees
  (`zig build meta-check` holds this in the generated headers). The headers'
  signatures and constant values are reflected from `src/c_abi`, but their
  comment prose lives in `tools/header_gen.zig` — a C-contract change edits
  both the Zig doc comment and the generator's string, then `zig build
  gen-header`.
- `conformance`: canonical CapTP scenario drivers — the observable-trace oracle
  that `test/conformance`, `test/oracle`, and the bindings' scenario runners
  compare against. Not part of the runtime path.

If a change moves authority downward into codec/adapter code, stop and redesign.
When a concern fits no layer above, give it to the layer that owns the decision,
not the layer where the symptom appeared.
