---
description: "Zig pancake architecture guardrails: codec-neutral model, authoritative session, sync no-I/O core."
globs: src/**/*.zig, test/**/*.zig, bench/**/*.zig, examples/**/*.zig, examples/**/*.c, include/**/*.h, build.zig, README.md, docs/**/*.md, AGENTS.md
---

# pancake — Architecture Guardrails

## Protocol Authority

OCapN behavior, Spritely Goblins fixtures, and Zig-local protocol scenarios are
the conformance authority. The Rust, Deno, Python, and Racket bindings are C ABI
dogfood consumers, never the oracle for Zig semantics.

## Runtime Shape

```text
Frame -> Codec view -> Session state -> Outgoing Message -> Codec -> Frame
```

Session state owns authority. Codecs parse/render bytes; they do not decide
whether references, answers, exports, imports, or releases are valid.

Export positions are minted only by the session's allocator
(`Peer.exportNextObject`; `pancake_peer_next_export` over the ABI). A counter
kept outside the session eventually collides with the same counter's
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
- `ocapn/`: the OCapN / CapTP protocol itself, the four layers that _are_ the
  protocol (everything else adds none). They live under `src/ocapn/` and are
  reached as `pancake.ocapn.<layer>`:
  - `ocapn/model`: codec-neutral semantic types.
  - `ocapn/codec`: encode/decode and borrowed semantic views.
  - `ocapn/session`: validation and authoritative tables.
  - `ocapn/engine`: caller-owned `Peer`, `step`, inbound dispatch, outbound
    drain.
- `actors`: Goblins-shaped local objects, a sync, no-I/O `Vat` (spawn,
  near-call `$`, eventual-send `<-`, promises) above the engine; adds no CapTP
  semantics the engine lacks. Also owns opt-in local time-travel
  (`snapshot`/`restore`, refcounted state boxes, copy-on-write, functional
  `become`; ADR-0060) — local-only, never wire state.
- `persistent`: a sharp leaf module of persistent immutable collections — one
  refcounted-HAMT `PersistentMap` (ADR-0061) so a persistent actor's functional
  `become` is O(log n) with structural sharing. Pure, no-I/O, imports nothing,
  and not on the public `pancake` namespace; reached by opt-in persistent
  actors.
- `net`: the one place `std.Io` enters, folds the one parser over a stream and
  binds the TCP socket. Not part of the no-I/O core.
- `driver`: the native application surface above both `actors` and `net`;
  `ConnectedVat` binds a vat to a live `net.Connection` over a caller-owned
  `engine.Peer`. Adds no CapTP semantics.
- `c_abi/`: the public C ABI family under `src/c_abi/`, grouped the way
  `src/ocapn/` groups the protocol core. It ships as a set of composable
  archives that share types by _layout_, not symbols — `libpancake_ocapn`,
  `libpancake_net`, and one per transport
  (`libpancake_net_transport_{tcp,inproc,iroh}`) — each exporting only its own
  `pancake_<family>_*` family (the ADR-0055 companion split, generalized to
  every transport by ADR-0059):
  - `c_abi/shared` (module `c_abi_shared`): the shared C-ABI vocabulary leaf,
    the C-visible frame/context types, return and codec codes, allocation
    policy, managed-frame machinery, and the per-thread last-error slot.
    Declares **no `export fn`**, so every archive reuses it without inheriting
    another's exports.
  - `c_abi/ocapn` (module `c_abi`): `libpancake_ocapn`'s entry points, the
    sans-io peer plus the shared vocabulary, C-shaped only. Peer, frame,
    context, and URI modules import `c_abi_shared` directly; there is no marshal
    leaf. Every handle frees through exactly one `pancake_*_release`; a
    `*_close` is a shutdown lever and never frees (`zig build meta-check` holds
    this in the generated headers). Header signatures and constant values are
    reflected from `src/c_abi/ocapn`, but their comment prose lives in
    `tools/header_gen.zig` — a C-contract change edits both the Zig doc comment
    and the generator's string, then `zig build gen-header-ocapn`.
  - `c_abi/net_transport` is the grouping directory for the transport archives:
    it holds no source of its own, only one subdirectory per transport,
    mirroring the `libpancake_net_transport_{tcp,inproc,iroh}` archive family.
    Each child below is its own `.graph = false` layer.
    - `c_abi/net_transport/tcp` (module `c_abi_net_transport_tcp`): the TCP
      transport archive (`libpancake_net_transport_tcp`). It imports `net`,
      `model`, and `c_abi_shared`, exports only its `pancake_tcp_*` family plus
      its own `pancake_tcp_last_error`, and reflects its header from its own
      root (`zig build gen-header-net-transport-tcp`).
    - `c_abi/net_transport/inproc` (module `c_abi_net_transport_inproc`): the
      in-process transport archive (`libpancake_net_transport_inproc`). It
      imports `net` and `c_abi_shared`, exports only its `pancake_inproc_*`
      family plus its own `pancake_inproc_last_error`, and reflects its header
      from its own root (`zig build gen-header-net-transport-inproc`).
    - `c_abi/net_transport/iroh` (module `c_abi_net_transport_iroh`): the iroh
      transport's public C ABI (`libpancake_net_transport_iroh`), exports only
      the `pancake_iroh_*` family and reuses `c_abi/shared` by layout. It sits
      _outside_ the layer DAG (`.graph = false` in `build.zig`'s `layer_table`)
      because it links the Rust sidecar and imports the injected `iroh`
      resident, neither expressible as a DAG edge; `irohAbiModule` mints it and
      `arch-check` still claims the directory for file coverage and the I/O
      bans. Header reflected from `src/c_abi/net_transport/iroh`, prose in
      `tools/header_gen_iroh.zig`.
  - The transport archives sit outside the layer DAG too (`.graph = false`); the
    `archive_table` in `build.zig` declares the archive set and its dependency
    edges (`net_transport_{tcp,inproc,iroh}` → `net` → `ocapn`).
- `oracle`: canonical CapTP scenario drivers, the observable-trace reference
  of truth that the Zig oracle tests (`test/oracle`) compare against. It is a
  public surface so a C consumer can produce the same canonical trace, but no
  binding consumes it today: the bindings prove the C ABI by dogfood, not by
  oracle traces. Not part of the runtime path. (The top-level `conformance/`
  tree is unrelated: it holds the external authority — the OCapN suite, the live
  Goblins peer — not this in-tree layer.)

If a change moves authority downward into codec/adapter code, stop and redesign.
When a concern fits no layer above, give it to the layer that owns the decision,
not the layer where the symptom appeared.
