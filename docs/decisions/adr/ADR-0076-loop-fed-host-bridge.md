---
id: ADR-0076
status: accepted
date: 2026-07-11
tags: [driver, net, host, completion-loop, handoff]
decision: "Feed the byte-fed Host from a completion loop through a translator (`driver.Bridge`): adoption via Host.openAcceptedOver / openDialedOver, per-event serving via Host.serveEvent, cross-connection flushes via Loop.armOutbound, and a budgeted drive whose breach condemns the flooded connection and queues a close action. TCP uses `net.TcpLoop`; iroh uses `completion.Loop(iroh.Backend, iroh.DialResolver)`: one CapTP spine (ADR-0057). Outbound dials use `Loop.dialLocator` over OCapN locator parts; a netlayer `Locator` owns resolve, the Backend owns `startDial` (platform Backends are connect-only). `Loop.dial` is private."
supersedes: []
superseded_by: []
---

# ADR-0076 The loop-fed host bridge

## Context

ADR-0072's fourth amendment retired the node-less loop tier and named the
landing condition for its replacement: the `net.TcpLoop` / `completion.Loop` to byte-fed
`driver_core.Host` bridge lands together with its two real mechanisms,
cross-connection outbound arming and a budgeted byte feed: and its first
consumer, the live-socket scale harness. That condition is met here.

The prior tier died because it wrapped: a `Served` per connection with no
node, so handoff was unreachable. The lesson this ADR encodes is the
opposite shape. Every decision on this path already has one owner,
`Host.drainWork` decides what to flush and when a connection is condemned,
`Loop.flushOutbound` decides how bytes reach a socket, `Served.drivePostBatch`
decides how much a batch may amplify: so the bridge must be a *translator*
that adds only the verbs letting those owners reach each other, never a
wrapper that re-makes their decisions. Engages the First Principles on the
sans-io core (the host stays byte-fed and I/O-banned; the loop stays
protocol-blind) and on performance as contract (one loop thread, many
connections, the ladder's fan-out posture).

## Decision

Three verbs and one carrier, each at the layer that owns it:

- **`Host.openAcceptedOver` (`src/driver/core/host.zig`)** adopts a peer the
  embedder owns and pins (`engine.Node.registerConnOver` underneath) with
  the identical keyed-responder wiring `openAccepted` has, minus ownership:
  the node and host never free an adopted peer; the embedder frees it after
  `releaseConn`. `Host.serveEvent` is the per-event feed verb for an
  embedder that polls its peers itself: structurally `pumped` for one event,
  with the callback latch and the node pump a raw `Served.serveEvent` would
  skip. Its unwind consumes the events still queued behind the one it was
  handed, so a loop's per-event hook fires once per inbound batch.
- **`Loop.armOutbound(slot)` (`src/net/completion/loop.zig`)** is the
  cross-connection arm: encode and submit whatever is queued on `slot`'s
  peer, callable mid-dispatch while the loop serves a different connection.
  Single-threaded loop, `write_in_flight` prevents a double submit, and
  ADR-0042 parking engages at that connection's next `armOrPark`: the net
  test pins that cross-armed bytes ride the same queue accounting.
  `Loop.closeSlot(slot)` is the matching "flush the projected abort, then
  close" entry.
- **`Served.local_turn_budget` / `Host.Options.local_turn_budget`
  (`src/driver/core/served.zig`)** cap local-turn amplification per drive
  through the existing `drivePostBatch` verdict. Attribution is the sharp
  edge: a breach inside the fed connection's own latched dispatch keeps
  `failDispatch` semantics (that feed fails); a breach discovered in the
  pump belongs to the connection whose vat amplified: possibly a sibling of
  the fed one: which is condemned with a typed `resource_exhausted` abort
  while the fed verb succeeds. A condemned connection's vat is never driven
  again; its queued abort still encodes and flushes.
- **`HostAction.close`** is the embedder signal that carries the verdict
  out: flush the condemned connection's queued abort, close its transport,
  release the shell. Without it a byte-fed embedder cannot learn the host
  condemned a connection mid-pump. `condemned` alone only refuses future
  verbs. Mirrored end to end as `PANCAKE_HOST_ACTION_CLOSE` and an arm in
  every binding's action drain.

`driver.Bridge` (`src/driver/bridge.zig`) composes them: the loop's
hooks adopt (`makeConnCtx`), serve (`serve`), and release (`freeConnCtx`),
and every entry point ends by draining the host's action queue into the loop
`flush` becomes `armOutbound`, `close` becomes `closeSlot`,
`need_gift_id` draws at the driver tier's entropy boundary, `dial` is
refused fail-closed. Publishing runs at adoption (`driver_core.Publish`),
before any inbound frame is served, so a partner's first fetch cannot race
the registration. The consumers land with it: the
three-party-handoff-across-one-loop test (the deposit leaves on a connection
only `armOutbound` can reach) and the `zig build tcp-loop` scale harness.

## Scope (what this does not decide)

- ~~**No loop-global fan-in backpressure.**~~ **Amended (ADR-0082).** ADR-0042
  remains the per-connection default; opt-in `fan_in_throttle` and
  `park_kill_ms` on `completion.Loop.Options` are the loop-global controls.
- ~~**The iroh `LoopHost` is not converged.**~~ **Converged (amendment
  below).** `iroh.LoopHost` is deleted; iroh scale is
  `completion.Loop(iroh.Backend, iroh.DialResolver)` + `driver.Bridge` + Host.
- ~~**No deadline on blocking answer-waits.**~~ **Shipped (amendment
  below).** `BlockingSession.settle_timeout_ms` / `SessionOptions.settle_timeout_ms`
  and `Loop.runUntil(…, deadline_ms)` bound post-handshake waits; the handshake
  budget remains `handshake_timeout_ms` (not a phantom `finishOpen`).

## Amendment: settle / `runUntil` deadlines

Blocking answer-waits no longer park forever on a partner that opens then
stalls. `BlockingSession.settle_timeout_ms` (default `0` = unbounded) is a
wall-clock budget for `settle` / `call` / `fetch`; expiry returns
`Error.WaitTimedOut` after breaking the stack-bound far listener.
`SessionOptions.settle_timeout_ms` threads the same knob onto owned
`Session`/`Server` paths. Completion-`Loop.runUntil` takes `deadline_ms`
(same `0` = unbounded convention) and returns `error.Timeout` when the flag
is still clear at the deadline. Backends' `poll` accepts a millisecond
timeout so the loop can wake to check it. Gated by the silent-partner settle
scenario in `test/driver/blocking_session_test.zig`.

## Amendment: loop-side dial executor

A bridged host redeems three-party handoffs on one loop thread. `Exec.dial`
borrows the pending dial view (`Host.pendingDial(ticket)`: no re-parse) and
forwards transport / designator / hint through `Loop.dialLocator`; the Loop's
`Locator` resolves them into the Backend's `ConnectTarget` and the Backend
`startDial`s. The bridge parks only the node's ticket under the slot
(`OutboundConnect.redeem`) until connect completes; adoption re-borrows the
view for `Host.openDialedOver`. Session open reports `exporterDialed`; refused
connect fires `on_close(slot, …, opened=false)` and `dialFailed`. Netlayers
own networking (`tcp.DialResolver.resolve`; iroh's `Locator` resolves node-id
designators); Bridge stays above that boundary. Gated by the redeem theorem in
`test/driver/bridge_test.zig`.


## Amendment: iroh Backend convergence

`iroh.LoopHost` is deleted. The sidecar readiness fd + try-I/O adapt through
`iroh.Backend` (same Backend contract as io_uring/kqueue), so CapTP fan-out
rides `driver.Bridge` + `driver_core.Host` for both TCP and iroh. `Bridge` is
generic over the loop type (`Bridge(net.TcpLoop)` /
`Bridge(Loop(iroh.Backend, iroh.DialResolver))`).
Gated by `zig build iroh-loop`. Iroh redeem dial
(`Loop.dialLocator` to `iroh.DialResolver.resolve` to `startDial`) ships
on the same bridge; gated by `zig build iroh-bridge-redeem`.

## Amendment: Backend-owned dial translation

Each completion Backend owns dial *start* end to end: an associated
`ConnectTarget` type, `startDial` (mint handle if needed, submit connect, clean
up on failure), and required `shutdownFd`. OCapN locator resolve is a separate
comptime `Locator` on `completion.Loop(Backend, Locator)`. `tcp.DialResolver` or
`iroh.DialResolver`, never a platform Backend concern. Platform Backends
(io_uring/kqueue) speak only `IpAddress` connect ops. `net.TcpLoop` is
`completion.Loop(platform, tcp.DialResolver)`. There is no shared `ConnectTarget`
union, no forwarding TCP Backend wrapper, no public `Loop.dial(ConnectTarget)`,
no socket-shaped `openDialFd`/`submitDial` Loop choreography, and no `@hasDecl`
soft optionality,
`validateBackend` / `validateLocator` compile-check the total contract. Above
the net boundary, callers (including Bridge) speak only
`Loop.dialLocator(transport, designator, hint)`. Blocking residents use the
same `Locator.resolve` before connect (`tcp_keyed` / `iroh` `residentDial`);
transport symbols and `direct-addresses` live in `model.transport`.

## Alternatives Considered

- **A wrapping loop tier owning per-connection serve state**: rejected,
  that was the retired shape; node-less, so handoff was unreachable, and it
  duplicated decisions the host already owns.
- **Loop-owned peers handed to the host by value**: rejected: the loop's
  fixed slots hold each peer inline at a stable address, and
  `registerConnOver` exists precisely so adoption never moves or re-owns a
  peer.
- **Failing the fed verb on any budget breach**: rejected: the fed
  connection's work can flood a sibling, and closing the messenger punishes
  the wrong session while the flooded vat keeps its runaway queue.

## Consequences

- `test/driver/core_host_budget_test.zig` pins the attribution contract;
  `test/driver/core_host_adopt_test.zig` pins adoption ownership and the
  batch-consumption subtlety; `test/net/completion_cross_arm_test.zig` pins
  the cross-arm at the net layer; `test/driver/bridge_test.zig` holds
  the theorem and the budget runaway over real sockets. Multi-party teardown
  uses `Loop.runUntil` then `closeAndDrain` so armed recvs retire before `deinit`.
- `zig build tcp-loop` is the live scale step (measured footprint printed,
  never gated. ADR-0073 owns the wall-clock rationale).
- The bridge's retained allocations (shells and the ConnId-to-slot map) are
  ledgered in the memory rule; `completion.MakeConnCtx` carries the slot so
  cross-connection verbs have a handle.

## Notes

ADR-0042 (outbound backpressure), ADR-0054 (shared read pool), ADR-0100
(session-owned gift authority and parked withdraws), ADR-0066/0069 (node routing and
tokens), ADR-0072 (the byte-fed host and the retired loop tier), ADR-0073
(why live-harness figures print rather than gate).
