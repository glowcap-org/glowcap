---
id: ADR-0076
status: accepted
date: 2026-07-11
tags: [driver, net, host, completion-loop, handoff]
decision: "Feed the byte-fed Host from a completion loop through a translator (`driver.Bridge`): adoption via Host.openAcceptedAdvertisedOver / openDialedOver, per-event serving via Host.serveEvent, cross-connection flushes via Loop.armOutbound, and a budgeted drive whose breach condemns the flooded connection and queues a close action. TCP uses `net.TcpLoop`. iroh uses `completion.Loop(iroh.Backend, iroh.DialResolver)`: one CapTP spine (ADR-0057). Outbound dials use `Loop.dialLocator` over OCapN locator parts. A netlayer `DialResolver` owns resolve, the Backend owns `startDial` (platform Backends are connect-only). `Loop.dial` is private."
supersedes: []
superseded_by: []
amended_by: [ADR-0113]
---

# ADR-0076 The loop-fed host bridge

## Context

ADR-0072 retired the node-less loop tier, a `Served` per connection with no
node, which made handoff unreachable. Its replacement is the `net.TcpLoop` /
`completion.Loop` to byte-fed `driver_core.Host` bridge, with two mechanisms
(cross-connection outbound arming and a budgeted byte feed) and a first
consumer, the live-socket scale harness.

Every decision on this path has one owner. `Host.drainWork` decides what to
flush and when a connection is condemned, `Loop.flushOutbound` decides how
bytes reach a socket, and `Served.drivePostBatch` decides how much a batch may
amplify. The bridge is a translator that adds only the verbs letting those
owners reach each other, and it re-makes none of their decisions.

## Decision

Three verbs and one carrier, each at the layer that owns it:

- **`Host.openAcceptedAdvertisedOver` (`src/driver/core/host.zig`)** adopts a
  peer the embedder owns and pins (`engine.Node.registerPeerOver` underneath)
  with the same responder wiring `openAcceptedAdvertised` has, minus ownership:
  the node and host never free an adopted peer. The embedder frees it after
  `releaseSession`. `Host.serveEvent` is the per-event feed verb for an
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
  through the existing `drivePostBatch` verdict. Attribution matters: a breach
  inside the fed connection's own latched dispatch keeps `failDispatch`
  semantics (that feed fails). A breach discovered in the pump belongs to the
  connection whose vat amplified: possibly a sibling of the fed one: which is
  condemned with a typed `resource_exhausted` abort while the fed verb succeeds.
  A condemned connection's vat is never driven again. Its queued abort still
  encodes and flushes.
- **`HostAction.close`** is the embedder signal that carries the verdict
  out: flush the condemned connection's queued abort, close its transport,
  release the shell. Without it a byte-fed embedder cannot learn the host
  condemned a connection mid-pump. `condemned` alone only refuses future
  verbs. Mirrored end to end as `GLOWCAP_HOST_ACTION_CLOSE` and an arm in
  every binding's action drain.
- **`HostAction.resume_work`** is the continuation signal for a finite
  `host_work_quantum`. A quantum may end with Node actions, handoff changes, or
  dirty session work remaining. When no ordinary action already wakes the next
  drain, the Host deduplicates one host-global resume notice. Consuming that
  notice ends the current drain turn. Completion-loop embedders resume through
  `Options.on_loop_turn`, which forces one nonblocking backend poll between
  Host slices. Async language bindings yield through their native scheduler.
  The action carries no session, ticket, bytes, or I/O operation and is
  mirrored as `GLOWCAP_HOST_ACTION_RESUME`.

`driver.Bridge` (now `driver.HostRuntime` in `src/driver/host_runtime.zig`) composes them: the loop's
hooks adopt (`makeConnCtx`), serve (`serve`), and release (`freeConnCtx`),
and every entry point ends by draining the host's action queue into the loop
`flush` becomes `armOutbound`, `close` becomes `closeSlot`,
`need_gift_id` draws at the driver tier's entropy boundary, `dial` is
refused fail-closed. Publishing runs at adoption (`driver_core.Publish`),
before any inbound frame is served, so a partner's first fetch cannot race
the registration. The consumers land with it: the
three-party-handoff-across-one-loop test (the deposit leaves on a connection
only `armOutbound` can reach) and the `zig build tcp-loop` scale harness.

The loop and Host are unsynchronized single-owner objects, but ownership is
sequential rather than permanently tied to the first OS thread. Every public
loop drive releases its thread claim at the quiescent return boundary and calls
the Bridge's ownership-transfer hook on that same thread. A caller may join a
background drive and then tear down or resume the pair from its own thread.
Touching either object while the drive is still running remains a data race.

## Scope (what this does not decide)

- **Loop-global fan-in backpressure** is opt-in (ADR-0082). ADR-0042 is the
  per-connection default. `fan_in_throttle` and `park_kill_ms` on
  `completion.Loop.Options` are the loop-global controls.
- **iroh scale** is `completion.Loop(iroh.Backend, iroh.DialResolver)` +
  `driver.Bridge` + Host. There is no `iroh.LoopHost`.
- **Blocking answer-waits have deadlines.** `BlockingSession.Options.settle`,
  `SessionOptions.settle`, and the completion loop's run deadline bound
  post-handshake waits. Keyed handshakes use the sibling `handshake` budget.

## Settle and `runUntil` deadlines

Blocking answer-waits do not park forever on a partner that opens then stalls.
`BlockingSession.Options` requires callers to choose both `handshake`
and `settle` budgets before construction. `SessionOptions` requires the same
pair for owned `Session`/`Server` paths. A caller that means forever spells
`.unbounded`. Settle expiry returns `Error.WaitTimedOut` after
breaking the stack-bound far listener. The completion loop's run deadline
returns `error.Timeout` when its flag is still clear at expiry, and backend
polling accepts a timeout so the loop can wake to check it. Gated by the
silent-partner settle scenario in `test/driver/session_fault_test.zig`.

## Loop-side dial executor

A bridged host redeems three-party handoffs on one loop thread. `Exec.dial`
borrows the pending dial view (`Host.pendingDial(ticket)`: no re-parse) and
forwards transport / designator / hint through `Loop.dialLocator`. The Loop's
`DialResolver` resolves them into the Backend's `ConnectTarget` and the Backend
`startDial`s. The bridge parks only the node's ticket under the slot
(`OutboundConnect.redeem`) until connect completes. Adoption re-borrows the
view for `Host.openDialedOver`. Session open reports `exporterDialed`. Refused
connect fires `on_close(slot, …, opened=false)` and `dialFailed`. Netlayers
own networking (`tcp.DialResolver.resolve`, iroh's `DialResolver` resolves node-id
designators). Bridge stays above that boundary. Gated by the redeem theorem in
`test/driver/host_runtime_handoff_test.zig`.

## iroh Backend

The sidecar readiness fd + try-I/O adapt through
`iroh.Backend` (same Backend contract as io_uring/kqueue), so CapTP fan-out
rides `driver.Bridge` + `driver_core.Host` for both TCP and iroh. `Bridge` is
generic over the loop type (`Bridge(net.TcpLoop)` /
`Bridge(Loop(iroh.Backend, iroh.DialResolver))`).
Gated by `zig build iroh-loop`. Iroh redeem dial
(`Loop.dialLocator` to `iroh.DialResolver.resolve` to `startDial`) rides the same
bridge, gated by `zig build iroh-redeem`.

## Backend-owned dial translation

Each completion Backend owns dial *start* end to end: an associated
`ConnectTarget` type, `startDial` (mint handle if needed, submit connect, clean
up on failure), and required `shutdownFd`. OCapN locator resolve is a separate
comptime `DialResolver` on `completion.Loop(Backend, DialResolver)`. `tcp.DialResolver`,
`iroh.DialResolver`, or `keyed_relay.DialResolver`, never a platform Backend
concern. Platform Backends (io_uring/kqueue) speak only `IpAddress` connect ops.
`net.TcpLoop` is `completion.Loop(platform, tcp.DialResolver)`. `net.KeyedRelayLoop`
is a composite backend over the same platform backend: TCP stays
delegated, while keyed-relay dials are WebSocket state machines below the Loop
contract, so Bridge still speaks one `dialLocator` surface. There is no public
`Loop.dial(ConnectTarget)`, no socket-shaped `openDialFd`/`submitDial` Loop
choreography, and no `@hasDecl` soft optionality.
`validateBackend` / `validateDialResolver` compile-check the total contract. Above
the net boundary, callers (including Bridge) speak only
`Loop.dialLocator(transport, designator, hint)`. Blocking residents use the
same `DialResolver.resolve` before connect (`tcp_keyed` / `iroh` `residentDial`).
Transport symbols and `direct-addresses` live in `model.transport`.

Completion adapters compose below that contract. Each layer derives disjoint
synthetic-handle, private-`user_data`, and receive-token tags from the wrapped
backend's `adapter_depth`. A second adapter cannot consume the first one's
completion or recycle its buffer. `iroh.CompletionBackend(Platform)` feeds its
sidecar readiness and stopper descriptors through `Platform` and delegates
non-iroh targets to it. `rooms-peer` wraps `net.KeyedRelayBackend` this way, so
its room leg and direct iroh/keyed-relay legs share one Loop connection ceiling
and one Bridge action map. A transport the Loop cannot resolve fails at
`dialLocator`, so the Bridge has no second I/O lifecycle outside Loop admission.

## Alternatives Considered

- **A wrapping loop tier owning per-connection serve state**: rejected. It is
  node-less, so handoff is unreachable, and it duplicates decisions the host
  owns.
- **Loop-owned peers handed to the host by value**: rejected: the loop's
  fixed slots hold each peer inline at a stable address, and
  `registerPeerOver` exists precisely so adoption never moves or re-owns a
  peer.
- **Failing the fed verb on any budget breach**: rejected: the fed
  connection's work can flood a sibling, and closing the messenger punishes
  the wrong session while the flooded vat keeps its runaway queue.

## Consequences

- `test/driver/core_host_budget_test.zig` pins the attribution contract.
  `test/driver/core_host_adopt_test.zig` pins adoption ownership and the
  batch-consumption subtlety. `test/net/completion/cross_arm_test.zig` pins
  the cross-arm at the net layer. `test/driver/host_runtime_handoff_test.zig` holds
  the theorem and `test/driver/served_budget_test.zig` the budget runaway. Multi-party teardown
  uses `Loop.runUntil` then `closeAndDrain` so armed recvs retire before `deinit`.
- `zig build tcp-loop` is the live scale step (measured footprint printed,
  never gated. ADR-0073 owns the wall-clock rationale).
- The bridge's retained allocations (shells and the ConnId-to-slot map) are
  ledgered in the memory rule. `completion.MakeConnCtx` carries the slot so
  cross-connection verbs have a handle.

## Notes

ADR-0042 (outbound backpressure), ADR-0054 (shared read pool), ADR-0100
(session-owned gift authority and parked withdraws), ADR-0066/0069 (node routing and
tokens), ADR-0072 (the byte-fed host and the retired loop tier), ADR-0073
(why live-harness figures print rather than gate).
