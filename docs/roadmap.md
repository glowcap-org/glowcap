# pancake: Remaining Work

The [ladder](ladder.md) explains which architectural rungs are held.
[shipped.md](shipped.md) inventories what already runs and which gates pin it.
This file names only the concrete work that remains. When an item lands, this
file changes in the same diff.

## How this is ordered

Sections follow dependency, not priority.

1. **Watch items** wait on upstream, not on this repository.
2. **Independent tracks** are localized and can proceed in parallel.
3. **Platform reach** needs hardware or toolchains this environment lacks.
4. **Scale and external blocks** rest on the shipped iroh substrate.

## 1. Watch items (upstream)

- **OCapN Null.** The one passable still outside the model (Integer is
  arbitrary-precision per ADR-0049; Struct and Undefined ship per ADR-0046).
  Null stays fail-closed: Goblins has no Null marshalling and the upstream
  encoding is unsettled. The boundary is pinned by tests; it unblocks only when
  upstream settles an encoding.
- **Live `op:untag` against Goblins.** Projection ops `op:get`, `op:index`, and
  `op:untag` are answered in-tree (ADR-0050, ADR-0052). The live Goblins gate
  already exercises pipelined `op:index` and `op:get`; a live untag gate slots
  in when Goblins ships the op's marshaller.

## 2. Independent tracks

- **Export-on-marshal for spawned capabilities.** `driver.spawnAt` (and the
  `spawn` verbs on it) mints the export when the actor is spawned. Minting only
  when the reference first marshals onto the wire would close the early-export
  window. Today that contract is documented on `spawn` / `spawnAt`; `Vat.spawn`
  is the no-export alternative.
- **Binding-level keyed-tcp surfaces.** The library already ships
  `net.tcp_keyed` and `engine.Peer.expectPartnerKey` (ADR-0075), gated by
  `test/driver/keyed_tcp_restart_test.zig`. Open: per-binding dial/host
  surfaces, a C ABI partner-key-pin export, and the byte-fed iroh dial pin
  (ADR-0075 § Scope).
- **Loop-side dial executor.** `driver.LoopBridge` (ADR-0076) feeds the
  byte-fed host from `net.Loop` and is gated by `zig build tcp-loop` plus the
  handoff-across-one-loop test. It answers every `dial` action fail-closed, so
  a bridged host can mint gives but cannot yet redeem as a handoff recipient
  on one loop thread.
- **C ABI `local_turn_budget`.** The Zig TCP bridge can set
  `Host.Options.local_turn_budget`; `pancake_host_new` does not surface it, so
  every binding loop over the C ABI still drives unbounded amplification
  (ADR-0076 § Scope).
- **A hosted, versioned C release of the archives.** Bindings already resolve
  archives through the cascade in [`bindings/README.md`](../bindings/README.md).
  Deferred is the find leg's upstream: a hosted, versioned, per-platform release
  keyed to `pancake_abi_version`, the prerequisite for runtime-download or npm
  per-platform packaging.

ADR-0053 refuses a read/write fiber split for the blocking pump: cooperative
request/response stays on one fiber; duplex backpressure rides a completion
loop (`net.Loop` or iroh's `LoopHost`).

Wall-clock tripwires already gate under `zig build check` via `perf-check`
(ADR-0073 / ladder rung 2). Tighter hardware-stable ceilings remain a
measurement concern, not a missing gate.
## 3. Platform reach

- **Windows / IOCP backend.** The completion loop is OS-neutral; io_uring and
  kqueue ship (kqueue compile-gated by `cross-check`). IOCP needs a Windows
  machine.
- **macOS runtime CI.** kqueue is compile-gated on every `check` but never run.
  Runtime proof needs a macOS runner.
- **Browser binding via WebAssembly (ADR-0070).** The sans-io core compiles to
  `wasm32` (`cross-check`). Milestone 1 is a WebSocket transport; Milestone 2 is
  WebRTC DataChannel with room-relayed signaling. Needs a WASM toolchain and a
  browser. See
  [ADR-0070](decisions/adr/ADR-0070-browser-binding-via-wasm.md).

## 4. Scale and external blocks

The iroh substrate is shipped (channel, discovery postures, key unification,
durable identity, mesh, loop scale path). See [shipped.md](shipped.md). What
remains:

- **Live-socket ~500k measurement.** `iroh.LoopHost` (ADR-0057) is gated by
  `iroh-loop` and `bindings-iroh-loop`; `bench-peer-scaling`'s `served` row
  extrapolates in-process; `zig build tcp-loop` prints TCP bridge footprint.
  The open work is measuring under real live sockets at the footprint target.
- **iroh `LoopHost` → `net.Loop` + `LoopBridge` convergence.** The iroh scale
  path still duplicates the TCP loop's slot/outbound/close machine (~467 lines
  in `src/net/transport/iroh.zig`); every host-bridge hardening lands twice or
  TCP-only until that converges (ADR-0076 § Scope).
- **Goblins interop over iroh.** Upstream: Goblins ships no iroh netlayer.
  Teaching a Goblins vat that seam unblocks extending the existing
  `*-goblins-interop` / `*-goblins-handoff` gates over iroh on the pancake side.
- **A native Zig QUIC** stays rejected until iroh's protocols stabilize and a
  production Zig QUIC stack exists (ADR-0055's flip condition).
