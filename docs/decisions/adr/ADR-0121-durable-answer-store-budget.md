---
id: ADR-0121
status: accepted
date: 2026-08-24
tags: [captp, session, memory, resilience, flow-control]
decision: "Sent inbound-answer resolutions leave transient outbound flow accounting when they enter the Session answer store. That durable owner has an independent cumulative byte cap, enforced before capacity reservation or export mutation; overflow fails loud as resource_exhausted and never evicts answer authority."
supersedes: []
superseded_by: []
amends: [ADR-0025, ADR-0116]
amended_by: [ADR-0124]
---

# ADR-0121 Durable answer-store budget

## Context

A sent answer resolution has two different lifetimes. Before encoding it is
transient outbound work; after the send commits, the Session may need the
semantic resolution for pipelining, listeners, legal answer-name reuse, and
V1 callback projection until the partner sends `op:gc-answers`. Treating both
lifetimes as one flow-control charge deadlocked a saturated session: the
waterline refused the encodes that would have released its own pending work.

Separating the ledgers fixed that liveness defect, but answer-row cardinality
alone does not bound the durable bytes. A conforming partner can issue many
distinct answered calls and withhold `op:gc-answers`; each row may retain a
large, valid resolution. At the default 65,536-row limit, frame admission is
not a useful aggregate memory bound.

## Decision

`SessionLimits.max_retained_sent_answer_bytes` independently bounds the exact
owned-resolution charge held across sent inbound answers. Its default is
16 MiB. The existing `retained_sent_answer_bytes` counter remains the sole
accounting authority; no adapter, Peer flow queue, or codec mirrors it.

The answer store plans a settlement before allocation or authority mutation:
it measures the owned tree once, subtracts the replaced row's prior charge,
checks overflow and the cumulative cap, and resolves any promise target. Only
an admitted plan may reserve export-table capacity or materialize a lazy answer
payload. Commit then moves ownership and updates the counter without another
walk, allocation, or copy.

Crossing the limit returns `RetainedAnswerCapExceeded`. The engine classifies
that refusal as `resource_exhausted`, emits a terminal `op:abort` when it is an
inbound-driven session outcome, and closes the session. The store never evicts
or silently drops a resolution: doing so would change pipelining authority and
could redirect a later call or listener.

The limit is a `u32` beside the existing bounded gift counts. The early-withdraw
row limit is also a `u32`; all four values fill the same two machine words those
knobs already occupied, so `Peer` remains within its checked 1,136-byte fixed
footprint. Runtime admission adds only constant-time integer arithmetic. Frame
movement, settlement ownership, and encoding remain zero-copy.

## Consequences

- Transient pressure and durable retention are independently tunable and cannot
  deadlock one another.
- Two individually valid resolutions may still exceed the session aggregate;
  the later settlement fails before changing its answer or export authority.
- Replacement admission uses net delta. A smaller replacement can proceed at
  the cap, while an oversized replacement preserves the prior resolution and
  exact charge.
- Answer GC, local-promise retirement, detached-obligation retirement, and
  teardown release the same counter they already owned; released capacity can
  admit a later settlement.
- The versioned C and binding options surface exposes the durable budget
  independently of transient pressure (ADR-0124).

## Evidence

`test/engine/node/answer_settlement_test.zig` pins cumulative refusal,
replacement atomicity, export non-mutation, exact release, and readmission.
`test/engine/abort_projection_test.zig` pins the typed resource classification.
The ordinary allocation and footprint gates run under `zig build test`.
