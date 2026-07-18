---
description: "Zig pancake architecture guardrails: codec-neutral model, authoritative session, sync no-I/O core."
globs: src/**/*.zig, test/**/*.zig, bench/**/*.zig, examples/**/*.zig, examples/**/*.c, include/**/*.h, build.zig, README.md, docs/**/*.md, AGENTS.md
---

# pancake — Architecture Guardrails

## Protocol Authority

OCapN behavior, Spritely Goblins fixtures, and Zig-local protocol scenarios are
the conformance authority. The Rust, Deno, Python, and Racket bindings are C ABI
dogfood consumers, never the oracle for Zig semantics.

**CapTP vocabulary (ADR-0079, agent reference):** Keep this map here, not in
human first-read docs. `Host` / `PancakeHost` / binding `Host` = multi-session
CapTP product (owns `engine.Node`); `engine.Node` = sans-io handoff router;
binding `Session` = one-partner app object (`driver.Session`); Goblins `mycapn`
= endpoint ≈ Host + router tables ≈ `engine.Node`. Binding `Node` /
`Connection` deleted; `net.Connection` is the byte stream only. No
multi-session “node” alias for `PancakeHost`; no `driver.Connection`.

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

Vocabulary: CapTP is transport-agnostic. A netlayer is a locator transport
symbol (`tcp`, `keyed-tcp`, `inproc`, `iroh`). Socket and stream code live in
transport residents; `keyed-tcp` is its own symbol and reuses `tcp` sockets —
not a second CapTP stack. CapTP never names a transport.

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
- `net`: the one place `std.Io` enters, folds the one parser over a stream, and
  realizes netlayer residents over byte streams (sockets, pipes, QUIC sidecar).
  Not part of the no-I/O core. CapTP never names a transport.
- `driver/core` (`driver_core`): the sans-io serve core the driver stands on —
  the vat serve loop `Served` (which carries the publish/spawn/fetch verbs),
  its `ServeOptions`, the shared vocabulary (`Error`, `Identity`, `Capability`,
  `Settled`), the turn-time `spawnAt`, stateless GC, and the byte-fed
  multi-session CapTP host core `Host` (node-registered CapTP sessions as `Conn`,
  crossed-hellos, auto-redeem, vows, and an action queue the embedder
  answers). It is `core = true`, so
  `arch-check` bans I/O here exactly as in `engine`; that ban is what keeps a
  socket from ever creeping back into the serve core (ADR-0072). A byte-fed
  consumer (the `libpancake_driver` C ABI, a browser) drives a `Served` or a
  `Host` directly, net-free.
- `driver`: the native application surface above `driver_core`, `actors`, and
  `net`; the I/O bindings that compose the sans-io core. `BlockingSession` binds a
  `Served` to a live `net.Connection` over a caller-owned `engine.Peer`;
  owning one-call clients/servers ride `driver.Session` / `driver.Server`.
  `driver.Bridge` + `completion.Loop` is the native Zig multi-session CapTP path
  over `driver_core.Host` (ADR-0068/0072/0076) — the completion-loop scale path
  (`net.TcpLoop` over the `tcp` socket backend; `completion.Loop(iroh.Backend, iroh.DialResolver)`
  for iroh). Language bindings drive `driver_core.Host`
  through `libpancake_driver` (byte-fed readiness), not by rebuilding a Zig
  Host type. Adds no CapTP semantics. It also owns the `drawSessionSecret`
  entropy boundary and the transport constructors — the members that must stay
  above the core's I/O ban.
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
    `tools/gen/header/ocapn.zig` — a C-contract change edits both the Zig doc comment
    and the generator's string, then `zig build gen-header-ocapn` (writes
    `pancake_ocapn.h`);
    `zig build gen-ts-abi` reflects the same constants and struct layouts into
    the TypeScript binding's generated mirror. Multi-session CapTP product
    work uses `pancake_host_*` in `pancake_driver.h`.
  - `c_abi/driver` (module `c_abi_driver`): `libpancake_driver`, the byte-fed
    host tier over the C ABI (ADR-0072). An embedder that owns its own loop,
    sockets, and entropy drives a full multi-session CapTP Host with bytes:
    `pancake_host_session_feed` hands a CapTP session an inbound frame,
    `pancake_host_session_take_outbound` drains an outbound one, and the host's
    own effects (dials, gift-id entropy, flushes) surface as actions through
    `pancake_host_next_action` — so publish/fetch/send, vows, projections, and
    the full three-party handoff run from C with no socket. It wraps
    `driver_core.Host`, imports
    `foundation`/`model`/`engine`/`actors`/`driver_core` and `c_abi_shared`,
    exports only the `pancake_host_*` family plus its own
    `pancake_host_last_error`, and reuses `c_abi/shared`'s frame and argument
    vocabulary by layout — the family reads for the `Host` entry type though
    the archive is named for its module, as `libpancake_net_transport_tcp` →
    `pancake_tcp_*` does.
  - `c_abi/wasm` (module `c_abi_wasm`): the browser binding's freestanding
    `wasm32` entry root (ADR-0070). It imports `c_abi_shared`, `c_abi`, and
    `c_abi_driver` to force the `pancake_*` (ocapn) and `pancake_host_*` export
    families into one loadable wasm module, and adds the two JS<->wasm linear-
    memory primitives `pancake_wasm_alloc` / `pancake_wasm_free`. It adds no
    CapTP surface of its own; a browser instantiates the module and drives the
    byte-fed Host with bytes exactly as a C embedder does. Built by
    `zig build wasm-driver`; sits outside the layer DAG (`.graph = false`).
  - `c_abi/net_transport` is the grouping directory for the transport archives:
    it holds no source of its own, only one subdirectory per transport,
    mirroring the `libpancake_net_transport_{tcp,inproc,iroh}` archive family.
    Each child below is its own `.graph = false` layer.
    - `c_abi/net_transport/tcp` (module `c_abi_net_transport_tcp`): the TCP
      transport archive (`libpancake_net_transport_tcp`). It imports `net`,
      `driver`, and `c_abi_shared`, exports only its `pancake_tcp_*` family plus
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
      `tools/gen/header/iroh.zig`.
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
