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
  - **Landed:** Milestone 1. The byte-fed Host compiles to one freestanding
    `wasm32` module (`zig build wasm-driver`), and `@pancake/web`
    (`bindings/ts/web`) runs the whole `@pancake/stack` surface over it: the
    wasm FFI adapter, the module-reported struct layout, and a WebSocket byte
    channel. `zig build web-peer-test` proves a browser-shaped peer holding a
    keyed session against a native WebSocket-accepting host, with calls in
    both directions; `wasm-driver-test`, `wasm-abi-layout-check`, and
    `wasm-import-check` hold the layers under it.
  - **Also landed:** the rooms web demo runs the browser peer over the
    byte-transparent relay ([shipped.md](shipped.md)); the plan is
    [rooms-web-browser-peer](planning/rooms-web-browser-peer.md).
  - **Next:** browser DMs through the relay (the relay item in section 3
    below), then Milestone 2 (WebRTC DataChannel with
    room-relayed signaling, the browser-to-browser handoff).
  - **Depends on:** nothing upstream; the remaining work is in-tree.
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
- **Byte-transparent relay: the open legs.** The relay is a first-class
  capability, `@pancake/relay`, governed by
  [ADR-0086](decisions/adr/ADR-0086-byte-transparent-relay.md)'s contract, and
  proven across three runtimes ([shipped.md](shipped.md)). The cross-runtime
  matrix `zig build bindings-relay` holds TCP forwarding and the backpressure
  clause for the Deno reference relay, the Python relay
  (`bindings/python/relay.py`), and the Rust relay (`bindings/rust/relay`);
  `zig build bindings-relay-iroh` holds the iroh leg for all three, each dialing
  a real iroh endpoint over QUIC. The `rooms-web-*` steps drive the Deno relay
  through a real Chromium. What remains:
  - **A Racket relay row.** ADR-0086 makes the relay a per-runtime pump over a
    shared contract, added to the matrix as a row. Racket needs two pieces first:
    a WebSocket server (the pinned toolchain ships none, so the row needs the
    `rfc6455` package added to the devcontainer or a hand-rolled RFC 6455 server),
    and a bare iroh relay-channel dial in the binding (it drives the iroh
    readiness loop for sessions but exposes no raw-channel dial like the other
    three bindings). The contract-level pieces already exist. Zig has no
    WebSocket server yet either, so a Zig relay needs one built first.
  - **Dispatch through the shared classifier.** Each relay classifies its target
    locator locally today. Routing that dispatch through the shared
    `pancake_host_plan_dial` (the same classifier the handoff redeem-dial uses),
    so every runtime's relay sorts a locator identically, is the remaining
    consistency step ADR-0086 names.
  - **A named `PancakeRelayChannel` C-ABI shape.** iroh's raw conn plus readiness
    already satisfy the byte-channel contract; naming them as one documented
    channel (readiness fd, pump, `try_read`/`try_write` with `WOULD_BLOCK`,
    close, release) and adding the same for `inproc` makes in-tree relay
    conformance transport-uniform.
  - **Browser-to-member DMs through the relay.** The relay allow-list admits
    only the room server's own port, so the browser DM path is a stub that
    says the feature is coming later. Opening it needs a source for member
    ports (for example, the room server exposing live-introduction locators
    over a session) plus a live proof.
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
