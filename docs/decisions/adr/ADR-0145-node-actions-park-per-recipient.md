---
id: ADR-0145
status: accepted
date: 2026-09-05
tags: [host, scheduling, backpressure, node]
decision: "A Node action refused by its recipient's outbound pressure parks on that recipient and re-enters the queue when that recipient's outbound is next taken; the shared Node queue is ordered per recipient, not globally."
supersedes: []
superseded_by: []
amends: []
amended_by: []
---

# ADR-0145 Node actions park per recipient

## Context

The Host drains the sans-io Node's action queue through a peek-and-commit
seam: an action is executed while it is still at the head, and consumed only
once its Host-side consequence has committed, so an allocation failure leaves
the exact action retryable. Two arms of that executor send to a recipient
session: a break of a served answer, and the settle or break of a Host-owned
deferred promise, which projects to every session that pipelined at it. Each
send admits against the recipient's outbound budget and refuses with
`OutboundBackpressure` when the partner has not read enough.

That refusal used to unwind the whole pump pass with the action still at the
head. The queue is one FIFO for every session the Host serves, so every dial,
settle, gift draw, and break queued behind that action waited on one slow
partner. `test/driver/core_host/pressure_test.zig` reproduces it: a sibling
session's break never left while the first recipient's budget was zero. That
crosses the resilience line that independent work stays live, and it did so
silently, because the pass ended on a pressure boundary the embedder already
treats as ordinary flow control.

## Decision

A recipient's outbound pressure is that partner's flow control and holds back
only what is bound for it. When the executor's send refuses with backpressure,
`execNodeAction` returns the refusing recipient instead of an error, and the
drain moves the action off the shared queue into `Host.parked_node_actions`,
one row per recipient, with the action's owned payload intact
(`Node.parkPeekedAction`). The queue seat the action returns to is promised
before it leaves the queue, in that same verb, so every fallible step precedes
the take: a refusal leaves the action at the queue head and the pass ends on
the pressure as before, and the return through `Node.pushParked` never
allocates. The row re-enters the queue in its original order when the embedder
next takes that recipient's outbound bytes, the one event that can have moved
the pressure, and when the recipient's session is released. Release requeues
rather than frees because a parked deferred settle also owes projections to
other sessions; an action bound only for the released recipient finds no
session when it runs and is consumed.

The deferred-promise arms take part by reporting the projection recipient
whose send refused, with that projection still owed, so the same rule covers
a promise pipelined at by several sessions.

The queue's order is therefore per recipient. Actions bound for one session
keep their relative order; actions bound for different sessions may complete
in either order. Nothing in the Node relies on cross-recipient order: a
settle names its route by id, a retirement is claimed by the Node's own
state, and a dial is an attempt the executor commits.

## Scope (what this does not decide)

A parked row returns to the queue only when the embedder takes the recipient's
outbound bytes. An embedder that stops taking bytes from a pressured session
keeps that session's actions parked, which is the same standing as its
outbound frames. An allocation failure in the executor's Vat consequence still
leaves the action at the head; it is not a recipient's pressure.

## Alternatives Considered

- **Rotate the refused action to the queue tail**: one pass could re-meet it
  and spin until a bound; the parked row costs the same order change and needs
  no bound.
- **Reserve the recipient's outbound charge when the Node mints the action**:
  the deferred arms project to recipients the Node does not know at mint time,
  and it would spend outbound budget on work that may never run.
- **Condemn the pressured recipient**: turns ordinary flow control into a
  protocol failure.

## Consequences

`Host.parked_node_actions` is a Host-level map with precise frees, named in
the memory ledger; no session field grows. The Node's action reservation
counts parked seats beside its proxy and redeem promises. `execNodeAction`,
`capability_promise.fulfill`, and `capability_promise.breakPromise` report one
`ActionOutcome`: done, or parked on the refusing recipient.
`HostSession.takeOutbound` and session release requeue infallibly, so neither
can fail on a parked row.

## Evidence and gate

`test/driver/core_host/pressure_test.zig`, "a node action parked on one
recipient's pressure leaves sibling actions live", was red before this change
and is green after it, and it shows the parked break landing once the
recipient's bytes are taken. Its sibling, "releasing a pressured recipient
returns its parked actions to the queue", holds the release path under the
leak check with an owned payload. `zig build test` runs both.

## Notes

ADR-0112 records the loop-archive drain this queue feeds; ADR-0114 the
out-of-line session close timing this table's shape follows.
