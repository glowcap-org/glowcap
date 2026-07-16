# pancake: Remaining Work

The [ladder](ladder.md) explains which steps on the ladder are held.
[shipped.md](shipped.md) inventories what already runs. This file names only the
concrete work that remains. When an item ships, update this file to match.

## How this is ordered

Sections follow dependency, not priority.

1. **Watch items** wait on upstream.
2. **Platform reach** waits on hardware or toolchains this repository does not
   yet have.
3. **Scale, packaging, and external blocks** rest on shipped substrates, or on
   release work beyond the in-tree code.

Items in sections 1 and 2 are backlogged big rocks, not near-term
implementation. Each names a blocker and a flip condition, and what a
Linux-plus-bindings 1.0 audit may omit until that flip. When a flip condition
trips, promote the rock into a dedicated execution plan. Do not treat it as the
next opportunistic PR.

The blocking pump stays a single fiber by contract (ADR-0053): cooperative
request/response on one fiber; duplex backpressure on a completion loop
(`net.TcpLoop`, or `completion.Loop(iroh.Backend, iroh.DialResolver)`).

Wall-clock tripwires already run under `zig build check` via `perf-check`
(ADR-0073 / ladder step 2). Tighter hardware-stable ceilings remain a
measurement concern, not a missing check step.

## 1. Watch items (upstream)

Status: backlogged. These wait on upstream OCapN or Goblins. They are not a
craft failure for the current Linux-plus-bindings bar while the in-tree answers
hold. Do not invent wire pancake's partner cannot speak.

- **OCapN Null.**
  - **Blocker:** Goblins has no Null marshalling, and the upstream encoding is
    unsettled.
  - **Flip condition:** a settled upstream encoding plus Goblins marshalling, or
    an explicit OCapN decision that Null is out of scope.
  - **When flipped:** add a `model.Argument` arm (or document Null as forever
    out of scope), codec round-trips, and a Goblins live proof if marshalling
    exists. Until then unknown Syrup records stay `Tagged` (not a Null refuse).
  - **Depends on:** nothing in-tree. Integer is arbitrary-precision (ADR-0049);
    Struct and Undefined ship (ADR-0046).
- **Live `op:untag` against Goblins.**
  - **Blocker:** Goblins has not shipped the op's marshaller on the live wire.
  - **Flip condition:** Goblins ships `op:untag` marshalling; then add a live
    check step beside the existing pipelined `op:index` / `op:get` exercises in
    `goblins-interop`.
  - **When flipped:** extend the client bracket so pancake asks Goblins to
    untag (or Goblins asks pancake) and asserts settlement.
  - **Depends on:** in-tree projection answers already ship (ADR-0050,
    ADR-0052).
- **Draft CapTP `op:listen` arity.**
  - **Blocker:** the draft CapTP text sketches a 2-operand listen; Goblins and
    the upstream suite speak 3-operand (`wants_partial`). pancake follows the
    suite ([community-review](community-review.md)).
  - **Flip condition:** the draft text and suite agree on arity; then drop the
    invite asterisk if nothing else drifts.
  - **Depends on:** nothing in-tree.
- **Settlement encoding (`op:break` vs resolver-callback / `op:resolve`).**
  - **Blocker:** draft CapTP discussion sometimes names a separate `op:break`;
    Goblins CapTP v1.0 uses resolver-callback fulfill/break; `pancake-next`
    folds fulfill/break under `op:resolve`.
  - **Flip condition:** a settled CapTP settlement encoding that Goblins also
    speaks; then revisit the `pancake-next` fold and the invite brief.
  - **Depends on:** nothing in-tree for the Goblins path (already correct).

## 2. Platform reach

Status: backlogged. These wait on hardware, runners, or toolchains this
repository does not yet have. A top-tier 1.0 audit on Linux and bindings does
not require them; it does require this file to say so plainly. Ladder step 5
names Windows completion as open work. Full-N live-socket measurement is
machine work on that step too ([ladder](ladder.md)).

- **Windows / IOCP backend.**
  - **Blocker:** no Windows machine or IOCP backend in-tree.
  - **Flip condition:** a Windows host is available, and an IOCP backend lands
    behind the existing OS-neutral completion loop (io_uring and kqueue already
    ship; kqueue is compile-gated by `cross-check`).
  - **Depends on:** the publishable C ABI cascade staying honest on platforms
    that already pack
    ([ADR-0077](decisions/adr/ADR-0077-publishable-c-abi-resolve.md)). Do not
    claim portable 500k across OS before live-scale evidence exists on Linux.
- **macOS runtime CI.**
  - **Blocker:** no macOS runner in CI. kqueue is compile-gated on every
    `check` but never executed.
  - **Flip condition:** a macOS runner is available and a runtime proof step is
    wired.
  - **Flip condition:** the kqueue compile path already covered by `cross-check`.
- **Browser binding via WebAssembly (ADR-0070).**
  - **Blocker:** no WASM toolchain and browser milestone entry yet, and no WASM
    build of the C ABI.
  - **Flip condition:** a WASM toolchain and browser; then enter ADR-0070
    Milestone 1 (WebSocket transport), then Milestone 2 (WebRTC DataChannel with
    room-relayed signaling).
  - **Depends on:** the sans-io core already compiling to `wasm32`
    (`cross-check`). Prefer a published C ABI before browser packaging pressure.
    See [ADR-0070](decisions/adr/ADR-0070-browser-binding-via-wasm.md).

## 3. Scale, packaging, and external blocks

The iroh substrate is shipped (channel, discovery postures, key unification,
durable identity, mesh, loop scale path). See [shipped.md](shipped.md). What
remains:

- **Live-socket ~500k measurement.** iroh scale (ADR-0057) rides
  `completion.Loop(iroh.Backend, iroh.DialResolver)` + `driver.Bridge` +
  `driver_core.Host`, verified by `iroh-loop` and `bindings-iroh-loop`.
  `bench-peer-scaling`'s `served` row extrapolates in-process;
  `zig build tcp-loop` prints TCP bridge footprint. Opt-in Phase 2 of
  `bench-peer-scaling` (`--live`) measures TCP loopback under
  `completion.Loop` + `driver.Bridge` at stepped N. It is not part of
  `zig build check`. Never call 500k an achievement until a printed live-N run
  updates [ladder](ladder.md) and [shipped](shipped.md) with the step name and
  measured figures.
- **A hosted, versioned C release of the archives.** `zig build release-pack`
  and the `v*` GitHub release workflow exist. Bindings resolve archives through
  the publishable cascade in [`bindings/README.md`](../bindings/README.md)
  ([ADR-0077](decisions/adr/ADR-0077-publishable-c-abi-resolve.md)).
  `release-pack` dereferences soname symlinks so staged `lib/` has only regular
  files. What remains is ops on a credentialed maintainer machine: cut
  `v{abi_version}` after a green `release-pack` on each published target, flip
  `releases_published` in the same change that the release assets go live, then
  cold-cache smoke (checklist in `bindings/README.md`). Do not flip the valve
  before the GitHub assets exist.
- **Goblins interop over iroh.**
  - **Status:** backlogged (upstream).
  - **Blocker:** upstream Goblins ships no iroh netlayer.
  - **Flip condition:** a Goblins vat that speaks the iroh seam; then extend the
    existing `goblins-interop` / `goblins-handoff` / `goblins-gift` (and binding
    siblings) over iroh on the pancake side.
  - **When flipped:** keep Cap'n Proto out of the Goblins story; the proof is
    Syrup CapTP over the iroh netlayer the same way TCP is today.
  - **Depends on:** the pancake iroh substrate already shipped.
- **Export-side listen on an unresolved promise export.**
  - **Status:** named boundary (ADR-0007). Live object-export listen fires
    fulfill immediately; unresolved promise export without an answer row
    refuses loud.
  - **Flip condition:** a Goblins or suite app pattern needs listen-until-settle
    on a promise that is only an export (no answer row); then install against
    export-side promise resolution instead of refusing.
  - **Depends on:** answer-side and imported-promise listen already shipping.
- **A native Zig QUIC** stays rejected until iroh's protocols stabilize and a
  production Zig QUIC stack exists (ADR-0055's flip condition).
