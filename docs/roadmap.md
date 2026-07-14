# pancake: Remaining Work

The [ladder](ladder.md) explains which architectural rungs are held.
[shipped.md](shipped.md) inventories what already runs and which gates pin it.
This file names only the concrete work that remains. When an item lands, this
file changes in the same diff.

## How this is ordered

Sections follow dependency, not priority.

1. **Watch items** wait on upstream, not on this repository.
2. **Platform reach** needs hardware or toolchains this environment lacks.
3. **Scale, packaging, and external blocks** rest on shipped substrates or on
   release/ops work outside a single in-tree pass.

Independent tracks that used to live here have either shipped (grant-on-marshal
per ADR-0074; loop-side dial executor and C ABI `local_turn_budget` per
ADR-0076; C ABI `pancake_peer_expect_partner_key` per ADR-0075) or moved below
as deferred packaging / binding / convergence work.

ADR-0053 refuses a read/write fiber split for the blocking pump: cooperative
request/response stays on one fiber; duplex backpressure rides a completion
loop (`net.TcpLoop`, or `completion.Loop(iroh.Backend, iroh.DialResolver)`).

Wall-clock tripwires already gate under `zig build check` via `perf-check`
(ADR-0073 / ladder rung 2). Tighter hardware-stable ceilings remain a
measurement concern, not a missing gate.

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

## 2. Platform reach

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

## 3. Scale, packaging, and external blocks

The iroh substrate is shipped (channel, discovery postures, key unification,
durable identity, mesh, loop scale path). See [shipped.md](shipped.md). What
remains:

- **Live-socket ~500k measurement.** iroh scale (ADR-0057) rides
  `completion.Loop(iroh.Backend, iroh.DialResolver)` + `driver.Bridge` + `driver_core.Host`, gated by
  `iroh-loop` and `bindings-iroh-loop`; `bench-peer-scaling`'s `served` row
  extrapolates in-process; `zig build tcp-loop` prints TCP bridge footprint.
  Opt-in Phase 2 of `bench-peer-scaling` (`--live`) measures TCP loopback under
  `completion.Loop` + `driver.Bridge` at stepped N (RSS, connect success,
  ns/turn); it is not part of `zig build check`.
- **A hosted, versioned C release of the archives.** `zig build release-pack`
  and the `v*` GitHub release workflow exist; bindings resolve archives through
  the publishable cascade in [`bindings/README.md`](../bindings/README.md)
  ([ADR-0077](decisions/adr/ADR-0077-publishable-c-abi-resolve.md)): each
  package ships `c-abi-resolve.json` and downloads language-natively, so a
  published binding (or a future separate binding repo) does not need a Zig
  checkout. What remains is ops: flip `releases_published` and cut the first
  versioned per-platform tarballs keyed to `pancake_abi_version` (checklist in
  `bindings/README.md`).
- **Goblins interop over iroh.** Upstream: Goblins ships no iroh netlayer.
  Teaching a Goblins vat that seam unblocks extending the existing
  `*-goblins-interop` / `*-goblins-handoff` gates over iroh on the pancake side.
- **A native Zig QUIC** stays rejected until iroh's protocols stabilize and a
  production Zig QUIC stack exists (ADR-0055's flip condition).
