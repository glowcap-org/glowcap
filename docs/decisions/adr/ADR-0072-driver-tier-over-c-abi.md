---
id: ADR-0072
status: accepted
date: 2026-07-09
tags: [c-abi, driver, host, net, netlayer, loop, bindings, wasm, browser]
decision: "The C ABI gains a `libpancake_driver` archive that projects `driver.core.Host` (ADR-0068) as a sans-io core a binding drives, so a binding stops re-implementing the host tier per language on top of `pancake_peer_*` and the then-current pancake_node_* waist (since deleted; CapTP product work uses `pancake_host_*` only). Two seams are host-configurable: a binding registers netlayers as byte-fed callback vtables dispatched by transport symbol (the C projection of ADR-0062's `[]const net.netlayer.Netlayer`), and a binding either owns the loop (the core never blocks, draining through a `schedule` callback and honoring a `set_read_paused` backpressure callback while the binding pumps its own event loop) or delegates it (name a built-in netlayer and call a blocking `run`, where `net.TcpLoop` / `completion.Loop` owns sockets and scheduling; Zig CapTP multi-conn rides `driver.Bridge` per ADR-0076). The core is byte-fed, so Zig's stream-shaped `tcp`/`iroh` netlayers are used only in the Zig-owned mode where the loop bridges stream to feed; the byte-fed seam is not a rewrite of the stream contract. A published actor is embedder-hosted behavior the core hosts through `Vat.spawnHosted` / `HostedActor` (ADR-0071), reusing that contract rather than a second archive; the interim `libpancake_actors` archive is retired (this ADR supersedes ADR-0071 — the `spawnHosted` foundation stands, consumed here). Because the core is sans-io it compiles to `wasm32`, so a browser binding (ADR-0070) drives this same core from JS through a WebSocket netlayer instead of driving the raw `Peer`. The archive is named after its Zig module (as `actors`/`net`/`ocapn` are), imports `driver` and `c_abi_shared`, exports only the `pancake_host_*` family, is symbol-disjoint per ADR-0059, and is an adapter, never in the sans-io core."
supersedes: [ADR-0071]
superseded_by: []
---

# ADR-0072 The driver tier over the C ABI: host-configurable netlayers and loop

> **Vocabulary note (ADR-0079).** CapTP multi-connection product work is
> `Host` / `PancakeHost` / binding `Host` over `pancake_host_*`. The
> pancake_node_* C waist named in Context below is deleted; binding `Node` is
> not current. Embedder-hosted behavior is `HostedActor` / `spawnHosted`.

## Context

ADR-0068 built the native multi-connection tier, `driver.core.Host`: one identity,
one `engine.Node`, one crossed-hellos registry, and the redeem and origination
seams that make three-party handoffs work across many connections. It is
Zig-native by design, and it named the boundary it left standing — the
single-connection `connect`/`listen` tier below it, and the node-less, TCP-only
`LoopHost`/`LoopDialer` fan-out beside it — with the explicit note that "growing
the loop under the host is the direction that retires the boundary."

Every language binding delivers that same host tier to its users. ADR-0066/0067
gave each binding a transparent three-party story by having its `connect` build
a composite that owns the retained identity, the shared gift registry, and the
serve step. That composite is `driver.core.Host`'s job, re-written in TypeScript,
Python, Racket, and Rust on top of the sans-io `pancake_peer_*` and the then-
current pancake_node_* families (since deleted) — the connection pump, the
redeem loop, the
publish/fetch ergonomics, the promise-to-answer bookkeeping, once per language.
The reference implementation's own consumers carry the driver's orchestration,
and the tested Zig tier (`test/driver/core_host_test.zig`) is not the
code any binding actually runs. This is the drift ADR-0059 removed for value
vocabulary — shared by layout, not re-declared — reappearing one layer up as
shared behavior re-implemented instead of shared.

Two configurable seams are the reason a binding cannot simply drive the Zig
tier. ADR-0062 made a transport a runtime vtable the driver dispatches by symbol
and settled the Zig front door on a bare `[]const net.netlayer.Netlayer` slice,
but it exposed that configurability to C only as *built-in* transport archives
(`libpancake_net_transport_{tcp,inproc,iroh}`): a C consumer links a transport,
it does not supply one. A runtime that owns its transport — a Deno WebSocket, a
`asyncio` socket, a browser tab that has no socket at all — has no C seam to plug
that transport into the host tier. And the loop stays outside the netlayer
contract (ADR-0043/0062): the C ABI's sans-io `PancakePeer` is offered "for a
host that owns its own loop and drives raw frames," but that ownership is
available only at the single-`Peer` grain, not for the whole host tier, and the
Zig-owned `LoopHost` is not exposed to C at all. ADR-0070 makes the browser
drive the raw `Peer`/`Node` from JS precisely because no higher seam exists to
drive.

This engages the [core-boundary First
Principle](../../../AGENTS.md#first-principles) — the host core stays
deterministic and sans-io, adapters own I/O and scheduling — and
explicit-over-implicit, boring-public-surface, and make-the-correct-path-easy:
one tested host core a binding drives, with netlayer and loop ownership visible
at the boundary that performs them.

## Decision

**The C ABI gains `libpancake_driver`, a sans-io projection of `driver.core.Host`
with two host-configurable seams.** A binding drives one shared host core
instead of re-implementing the tier; `src/driver/core/host.zig` is the authority the
archive wraps, and `src/c_abi/driver` is the new root. The archive is named
after its Zig module, consistent with `net` →
`libpancake_net`, and `ocapn` → `libpancake_ocapn`; `Host` is a type inside the
module, not the archive's name.

**The embedder owns its transports outright; the seam is a pull-based action
queue, not callback vtables.** The embedder opens connections against its own
sockets and registers each with the host (`pancake_host_session_open_dialed_locator` /
`_open_accepted`, which sign the keyed hello under the host identity), then
moves bytes: `pancake_host_session_feed_bytes` for a raw byte stream the core
delimits internally (or `_feed` for an embedder whose transport already hands
whole frames), `pancake_host_session_take_outbound` for what it must write. Every
host effect surfaces through one pollable queue, `pancake_host_next_action`:
`DIAL` (open a connection to the named exporter — the action carries the full
locator URI and its parsed transport/designator/direct-address-hint views —
then report `pancake_host_dialed` / `_dial_failed` with the core-minted
ticket), `FLUSH` (drain that connection's outbound), `NEED_GIFT_ID` (draw
32 bytes of entropy into `pancake_host_provide_gift_id`), and `SETTLE`/`FAIL`
(a vow's outcome, its `ticket` the vow id — see the third amendment). The one
loop rule: after any top-level call, drain the queue. This is simpler than
the callback design first drafted here — no netlayer vtable, no `schedule` or
`set_read_paused` callbacks, no blocking `run`, no built-in-netlayer mode —
and the first binding rewire proved the dropped callbacks were never needed:
backpressure is inherent in a pull-based pump, and a blocking mode belongs to
the loop's owner, not the library.

**The core owns frame delimiting end to end.** `feed_bytes` threads the same
engine stream-prefix path the socket tier uses, so the frame-boundary scan,
both codecs' grammars, and the `FRAME_TOO_LARGE` cap live in one place — an
embedder never parses hostile bytes. Zig's `tcp`/`iroh` netlayers remain the
stream-shaped residents of ADR-0043/0062, untouched; the byte-fed seam is not
a rewrite of the stream contract.

**A published actor is embedder-hosted behavior, hosted through `spawnHosted`.**
Hosting an actor over this archive reuses ADR-0071's hosted-actor contract:
`Vat.spawnHosted` takes an opaque `ctx` and a behavior `(ctx, turn, verb, args)
-> reply | forward` (`HostedActor`, ADR-0079 vocabulary), and the driver core
spawns published actors that way. The
contract is shared by layout, not duplicated, so a behavior hosts identically
whether spawned in a local vat or published on a connection. A separate
bare-vat archive is therefore not the path a binding takes to host actors;
ADR-0071's interim archive is retired by this ADR's supersession (see the
Amendment), its `spawnHosted` foundation consumed here.

**A browser is this core in `wasm32` with a WebSocket netlayer.** Because the
core is sans-io it compiles to WebAssembly (as ADR-0070 established for the
Peer/Node core), so the browser binding drives `pancake_host_*` from JS with a
byte-fed WebSocket netlayer — JS owns the socket, feeds bytes, honors
`schedule` as `queueMicrotask` — instead of driving the raw `Peer`. This is the
same JS-owns-the-socket pattern ADR-0070 chose, lifted to the host tier.

**Placement follows ADR-0059.** `libpancake_driver` exports the `pancake_host_*`
family (plus its own `pancake_host_last_error`): the archive is named for its
Zig module, as `actors`/`net`/`ocapn` are, while the function family reads for
its entry type `Host`, the same divergence `libpancake_net_transport_tcp` →
`pancake_tcp_*` already carries. It imports `driver` and `c_abi_shared`, reuses
the shared value vocabulary by layout, is symbol-disjoint, and sits outside the
layer DAG (`.graph = false`) like the transport archives. It is an adapter tier
above the sans-io core, never inside it.

## Scope (what this does not decide)

- **Nothing here is implemented.** There is no `libpancake_driver` archive, no
  `src/c_abi/driver`, and no byte-fed drive of `driver.core.Host`.
- **No `tcp`/`iroh` rewrite.** The stream netlayer contract of ADR-0043/0062
  stands; the byte-fed form is additive and used by host-supplied transports and
  the Zig-owned-mode bridge only.
- **ADR-0071's bare-vat archive is superseded, its foundation consumed.** This
  ADR takes over its increment 3: bindings rewire onto `libpancake_driver`,
  not onto a bare vat archive. The `Vat.spawnHosted` foundation (ADR-0071
  increment 1) is the hosting contract this archive reuses; the interim C
  archive (increment 2) was held unconsumed against a possible network-free
  local-vat consumer until none materialized, then retired (see the
  Amendment).
- **ADR-0070's raw-Peer wasm path is not retired.** This offers a higher seam
  that ADR-0070's binding may adopt to thin its JS orchestration; the raw path
  remains valid.
- **The first increment is ephemeral, keyed follows.** Increment A lands the
  byte-fed `Host`, the host-supplied netlayer, the two loop modes, and
  publish/fetch/call over ephemeral sessions — the plumbing and the reuse.
  Increment B adds the retained keyed identity and, with it, redeem/originate
  (the three-party handoff), the same ephemeral-first staging ADR-0062 proved
  for the C TCP session.

## Alternatives Considered

- **Keep re-implementing the host tier per binding.** Rejected: it is the
  drift this ADR exists to remove — the exact orchestration ADR-0068 tested
  once, re-written and re-drifted four times, none of it the tested code.
- **Expose only built-in transport archives, no host-supplied netlayer.**
  Rejected: a runtime that owns its transport (a browser, a Deno WebSocket, an
  `asyncio` socket) has no seam; the netlayer is configurable in Zig (ADR-0062)
  but not to a C consumer, which is the gap.
- **Rewrite `tcp`/`iroh` as byte-fed to unify one netlayer shape.** Rejected for
  now: large blast radius on a settled, tested contract for no consumer benefit,
  since the loop already bridges stream to feed in Zig-owned mode. The two forms
  coexist; unification is a later option, not a prerequisite.
- **Wrap `driver.core.Host` wholesale so Zig always owns the loop.** Rejected: it
  forecloses the bring-your-own-loop and browser cases, which are the reason the
  seam exists; the thinnest-binding convenience is the Zig-owned mode, offered
  beside the byte-fed one, not instead of it.
- **Retire the bare-vat archive immediately, in this same decision.**
  Deferred rather than rejected: the archive and its `spawnHosted` foundation
  were built and tested (ADR-0071 increments 1–2), and a network-free
  local-vat consumer might yet have wanted it, so it was kept unconsumed with
  the explicit condition that it be retired if no consumer materialized. The
  condition fired and the retirement is recorded in the Amendment; the
  behavior contract lives on in this archive.
- **Name the archive `libpancake_host` after the `Host` type.** Rejected: every
  other archive is named after its Zig module, not a type it exports;
  `libpancake_driver` keeps that convention and leaves `Host` the type it is.

## Consequences

- **A Zig prerequisite lands first: a byte-fed `Host`.** `Host` already carries
  the node, routing, redeem, and publish/fetch orchestration and is already
  caller-pumped; only its input edge reads the socket, in
  `HostConnection.stepReadable`. The one change lifts that read out — the caller
  (or a loop) feeds frame bytes, and `dial`/`write`/`close` route through the
  netlayer callbacks — so all the orchestration is reused unchanged. This
  *dissolves* the `docs/boundaries.md` split (`LoopHost` node-less, `Host`
  loop-less) rather than merging two types: once `Host` is byte-fed, a loop is
  simply whatever feeds it — `net.TcpLoop` for Zig-owned scale (the loop keeps the
  fan-out and buffer pool; the Host keeps node/redeem/vat), the binding's loop
  for bring-your-own, the browser's for wasm. ADR-0068's "growing the loop under
  the host" is exactly this: feed the byte-fed Host from `completion.Loop`, no
  node-carrying `LoopHost` required. `test/driver` gains a sans-io host scenario
  proving three-party handoff and loop scale over fed bytes.
- **The core must compile to `wasm32` free of `net`.** The vat, the node, and
  the byte-fed drive extract out from under the `net` completion loop, so a
  browser reaches the vat through the driver core without a socket loop. This is
  what makes a separate net-free actor archive unnecessary for the browser; the
  `cross_wasm` compile gate holds that extraction, which is what allowed the
  interim bare-vat archive's retirement (see the Amendment).
- **A new archive** `libpancake_driver` in `build.zig`'s `layer_table` and
  `archive_table` (`.graph = false`, `arch-check` claims the directory for file
  coverage and the I/O bans), with a reflected header and prose generator and a
  `gen-header-driver` / `gen-header-driver-check` gate, following the ADR-0059
  pattern. A `test/c_abi/driver_test.zig` exercises the two seams.
- **The bindings collapse their in-language host tier onto `pancake_host_*`.**
  The per-binding pump, redeem loop, publish/fetch, and promise bookkeeping
  retire; the `bindings-*` dogfoods extend, and a per-binding
  `bindings-driver-loop` proof (mirroring `bindings-iroh-loop`) shows each
  binding serving many connections through a host-supplied netlayer and its own
  loop.
- **ADR-0070's TypeScript wasm binding can sit on `pancake_host_*`** instead of
  the raw `Peer`/`Node`, and its Milestone 1 WebSocket transport becomes a
  host-registered byte-fed netlayer in the browser, not only a Zig resident on
  the server. The rooms web bridge retires against the driver core.
- **Docs move with the code:** `docs/architecture.md` gains the archive and the
  byte-fed netlayer form, `docs/boundaries.md` loses the retired boundary, and
  `docs/roadmap.md`/`docs/shipped.md` track the phases.

## Forward compatibility

The byte-fed netlayer seam is the shape every callback-driven transport plugs
into: a WebRTC DataChannel (ADR-0070 Milestone 2), a WebTransport stream, or any
future host-owned transport is a `PancakeNetlayer` registration, no core edit.
The `schedule` and `set_read_paused` callbacks are the stable contract a host
loop honors across TCP, WebSocket, and WebRTC, so a binding's loop integration
is written once against the seam, not per transport.

## Notes

- Projects [ADR-0068](ADR-0068-native-host-tier.md) (the Zig host tier) to the C
  ABI and executes its named direction of growing the loop under the host.
- Extends [ADR-0062](ADR-0062-one-connect-over-a-netlayer-slice.md)'s netlayer
  configurability from a Zig slice and built-in C transports to a host-supplied
  C netlayer.
- Supersedes [ADR-0071](ADR-0071-actor-layer-c-abi-archive.md): bindings
  rewire onto `libpancake_driver`, which hosts embedder behaviors through
  ADR-0071's `Vat.spawnHosted` / `HostedActor` (its increment 1, standing and
  consumed); its
  interim increment-2 C archive is retired (see the Amendment). The
  hosted-actor contract is shared with the vat through the `actors` Zig
  module.
- Gives [ADR-0070](ADR-0070-browser-binding-via-wasm.md) a higher seam than the
  raw `Peer`/`Node` for its wasm binding and WebSocket transport.
- Placement and symbol-disjointness follow
  [ADR-0059](ADR-0059-composable-c-abi-archives.md); the loop and backpressure
  posture follow [ADR-0057](ADR-0057-iroh-completion-loop-bridge.md) and
  [ADR-0042](ADR-0042-outbound-high-water-backpressure.md).

## Amendment (2026-07-10)

The bare-vat archive retention this decision originally carried resolved by
its own named exit condition: no network-free local-vat consumer materialized,
the byte-fed host landed with the sans-io core compiling for `wasm32` (the
wasm-fallback hedge discharged by the `cross_wasm` gate), and hosted objects
ride `Vat.spawnHosted` through `pancake_host_*` directly. The interim archive,
its header, and its export family are removed from the tree; this ADR now
supersedes ADR-0071, whose `spawnHosted` foundation stands consumed here. The
decision text above was updated in place to the resolved state. The Racket
binding's raw peer wrappers were removed with its host rewire — a binding ships
one surface (the host family) — while the raw `pancake_peer_*` family remains
covered by the Zig C-ABI tests and the C examples.

## Amendment (2026-07-10, second): the seam as shipped, and the decided calls

The Decision text above now describes the shipped seam (the action queue), not
the callback-vtable draft it replaced; the adversarial review of the first
binding rewire ratified the simplification. Three surface calls were decided
there rather than defaulted, for the next binding rewires: **vow-listener
fusion is adopted** at the next rewire (an optional callback on
`conn_send`/`vow_send`/`vow_index`/`vow_untag` fuses mint and listen into one
crossing, retiring the eager register-at-mint discipline); **a host-native
caretaker is held** (ADR-0064 keeps forwarding proxies ordinary actors —
authorization policy stays above pancake); **an entropy callback is held**
(the `NEED_GIFT_ID` action keeps the queue uniform). The named next increment
was the blocking-tier collapse, since landed: the blocking tier's parallel
redeem executor and deferred-action machinery were deleted, its
crossed-hellos table merged into the byte-fed host core's, and the blocking
tier became a socket loop over that core, which carries the `Host` name in
`driver_core`. That blocking socket loop was later deleted: Zig multi-conn is
`driver.Bridge` + `completion.Loop` over the same core (ADR-0076).

## Amendment (2026-07-10, third): settlements ride the action queue

The second amendment's decided vow-listener fusion is superseded before it
ever lands: settle and fetch outcomes now ride the existing action queue as
`SETTLE`/`FAIL` kinds whose `ticket` is the vow id, and the callback settle
surface (`PancakeHostSettleCb`, `PancakeHostFetchCb`, `pancake_host_vow_send`)
is deleted from the C ABI. `pancake_host_session_fetch` and
`pancake_host_session_enliven` mint ids in the one vow space and return them
through an out param. Behaviors stay callbacks — a served deliver still needs
a synchronous reply — and the Zig host core's `vowOn` stays for in-process
consumers, whose listeners keep hearing resolutions borrowed and zero-copy.

The reasons, in order of force: the one loop rule stays one rule (a second
notification channel is a second thing a binding can forget); the node tier
already settled this way (`PANCAKE_NODE_ACTION_SETTLE`/`FAIL` — the host
tier's callback detour was the anomaly); the lifetime contract already
existed (host-owned, valid until the next `pancake_host_next_action`, the
DIAL locator's contract verbatim); and the three temporal traps —
register-before-feed, `AlreadyListening`, and the enliven cache hit's
fires-synchronously caveat — become unrepresentable rather than documented.
The fusion dissolves with the discipline it was patching. A vow with no
in-process listener pays one deep clone per settle at the byte boundary (the
named ledger entry in the memory rule); an unlistened settle can never
strand, because minting a vow reserves its completion's queue slot.

## Amendment (2026-07-11, fourth): the node-less tcp loop tier is retired

The Consequences' endpoint is executed: `driver.LoopHost` and
`driver.LoopDialer` (with `src/driver/loop.zig` and their two test files) are
deleted. They were the last serve orchestration outside the byte-fed core —
`Served`-per-connection with no node, so handoff was unreachable at that
tier — and their only consumers were their own tests: the iroh scale path
runs its own loop over the sidecar's readiness fd, and the bindings own
their loops over `pancake_host_*`. `net.completion.AfterEvents` is deleted
with its last consumer; the surviving hook seam (`make_conn_ctx`, `serve`,
`free_conn_ctx`, `on_close`) is net-tier vocabulary with net-tier tests. The
amplification verdict the loop tests pinned moves to a sans-io unit
(`test/driver/served_budget_test.zig`); the release-fires-broken contract
was already pinned over fed bytes.

The `net.TcpLoop` → byte-fed `Host` bridge shipped as ADR-0076 (`driver.Bridge`
over `completion.Loop`); the live-socket scale harness and iroh Bridge redeem
gate (`iroh-bridge-redeem`) are its consumers. ADR-0051's driver-tier sentence
("the driver exposes the client fan-out surface above the loop") was retired
with the old node-less loop tier; its net-tier decision — the backend
`startDial` and the one shared connection lifecycle for accepted and dialed
sockets — stands under `completion.Loop` / `net.TcpLoop`.

## Amendment (2026-07-12, fifth): opt-in embedder pump wrapper

The second amendment ratified the **pull-queue over callback vtables**. That
stands: `pancake_host_next_action` remains the normative C contract in
`pancake_driver.h`, and `examples/c/host_embedder_pump.c` remains a compiled
checklist of that choreography, not a new ABI.

This amendment authorizes an **optional convenience wrapper** — Zig-first under
`src/c_abi/driver/embedder_pump.zig`, C-exported only if a later slice proves
the export earns its keep — that still drains through
`pancake_host_next_action` internally and invokes embedder-supplied I/O hooks
(flush-write, close, dial, gift entropy, settle routing). It does **not**:

- replace the pull API or hide the one-loop rule,
- reintroduce a netlayer / `schedule` vtable as the primary seam,
- force an async-only model (Racket's sync `with-host-drain` stays a third
  spelling beside the async Host kick).

Bindings may thin their `pump` / `action` modules onto the wrapper later; they
may also keep owning the loop. Executor arm bodies (socket I/O, language
promise settlement) stay hand-written per language — the same lesson Pass 2
took for HostAction decode.

**Landed.** Zig helper `src/c_abi/driver/embedder_pump.zig`, C export
`pancake_host_pump_drain` + `PancakeHostPumpHooks`, and
`examples/c/host_embedder_pump.c` rewritten to call the export. Bindings keep
their hand-rolled drains (async dial / promise settlement / Racket sync lock).

## Amendment (2026-07-15, sixth): bindings adopt `pancake_host_pump_drain`

The fifth amendment authorized the opt-in wrapper; this amendment lands the
binding adoption. Every language action module drains through
`pancake_host_pump_drain` with **synchronous park-only arms** — decode and
append (or accumulate `drain-effects`), never await inside the C loop. Async
bindings (Python / TypeScript / Rust) await parked arms after the C call
returns; Racket keeps its sync `with-host-drain` spelling (flush / gift-id
under the host lock, dial / close / settle as post-lock fires).

The pull-queue remains normative: `pancake_host_next_action` stays the C
contract the wrapper pops internally, and `examples/c/host_embedder_pump.c`
still names it. Binding action modules must not hand-roll a
`pancake_host_next_action` pop loop — `zig build meta-check` refuses that
symbol in those four files and requires `pancake_host_pump_drain` instead.

**Landed.** All four bindings' action modules call `pancake_host_pump_drain`;
executor arm bodies (socket I/O, language promise settlement) stay hand-written
per language.