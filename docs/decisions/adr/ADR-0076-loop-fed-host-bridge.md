---
id: ADR-0076
status: accepted
date: 2026-07-11
tags: [driver, net, host, completion-loop, handoff]
decision: "Feed the byte-fed Host from the TCP completion loop through a translator (driver.LoopBridge): adoption via Host.openAcceptedOver, per-event serving via Host.serveEvent, cross-connection flushes via Loop.armOutbound, and a budgeted drive whose breach condemns the flooded connection and queues a close action."
supersedes: []
superseded_by: []
---

# ADR-0076 The loop-fed host bridge

## Context

ADR-0072's fourth amendment retired the node-less loop tier and named the
landing condition for its replacement: the `net.Loop` → byte-fed
`driver_core.Host` bridge lands together with its two real mechanisms —
cross-connection outbound arming and a budgeted byte feed — and its first
consumer, the live-socket scale harness. That condition is met here.

The prior tier died because it wrapped: a `Served` per connection with no
node, so handoff was unreachable. The lesson this ADR encodes is the
opposite shape. Every decision on this path already has one owner —
`Host.drainWork` decides what to flush and when a connection is condemned,
`Loop.flushOutbound` decides how bytes reach a socket, `Served.drivePostBatch`
decides how much a batch may amplify — so the bridge must be a *translator*
that adds only the verbs letting those owners reach each other, never a
wrapper that re-makes their decisions. Engages the First Principles on the
sans-io core (the host stays byte-fed and I/O-banned; the loop stays
protocol-blind) and on performance as contract (one loop thread, many
connections, the ladder's fan-out posture).

## Decision

Three verbs and one carrier, each at the layer that owns it:

- **`Host.openAcceptedOver` (`src/driver/core/host.zig`)** adopts a peer the
  embedder owns and pins — `engine.Node.registerConnOver` underneath — with
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
  ADR-0042 parking engages at that connection's next `armOrPark` — the net
  test pins that cross-armed bytes ride the same queue accounting.
  `Loop.closeSlot(slot)` is the matching "flush the projected abort, then
  close" entry.
- **`Served.local_turn_budget` / `Host.Options.local_turn_budget`
  (`src/driver/core/served.zig`)** cap local-turn amplification per drive
  through the existing `drivePostBatch` verdict. Attribution is the sharp
  edge: a breach inside the fed connection's own latched dispatch keeps
  `failDispatch` semantics (that feed fails); a breach discovered in the
  pump belongs to the connection whose vat amplified — possibly a sibling of
  the fed one — which is condemned with a typed `resource_exhausted` abort
  while the fed verb succeeds. A condemned connection's vat is never driven
  again; its queued abort still encodes and flushes.
- **`HostAction.close`** is the embedder signal that carries the verdict
  out: flush the condemned connection's queued abort, close its transport,
  release the shell. Without it a byte-fed embedder cannot learn the host
  condemned a connection mid-pump — `condemned` alone only refuses future
  verbs. Mirrored end to end as `PANCAKE_HOST_ACTION_CLOSE` and an arm in
  every binding's action drain.

`driver.LoopBridge` (`src/driver/loop_bridge.zig`) composes them: the loop's
hooks adopt (`makeConnCtx`), serve (`serve`), and release (`freeConnCtx`),
and every entry point ends by draining the host's action queue into the loop
— `flush` becomes `armOutbound`, `close` becomes `closeSlot`,
`need_gift_id` draws at the driver tier's entropy boundary, `dial` is
refused fail-closed. Publishing runs at adoption (`driver_core.Publish`),
before any inbound frame is served, so a partner's first fetch cannot race
the registration. The consumers land with it: the
three-party-handoff-across-one-loop test (the deposit leaves on a connection
only `armOutbound` can reach) and the `zig build tcp-loop` scale harness.

## Scope (what this does not decide)

- **No loop-side dial executor.** A bridged host answers every `dial` action
  with `dialFailed`, so it originates gives but cannot redeem one: a bridge
  host is not yet a handoff recipient. The executor lands with a
  loop-recipient consumer.
- **No loop-global fan-in backpressure.** ADR-0042 stays per-connection: a
  many-to-one fan-in's sources are not throttled by the sink's read-park.
- **The iroh `LoopHost` is not converged.**
  `src/net/transport/iroh.zig`'s `LoopHost` (~467 lines) duplicates
  `net.Loop`'s slot / outbound / backpressure / close state machine as a
  second, diverging copy. `net.Loop` already grew `armOutbound` /
  `closeSlot` so a host bridge can ride it; converging iroh onto
  `net.Loop` + `LoopBridge` (and deleting the dup) is a high-risk own
  pass, not in scope here. Until then, every bridge hardening lands twice
  or only on TCP.
- **No deadline on blocking answer-waits.** `BlockingHost.awaitVow` and
  `ConnectedVat.settle` still spin forever if a partner opens then never
  answers. The handshake budget on `finishOpen(…, ?budget_ms)` is the
  pattern; an optional `deadline_ms` → `error.WaitTimedOut` plus a
  "partner opens then stalls" scenario is the follow-up, deferred only
  for scope.
- **No C ABI budget knob.** `local_turn_budget` is not yet surfaced through
  `pancake_host_new`; an embedder loop over the C ABI still drives
  unbounded. The `close` action is already mirrored, so the knob is additive.

## Alternatives Considered

- **A wrapping loop tier owning per-connection serve state**: rejected —
  that was the retired shape; node-less, so handoff was unreachable, and it
  duplicated decisions the host already owns.
- **Loop-owned peers handed to the host by value**: rejected — the loop's
  fixed slots hold each peer inline at a stable address, and
  `registerConnOver` exists precisely so adoption never moves or re-owns a
  peer.
- **Failing the fed verb on any budget breach**: rejected — the fed
  connection's work can flood a sibling, and closing the messenger punishes
  the wrong session while the flooded vat keeps its runaway queue.

## Consequences

- `test/driver/host_budget_test.zig` pins the attribution contract;
  `test/driver/host_adopt_test.zig` pins adoption ownership and the
  batch-consumption subtlety; `test/net/completion_cross_arm_test.zig` pins
  the cross-arm at the net layer; `test/driver/loop_bridge_test.zig` holds
  the theorem and the budget runaway over real sockets.
- `zig build tcp-loop` is the live scale step (measured footprint printed,
  never gated — ADR-0073 owns the wall-clock rationale).
- The bridge's retained allocations (shells and the ConnId→slot map) are
  ledgered in the memory rule; `completion.MakeConnCtx` carries the slot so
  cross-connection verbs have a handle.

## Notes

ADR-0042 (outbound backpressure), ADR-0054 (shared read pool), ADR-0056
(gift registry and parked withdraws), ADR-0066/0069 (node routing and
tokens), ADR-0072 (the byte-fed host and the retired loop tier), ADR-0073
(why live-harness figures print rather than gate).
