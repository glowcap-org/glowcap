---
id: ADR-0072
status: accepted
date: 2026-07-09
tags: [c-abi, driver, host, net, netlayer, loop, bindings, wasm, browser]
decision: "The C ABI projects `driver.core.Host` (ADR-0068) as a sans-io core every binding drives, so no binding re-implements the host tier. The embedder owns its transports and loop: it registers each connection, feeds inbound bytes, takes outbound frames, and drains one pull-based action queue (`glowcap_host_next_action`) after every top-level call. There is no netlayer vtable, scheduling callback, or blocking run. The sans-io core compiles to `wasm32`, so the browser binding drives the same core. The archive is `libglowcap_host` (ADR-0112) and exports only `glowcap_host_*`."
supersedes: [ADR-0071]
superseded_by: []
amends: []
amended_by: [ADR-0096, ADR-0100, ADR-0110, ADR-0112, ADR-0113]
---

# ADR-0072 The driver tier over the C ABI: host-configurable netlayers and loop

> **Amendments.** ADR-0100 amends the Host internals only: gifts and replay
> counters are session-owned. ADR-0110: `feed_bytes` accepts an outer-framed
> byte stream and retains an incomplete envelope across calls, while `_feed`
> accepts one bare codec frame from a message-framed transport. ADR-0079 and
> ADR-0096: CapTP multi-session product work is `Host` / `GlowcapHost` over
> `glowcap_host_*`, `GlowcapReference` is one opaque Host-scoped id, and the
> glowcap_node_* and raw peer C families are deleted. ADR-0112: the byte-fed
> archive is `libglowcap_host`, which owns `glowcap_host_*`.
> `libglowcap_driver` exports only `glowcap_driver_*`, adopts a quiescent Host
> through `glowcap_driver_take_host`, and starts with zero transports. Transport
> archives install provider packages through the standalone
> `glowcap_transport_provider.h` ABI. The byte-fed Host seam below is the
> primitive those records build on.

## Context

ADR-0068 built the native multi-connection tier, `driver.core.Host`: one identity,
one `engine.Node`, one crossed-hellos registry, and the redeem and origination
seams that make three-party handoffs work across many connections. It is
Zig-native and named the boundary it left standing: the single-connection
`connect`/`listen` tier below it, and the node-less, TCP-only
`LoopHost`/`LoopDialer` fan-out beside it.

Every language binding needs that same host tier. ADR-0066/0067 gave each
binding a three-party story by having its `connect` build a composite that owned
the retained identity, the gift registry, and the serve step. That composite is
`driver.core.Host`'s job, re-written in TypeScript, Python, Racket, and Rust on
top of the sans-io peer and node C families: the connection pump, the redeem
loop, the publish/fetch ergonomics, and the promise-to-answer bookkeeping, once
per language. The tested Zig tier (`test/driver/core_host/`) is not the code any
binding runs. This is the drift ADR-0059 removed for value vocabulary, one layer
up: shared behavior re-implemented instead of shared.

Two seams keep a binding from driving the Zig tier. ADR-0062 made a transport a
runtime vtable the driver dispatches by symbol, but exposed it to C only as
built-in transport archives (`libglowcap_net_transport_{tcp,inproc,iroh}`). A
C consumer links a transport and cannot supply one, so a runtime that owns its
transport (a Deno WebSocket, an `asyncio` socket, a browser tab with no socket)
has no way to plug it into the host tier. And the loop stays outside the
netlayer contract (ADR-0043/0062): a host that owns its loop could drive only a
single `Peer`, not the host tier. ADR-0070 makes the browser drive the raw
`Peer`/`Node` from JS because no higher seam exists.

This applies the core-boundary First Principle
([AGENTS.md](../../../AGENTS.md#first-principles)): the host core stays
deterministic and sans-io, and adapters own I/O and scheduling. One tested host
core is driven by every binding, with netlayer and loop ownership visible at the
boundary that performs them.

## Decision

**The C ABI projects `driver.core.Host` as a sans-io core that a binding
drives.** `src/driver/core/host.zig` is the authority the archive wraps. The
archive is named after its Zig module, and `Host` is a type inside it.

**The embedder owns its transports. The seam is a pull-based action queue.** The
embedder opens connections against its own sockets and registers each with the
host (`glowcap_host_session_open_dialed_locator` / `_open_accepted`, which sign
the keyed hello under the host identity), then moves bytes:
`glowcap_host_session_feed_bytes` for an outer-framed byte stream the core
delimits internally (or `_feed` for a transport that hands whole bare frames),
and `glowcap_host_session_take_outbound` for the bare frames it must write. The
byte-stream pump adds the outbound envelope. Every host effect surfaces through
one pollable queue, `glowcap_host_next_action`:

- `DIAL`: open a connection to the named exporter. The action carries the full
  locator URI and its parsed transport, designator, and direct-address-hint
  views. The embedder reports `glowcap_host_dialed` / `_dial_failed` with the
  core-minted ticket.
- `FLUSH`: drain that connection's outbound.
- `NEED_GIFT_ID`: draw 32 bytes of entropy into `glowcap_host_provide_gift_id`,
  or report `glowcap_host_gift_id_failed`. The failure breaks the claimed handoff
  in the Node, so an entropy failure cannot discard the only ticket able to
  settle it.
- `SETTLE` / `FAIL`: a vow's outcome, with the vow id as `ticket`.

The one loop rule: after any top-level call, drain the queue. Every
authority-bearing effect has a terminal report after it is popped. There is no
netlayer vtable, no `schedule` or `set_read_paused` callback, no blocking `run`,
and no built-in-netlayer mode. Backpressure is inherent in a pull-based pump,
and a blocking mode belongs to the loop's owner.

**Settlements ride the action queue.** `glowcap_host_session_fetch` and
`glowcap_host_session_enliven` mint ids in the one vow space and return them
through an out param. Settle and fetch outcomes arrive as `SETTLE`/`FAIL`
actions, so the one loop rule stays one rule and a second notification channel
cannot be forgotten. The action's lifetime is the DIAL locator's: host-owned,
valid until the next `glowcap_host_next_action`. Register-before-feed,
`AlreadyListening`, and the enliven cache hit that fires synchronously are
unrepresentable. A vow with no in-process listener pays one deep clone per settle
at the byte boundary (a named entry in the memory ledger). An unlistened settle
cannot strand, because minting a vow reserves its completion's queue slot.
Behaviors stay callbacks, since a served deliver needs a synchronous reply. The
Zig host core's `vowOn` stays for in-process consumers, whose listeners hear
resolutions borrowed and zero-copy.

**The core owns byte-stream delimiting.** `feed_bytes` threads the outer Syrup
ByteArray parser the socket tier uses. The envelope parser owns the message
boundary and frame cap. The active codec must consume the complete body as one
frame. An embedder never parses untrusted stream bytes. Zig's `tcp`/`iroh`
netlayers remain the stream-shaped residents of ADR-0043/0062, and the byte-fed
seam does not change that contract.

**A published actor is embedder-hosted behavior, hosted through `spawnHosted`.**
`Vat.spawnHosted` takes an opaque `ctx` and a behavior
`(ctx, turn, verb, args) -> reply | forward` (`HostedActor`, ADR-0079
vocabulary), and the driver core spawns published actors that way. The contract
is shared by layout with ADR-0071, so a behavior hosts the same way in a local
vat or published on a connection. This ADR supersedes ADR-0071's interim
bare-vat C archive, which no network-free local-vat consumer ever used. The
`spawnHosted` foundation stands and is consumed here.

**A browser is this core in `wasm32`.** The sans-io core compiles to
WebAssembly (ADR-0070), so the browser binding drives `glowcap_host_*` from JS
with a byte-fed WebSocket transport. JS owns the socket and feeds bytes. This is
the JS-owns-the-socket pattern of ADR-0070 lifted to the host tier. The
`cross_wasm` gate holds that the vat, the node, and the byte-fed drive compile
free of `net`, which is why no separate net-free actor archive exists.

**Archives are adapters outside the sans-io core.** `libglowcap_host` and
`libglowcap_driver` are symbol-disjoint, share C layouts rather than symbols, and
sit outside the layer DAG (`.graph = false`, ADR-0059). `arch-check` claims their
directories for file coverage and the I/O bans.

**An optional embedder pump wrapper.** `src/c_abi/host/embedder_pump.zig`
exports `glowcap_host_pump_drain` and `GlowcapHostPumpHooks`. It drains through
`glowcap_host_next_action` internally and invokes embedder hooks (flush-write,
close, dial, gift entropy, settle routing). It does not replace the pull API, does
not reintroduce a netlayer or `schedule` vtable as the primary seam, and does not
force an async-only model. `examples/c/host_embedder_pump.c` calls the export, and
`glowcap_host_next_action` remains the normative C contract in
`glowcap_driver.h`. Python, Rust, and Racket drain through the wrapper with
synchronous park-only arms: decode and append, never await inside the C loop.
Async bindings await parked arms after the pop loop returns. Racket keeps its
sync `with-host-drain` form (flush and gift-id under the host lock, dial, close,
and settle as post-lock fires). TypeScript drains the pull queue directly
because browser Wasm has no general C-callback seam. Executor arm bodies (socket
I/O, language promise settlement) are hand-written per language.
`zig build source-check` requires the wrapper in Python, Rust, and Racket and
holds TypeScript's pull loop to the same generated action inventory.

## Scope (what this does not decide)

- **No `tcp`/`iroh` rewrite.** The stream netlayer contract of ADR-0043/0062
  stands. The byte-fed form is used by host-supplied transports and the
  Zig-owned-mode bridge only.
- **ADR-0070's raw-Peer wasm path stays valid.** This offers a higher seam its
  binding may adopt to thin its JS orchestration.
- **A host-native caretaker is not provided.** ADR-0064 keeps forwarding proxies
  ordinary actors, and authorization policy stays above glowcap.
- **An entropy callback is not provided.** `NEED_GIFT_ID` keeps the queue
  uniform.
- **The node-less TCP loop tier does not exist.** `driver.LoopHost`,
  `driver.LoopDialer`, and `net.completion.AfterEvents` are deleted. They served
  each connection without a node, so handoff was unreachable there. The
  net-tier hook seam (`make_conn_ctx`, `serve`, `free_conn_ctx`, `on_close`)
  stands with net-tier tests, and the amplification verdict is pinned in
  `test/driver/served_budget_test.zig`. Zig multi-connection work is
  `driver.Bridge` over `completion.Loop` (ADR-0076), and the iroh scale path
  runs its own loop over the sidecar's readiness fd. ADR-0051's net-tier
  decision, the backend `startDial` and one shared connection lifecycle for
  accepted and dialed sockets, stands under `completion.Loop` / `net.TcpLoop`.

## Alternatives Considered

- **Keep re-implementing the host tier per binding.** Rejected: it is the drift
  this ADR removes, with orchestration ADR-0068 tested once and re-written four
  times.
- **Expose only built-in transport archives.** Rejected: a runtime that owns its
  transport has no seam.
- **Callback netlayer vtables with `schedule`, `set_read_paused`, and a blocking
  `run`.** Rejected: the first binding rewire showed the callbacks were never
  needed.
- **Fuse mint and listen into one crossing with an optional callback on
  `conn_send`/`vow_send`/`vow_index`/`vow_untag`.** Rejected in favor of
  settlements on the action queue, which removes the discipline the fusion
  patched.
- **Rewrite `tcp`/`iroh` as byte-fed to unify one netlayer shape.** Rejected:
  large blast radius on a settled contract for no consumer benefit, since the
  loop already bridges stream to feed in Zig-owned mode.
- **Wrap `driver.core.Host` wholesale so Zig always owns the loop.** Rejected: it
  forecloses the bring-your-own-loop and browser cases that motivate the seam.
  Zig-owned mode is offered beside the byte-fed one.

## Consequences

- `Host` is byte-fed: its input edge no longer reads the socket
  (`HostConnection.stepReadable`). The caller or a loop feeds frame bytes, and
  `dial`/`write`/`close` route through the netlayer callbacks, so all the
  orchestration is reused. A loop is whatever feeds the Host: `completion.Loop`
  for Zig-owned scale (the loop keeps the fan-out and buffer pool, the Host keeps
  node, redeem, and vat), the binding's loop for bring-your-own, the browser's
  for wasm. `test/driver` holds a sans-io host scenario for three-party handoff
  and loop scale over fed bytes.
- The bindings' in-language host tier collapses onto `glowcap_host_*`. The
  per-binding pump, redeem loop, publish/fetch, and promise bookkeeping are gone.
  A per-binding `bindings-driver-loop` proof (mirroring `bindings-iroh-loop`)
  shows each binding serving many connections through a host-supplied transport
  and its own loop.
- ADR-0070's TypeScript wasm binding can sit on `glowcap_host_*` instead of the
  raw `Peer`/`Node`, and its WebSocket transport is a host-registered byte-fed
  transport in the browser.
- Any future callback-driven transport (a WebRTC DataChannel, a WebTransport
  stream) integrates by feeding bytes and draining the queue, with no core edit.
- `docs/architecture.md` and `docs/boundaries.md` describe the byte-fed form and
  no longer list the retired `LoopHost` boundary.

## Notes

- Projects [ADR-0068](ADR-0068-zig-host-tier.md) to the C ABI and executes its
  named direction of growing the loop under the host.
- Extends [ADR-0062](ADR-0062-one-connect-over-a-netlayer-slice.md)'s netlayer
  configurability from a Zig slice and built-in C transports to a host-supplied
  transport.
- Supersedes [ADR-0071](ADR-0071-actor-layer-c-abi-archive.md): bindings rewire
  onto the Host family, which hosts embedder behaviors through ADR-0071's
  `Vat.spawnHosted` / `HostedActor`.
- Gives [ADR-0070](ADR-0070-browser-binding-via-wasm.md) a higher seam than the
  raw `Peer`/`Node`.
- Placement and symbol-disjointness follow
  [ADR-0059](ADR-0059-composable-c-abi-archives.md). The loop and backpressure
  posture follow [ADR-0057](ADR-0057-iroh-completion-loop-bridge.md) and
  [ADR-0042](ADR-0042-outbound-high-water-backpressure.md).
