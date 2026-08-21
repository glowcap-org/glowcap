---
id: ADR-0067
status: accepted
date: 2026-07-05
tags: [engine, handoff, three-party, node, c-abi, bindings, sans-io]
decision: "The three-party redeem and origination sequencing sinks into a sans-io serve step on `engine.Node`: the node owns the exporter cache, the pending dial/withdraw/gift tables, the per-exporter give-location override, and every decision, consuming feeds (`acceptGive`, `exporterDialed`/`dialFailed`, `claimResolve`, `interceptFulfilledRoute`, `provideGiftId`) and emitting data actions (`dial`, `flush`, `settle`, `fail`, `need_gift_id`) the embedder executes. I/O, scheduling, and entropy stay host-side, with entropy an explicit requested effect. At acceptance this was projected as pancake_node_* serve verbs over PancakeNodeAction in `libpancake_ocapn` (since deleted; CapTP product work drains the same decisions through `pancake_host_*` / `PancakeHostAction`); all four bindings and the native interop driver collapsed onto the serve step as dumb action executors, deleting their hand-rolled redeem/origination orchestration; proven hermetically by `test/engine/node_test.zig` and live by the goblins handoff/gift and iroh handoff matrices."
supersedes: []
superseded_by: []
amends: []
amended_by: [ADR-0079, ADR-0113]
---

# ADR-0067 The three-party redeem sequencing is a sans-io serve step on the node

> **C-projection amendment.** The Zig `engine.Node` serve step and its
> semantics remain accepted. The former pancake_node_* C serve verbs over
> PancakeNodeAction were deleted with that waist; CapTP product work drains
> the same decisions through `pancake_host_*` / `PancakeHostAction`. Historical
> Decision and Consequences text below that names that C family describes the
> shape at acceptance time, not the current public C surface.
>
> **Vocabulary amendment (ADR-0079).** The multi-session product is binding
> `Host` / `PancakeHost`, not binding `Node`. Read historical binding-`Node`
> framing as acceptance-time vocabulary.

## Context

ADR-0066 sank the handoff *router* into `engine.Node` as pure routing data, but
left the *sequencing* above it to each embedder. Every binding therefore
re-implemented the same serve step, nearly line for line: intercept a resolve
carrying a handoff give before the vat sees it, refuse a give with no dialable
exporter locator, consult an exporter cache keyed by the locator string, dial
on a miss with the node identity, allocate a withdraw answer, subscribe before
sending, `sendWithdraw`, flush, await the withdraw's resolution, assert it is a
capability, enroll it, settle the original application answer with the token,
and break it on any failure: plus the gifter mirror (foreign-home consult,
home-is-self guard, gift-id entropy, gifter origination, exporter-leg flush before
recipient-leg flush). Four copies of a protocol sequence is the drift mode
ADR-0066 fixed for the tables, still open for the choreography.

The rationalization that kept it open was "the binding owns its async loop."
That conflates two things: the awaits are I/O effects the host must own; the
decision between them is pure data a sans-io core can own. The per-connection
`engine.Peer` already has exactly that shape (feed bytes, step, take
outbound); the cross-connection tier lacked it.

Engages the [First Principles](../../../AGENTS.md#first-principles): _protocol
correctness before implementation convenience_ (the redeem sequence is
protocol, not host idiom) and _the portable core stays sync and no-I/O_ (the
serve step owns decisions, never a socket, a scheduler, or entropy).
_Conformance is load-bearing_: the live `goblins-handoff` gate is the step's
oracle.

## Decision

`engine.Node` (`src/ocapn/engine/node.zig`) grows the serve state machine. New
state: the exporter cache (locator bytes to `conn_id`), the pending-dial table
(ticket to waiting redeems, so a second give for one exporter joins the dial
in flight instead of opening a second connection), the pending-withdraw table
(`(exporter conn, withdraw answer)` to the recipient answer to settle), and an
action queue. Feeds in, actions out:

The current implementation keeps the aggregate and action FIFO in
`src/ocapn/engine/node.zig`; its internal redeem scheduler is owned by
`src/ocapn/engine/node/redeem/`, split into parsed plans, dials, and tracked
withdrawals without changing this boundary.

- `acceptGive(recipient_conn, answer, give, exporter_locator)`: a live
  exporter withdraws immediately; an in-flight dial is joined; an unknown
  exporter queues `dial`; an empty locator queues `fail`.
- `exporterDialed(pending, conn_id)` / `dialFailed(pending, reason)`: the
  host reports the dial it performed; success caches the exporter and
  withdraws every waiter (allocating each withdraw answer from the exporter
  peer's own allocator), failure breaks every waiter.
- `claimResolve(conn_id, answer, outcome)`: the host offers every polled
  resolve; a pending withdraw's is consumed (enroll + `settle`, or `fail`),
  anything else is the application's, untouched.
- `interceptFulfilledRoute(conn_id, answer, far_id)`: the gifter mirror: a
  foreign-home reply is claimed and a `need_gift_id` action asks the host for
  32 bytes of entropy (an effect like dialing, requested only when a reply
  actually becomes a gift, so the ordinary reply path draws nothing);
  `provideGiftId(ticket, bytes)` answers it and the node originates the give
  and queues the two flushes, exporter first. Anything else is the host's
  plain resolve.
- `setExporterLocation(conn_id, bytes)`: the per-exporter give-location
  override (a dial-hint-only iroh exporter), stored where the origination
  recipe reads it instead of once per binding.
- `nextAction()`: drains `dial` / `flush` / `settle` / `fail` /
  `need_gift_id`, byte views valid until the next drain.

The step was projected into `libpancake_ocapn` as pancake_node_accept_give,
pancake_node_exporter_dialed, pancake_node_dial_failed,
pancake_node_claim_resolve, pancake_node_intercept_fulfilled_ref,
pancake_node_provide_gift_id, pancake_node_set_exporter_location, and
pancake_node_next_action over the PancakeNodeAction struct
(`src/c_abi/ocapn/node.zig` at acceptance; that C waist is deleted: see banner),
and all four bindings collapsed onto it:
each binding's `redeem` / `withdraw` / `originate` orchestration, exporter
cache, and pending bookkeeping were deleted, leaving a deliberately dumb action
executor (dial, flush, settle, break, draw entropy) plus the give/claim feeds
in its serve loop. Claim is offered only on connections the serve step itself
asked the executor to dial (pending withdraws exist nowhere else) so an
ordinary connection's reply path pays nothing for handoffs.

## Scope (what this does not decide)

- The ADR-0066 boundary stands: the vat (turn loop, behavior dispatch, async
  suspension) stays in the host; the pre-existing router verbs
  (`sendWithdraw`, `provideGiftId`, `enrollRedeemed`, `routeReference`) remain
  supported: the serve step composes them, it does not replace them.
- The dial itself: sockets, keyed-handshake pumping, reachability posture,
  stays host-side by construction; the `dial` action names the locator and the
  posture rule stays the transport-idiom ternary ADR-0066 recorded.

## Alternatives Considered

- **Keep the sequencing per binding.** Rejected: a protocol sequence copied
  four times is the same latent inconsistency ADR-0066 removed for the tables;
  the copies had already grown divergent locator validation.
- **An I/O-owning serve loop (dial inside Zig).** Rejected: pushes sockets and
  a scheduler into the sans-io core and fights every host runtime; the action
  queue keeps the boundary exact.
- **A callback-table serve (host registers dial/flush function pointers).**
  Rejected: callbacks invert control back into the core mid-call and make
  re-entrancy the host's problem; data actions keep the step a pure state
  machine the host drains at its own pace.

## Consequences

- `interop/goblins_interop/handoff_driver.zig` is rebuilt as a pure action
  executor: it feeds the give, performs the dial, offers resolves back, and
  receives the settle: so `zig build goblins-handoff` proves the serve step
  against live Goblins.
- `test/engine/node_test.zig` pins the decisions hermetically: interception,
  the fail-closed empty-locator and unopened-session arms, dial dedup, dial
  failure fan-out, claim-or-pass, token settlement and routability, exporter
  cache reuse, and the gifter claim/pass verdicts.
- At acceptance, `test/c_abi/node_test.zig` drove the projected pancake_node_*
  verbs over `include/pancake_ocapn.h`; that C waist and its header family are
  gone (see banner). CapTP product work uses `pancake_host_*` /
  `PancakeHostAction` instead.
