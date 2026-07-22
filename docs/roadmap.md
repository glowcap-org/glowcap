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
  - **Depends on:** the publishable C ABI cascade matching the published archives
    on platforms that already pack
    ([ADR-0077](decisions/adr/ADR-0077-publishable-c-abi-resolve.md)). Do not
    claim portable 500k across OS before live-scale evidence exists on Linux.
- **macOS runtime CI.**
  - **Blocker:** no macOS runner in CI. kqueue is compile-gated on every
    `check` but never executed.
  - **Flip condition:** a macOS runner is available and a runtime proof step is
    wired.
  - **Until then:** the kqueue compile path stays covered by `cross-check`.
- **Browser binding via WebAssembly (ADR-0070).**
  - **Landed:** Milestone 1, and the full browser-peer surface over the
    byte-transparent relay. The browser dials, hosts objects, redeems handoffs,
    answers a non-listening caller on the connection the call arrived on, and is
    cold-dialed by another browser through the relay rendezvous — a resident-less
    `keyed-relay` transport keyed by identity (ADR-0088; `zig build
    rooms-web-dm-tabs`). [shipped.md](shipped.md) inventories it with the checks
    that hold it.
  - **Next:** cold-dial by a *native* peer and *across relays* (ADR-0088: the
    native runtimes carry no rendezvous adapter, and the `keyed-relay` locator
    names the identity, not the relay), then Milestone 2, the WebRTC DataChannel
    netlayer with signaling carried by an OCapN capability and the
    browser-to-browser handoff
    ([ADR-0089](decisions/adr/ADR-0089-webrtc-datachannel-netlayer.md)). Phases 1
    through 3, the phase-5 signaling proof, the signaling capability over CapTP,
    and the browser arm have landed: the phase-1 de-risk proof (`zig build
    webrtc-datachannel-test`); the phase-2 sidecar, Zig resident, and a live keyed
    OCapN session between two native peers over a real DataChannel (`zig build
    webrtc-interop`); the phase-3 public C ABI archive
    `libpancake_net_transport_webrtc` with its parity-checked header; a signaling
    hub that brings up the channel between two native peers by designator (`zig
    build webrtc-mesh`); the same signaling verbs hosted as an OCapN capability
    and driven over a keyed CapTP session (`zig build webrtc-signaling-captp`);
    and a real headless Chromium running `@pancake/webrtc` and the wasm Host to
    greet a native peer over a DataChannel (`zig build webrtc-browser-peer`), and
    two headless Chromium peers holding a keyed session over a direct DataChannel
    with the signaling host out of the byte path (`zig build
    webrtc-browser-to-browser`), and a three-party handoff where a `webrtc` give
    redeems over CapTP by signaling-then-handshake and the exporter's engine
    verifies both certificates before handing back the gifted capability (`zig
    build webrtc-handoff`, webrtc's `iroh-mesh`). The native binding FFI mirror is
    generated and gated across Python, Racket, and Rust; the TypeScript binding is
    browser-native. What remains is the dial classifier's signaling plan so the
    Host auto-redeems a bare `webrtc` locator (the redeem mechanism itself is
    proven by `webrtc-handoff`), the room-hosted signaling topology, and the
    completion-loop scale tier, with their gates named in the ADR.
  - **Depends on:** nothing upstream; the remaining work is in-tree.
    See [ADR-0070](decisions/adr/ADR-0070-browser-binding-via-wasm.md),
    [ADR-0088](decisions/adr/ADR-0088-fully-functioning-browser-peer.md), and
    [ADR-0089](decisions/adr/ADR-0089-webrtc-datachannel-netlayer.md).

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
- **Byte-transparent relay: the open legs.** The relay is a first-class
  capability, `@pancake/relay`, governed by
  [ADR-0086](decisions/adr/ADR-0086-byte-transparent-relay.md)'s contract and
  proven across every binding runtime; [shipped.md](shipped.md) inventories the
  runtimes and the checks that hold them. What remains:
  - **A named `PancakeRelayChannel` C-ABI shape.** iroh's raw conn plus readiness
    already satisfy the byte-channel contract; naming them as one documented
    channel (readiness fd, pump, `try_read`/`try_write` with `WOULD_BLOCK`,
    close, release) and adding the same for `inproc` makes in-tree relay
    conformance transport-uniform.
  - **A live Goblins-through-relay proof.** Byte transparency against a real
    Goblins peer through the relay has no build step yet.
- **Goblins interop over iroh.**
  - **Status:** backlogged (upstream).
  - **Blocker:** upstream Goblins ships no iroh netlayer.
  - **Flip condition:** a Goblins vat that speaks the iroh seam; then extend the
    existing `goblins-interop` / `goblins-handoff` / `goblins-gift` (and binding
    siblings) over iroh on the pancake side.
  - **When flipped:** keep Cap'n Proto out of the Goblins story; the proof is
    Syrup CapTP over the iroh netlayer the same way TCP is today.
  - **Depends on:** the pancake iroh substrate already shipped.
- **A native Zig QUIC** stays rejected until iroh's protocols stabilize and a
  production Zig QUIC stack exists (ADR-0055's flip condition).
- **Protocol-timeline observability: griddle and ocapnviz.** The message-flight
  plane of the observability family
  ([plan](planning/observability-family.md),
  [ADR-0084](decisions/adr/ADR-0084-pancake-cli-product-boundary.md)).
  - **griddle** is a deterministic simulator and TCP tap that emits a CapTP
    protocol timeline as NDJSON: the topology and the message flight a
    conversation produced. Today only the brand is reserved.
    `pancake griddle status|help` is a placeholder subtree under the product
    CLI, and the sim runtime is not built.
  - **ocapnviz** is the browser topology visualizer (Deno and Pixi) that draws
    that timeline. pancake is a timeline producer, not ocapnviz's server: a
    render-bridge relays the NDJSON to the browser over a websocket, so ocapnviz
    lives beside pancake rather than inside it.
  - **Status:** deferred. Neither the griddle runtime nor ocapnviz is shipped.
  - **Flip condition:** a dedicated plan lands the sim runtime and the shared
    timeline schema on the existing installable CLI, with an optional
    `pancake ocapn trace --ws` as a second producer of that schema for live
    CapTP. It stays one control plane, never a second CapTP stack.
  - **Until then:** agents read live session state through `pancake` argv/REPL
    and the project MCP front; timeline visualization waits.
- **The binding FFI and pump spine moves onto the generated tier.** The four
  bindings hand-mirror one production spine: the C symbol signature tables
  (about 1,200 lines across `bindings/rust/src/sys/`,
  `bindings/python/pancake/_ffi_*.py`, `bindings/ts/stack/internal/ffi/`, and
  `bindings/racket/private/ffi-*.rkt` for the driver archive alone, with
  ocapn and transport siblings beside them) and the readiness-pump
  choreography above them, held to the same shape today by the needle checks
  in `tools/check/meta_check/binding_spine.zig`. The generated-constants tier
  (`gen-binding-constants`, `gen-ts-abi`, `gen-binding-ffi-layouts`,
  `gen-binding-host-action`) is the proven recipe: reflect one Zig source,
  emit per language, gate on staleness. What the signature tables need that
  plain reflection cannot supply is direction semantics: which parameters are
  out-buffers. The wasm adapter's `SymbolDef.outBuffers` annotation, Racket's
  `wrap-out1` picks, and Python's out-pointer picks are each hand-judged per
  function today. So the source of truth is an annotated symbol table beside
  the C ABI, from which each language's FFI spelling generates and each
  `binding_spine` needle family retires as its slice lands. The first slice is
  landed: every archive with a stack dlopen loader (ocapn, driver, tcp,
  inproc) carries an annotated inventory (`symbols.zig` beside its exports:
  out-param indexes, pointer-crossing overrides, per-language omissions and
  omitted families with reasons), and `gen-ts-abi` generates all four TS
  tables from them under one staleness check, with a two-way compile-time
  walk between inventory and export set. The `@pancake/iroh` lazy loader
  generates too (its inventory added the `nonblocking` crossing semantic), so
  the whole TypeScript FFI tier — five loaders across five archives — comes
  from the inventories, and the iroh readiness event bits plus the
  ready-event layout ride the generated constant and layout families in every
  binding. Next slices are the other languages, with two design facts scouted:
  Zig reflection strips parameter *names*, so the Rust extern blocks (which
  humans read) need a name source — extend the inventories with per-parameter
  names, or parse the generated C headers — and the `sys/` files interleave
  hand-authored struct mirrors and layout pins with the extern blocks, so the
  generated half lands as a sibling module the hand file re-exports, not a
  whole-file replacement. Both facts are now proven code: the iroh extern
  block generates (`gen-binding-rust-ffi` — types reflected, names parsed
  from the gate-held header, `rust_omit` rows for the symbols the binding
  does not declare) and every `sys/` hand file re-exports its generated
  sibling: all five Rust extern blocks now come from the inventories, with
  the named callback aliases riding a per-archive `special` table. The
  ctypes tier generates too (`gen-binding-python-ffi`): the sigs dicts are
  positional so no name source is needed, the struct-pointer mirrors map
  mechanically (`PancakeDialPlan` to `_DialPlan`), and — because each
  `_ffi_*.py` builds its dict inside `_load()` with the struct types in
  scope — the generated `_sigs_gen.py` exports one function per archive
  taking those types as parameters, so no import cycle forms. The
  byte-pointer spelling normalized to `c_void_p` across all five dicts (it
  accepts every call style the binding uses — buffers, casts, None — so the
  hand files' `POINTER(c_uint8)` outliers retired with no caller sweep),
  and the inventories grew the `python_omit` column, since Python's
  declared set matches neither TS's (it declares `pump_drain` and
  `context_new`) nor Rust's (it declares `next_action` and `feed_bytes`).
  The Racket tables generate too (`gen-binding-racket-ffi`), which
  completes the language tiers: raw `_fun` signatures reflect from the Zig
  exports, the out-cell wrapper tier (`wrap-out1` / `call/outs`) derives
  from `out_params` plus each parameter's slot shape, `call/outs` argument
  names come from the generated headers, and the inventories grew
  `racket_omit` and the thread-level `blocking` column (`#:blocking?`, the
  fact under TS's narrower `nonblocking` dispatch policy). The one
  non-mechanical wrapper (the pending-dial view materializer) stays
  hand-written over its provided starred raw, and the driver cstructs moved
  into `ffi-shared.rkt` so the generated modules sit below every hand
  module. The pump choreography hoist closed the rock: the byte-path tail
  the four pumps each kept by hand moved behind the one C verb —
  `pancake_host_session_feed_bytes` owns framing *and* the unconsumed tail
  (`HostSession.feed_tail`), consuming every fed byte on success, with an
  empty feed resuming the frames held behind the handshake hello — so the
  binding pumps shrank to read, feed, and drain, and the four hand-copied
  inbox/coalesce choreographies deleted. The generated FFI tiers made the
  signature change one regeneration per language.
- **A2A-on-CapTP facade.** An agent-to-agent surface layered on the shipped Host
  and session verbs, deferred to its own plan
  ([design](planning/pancake-a2a-on-captp-design.md)). It composes the existing
  CapTP substrate and adds no wire semantics the engine lacks; `host` and
  `listen` stay argv-only and oracle evidence stays in Zig gates until it lands.
