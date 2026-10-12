---
id: ADR-0099
status: accepted
date: 2026-07-31
tags: [actors, scheduling, vat, resilience, memory]
decision: "A Vat queues owned turns in bounded, reclaimable batches attributed to an ingress. Admission is atomic under per-ingress turn and byte caps, resource exhaustion is an actor-layer refusal, generic Vat drives rotate fairly, and Host batch drives isolate each Port to its own ingress budget."
supersedes: []
superseded_by: []
amends: [ADR-0036]
amended_by: []
---

# ADR-0099 Shared-Vat scheduling and admission

## Status

Accepted and shipped. `actors.Vat` owns bounded ingress queues and fair generic
rotation. The standard Host owns one Vat and assigns one ingress to each
session Port. Host batch drives consume only the attributed ingress, so a
runaway connection is refused without draining or condemning a sibling. The
same admission and queue-reclamation contract applies to a pure-local Vat with
no Host.

## Context

ADR-0036's Vat owns one FIFO and drives it to quiescence. Its queue arena can
reset when that one work stream drains. Composing several session Ports with
one Vat changes that lifetime: a busy or adversarial ingress can keep the arena
alive, consume unbounded pending work, or starve turns from another ingress.
That is a scheduler and resilience problem, not capability identity.

The actor layer owns the queue, so it must also own admission and the refusal
vocabulary. Host may identify a Port as an ingress, but actors cannot depend on
Host types and pure-local callers need the same bounded behavior.

## Decision

### Queue storage is bounded and reclaimable

The Vat owns queued messages in bounded chunks or batches. Enqueue performs the
one ownership copy required to outlive the caller. Queueing adds no second
message-tree copy. A chunk is released as soon as its final borrowing turn
settles, even while other ingresses still have pending work. Nested drives may
exhaust a chunk but cannot recycle it under an outer turn still reading one of
its messages. No arena or retained capacity waits for total Vat quiescence
before it can shrink.

Chunk and retained-spare capacity have explicit checked bounds. Queue turn,
byte, and single-chunk limits are runtime configuration with bounded defaults.
The Vat-wide spare has a checked static bound. An oversized single turn is
measured against the byte limit before allocation and never receives an
unbounded chunk.

### Every turn has an ingress

An ingress is an opaque actor-layer id. A Host Port owns one id. Pure-local use
has a local ingress. A turn spawned or
sent causally from another turn remains charged to that ingress until the
causal batch ends. An embedder cannot erase attribution by bouncing work
through a local actor.

### Admission is atomic and typed

Each ingress has pending-turn and pending-owned-byte caps. The Vat computes the
complete admission charge before mutating a queue. If either cap would be
exceeded, it refuses with the actor-layer `ResourceExhausted` reason and
enqueues nothing. Host and bindings project that typed reason.

The same rule applies to pure-local ingress. Configuration may grant different
caps, and no ingress is unbounded.

### Scheduling is fair under a turn budget

The Vat preserves FIFO order within one ingress and rotates among runnable
ingresses. A drive call accepts a turn budget and yields after consuming it,
even when work remains. Newly enqueued work cannot move an ingress ahead of an
already runnable peer. Empty ingress queues and completed chunks are reclaimed
without scanning every historical ingress.

Fairness is observable progress, not equal wall time: with two continuously
runnable ingresses, each receives turns across bounded successive rotations.
Handler execution remains synchronous and non-preemptive, so a single slow
handler is still an application concern.

The standard Host uses the stronger session-isolation form: a batch drive runs
only the Port ingress that caused it. Host's dirty-session worklist chooses the
next Port. The Vat does not drain a sibling because both are runnable.
A Port whose attributed ingress exceeds its configured local-turn budget is
condemned while every other Port remains live. That includes a Port whose
handler submitted the work to the condemned ingress: attribution follows the
destination Port selected by the Host operation, not the callback stack that
requested it. Fair ring rotation is the contract of a generic Vat drive and
nested local drive.

## Required evidence

Acceptance evidence is:

1. Fill one ingress to its turn cap and byte cap independently. The next enqueue
   returns `ResourceExhausted`, changes no counters, and leaves no partial turn.
2. Keep two ingresses continuously runnable under a small generic Vat budget
   and prove both make progress while preserving per-ingress FIFO order.
3. Through a production Host, have a handler on Port A submit enough work to
   Port B's ingress to exceed B's budget. Port B is condemned with a typed
   resource refusal while Port A remains live and continues serving.
4. Drain one chunk while another ingress remains busy and prove its allocation
   and accounting are reclaimed before total Vat quiescence.
5. Prove a causal local send remains charged to its originating ingress and
   cannot bypass that ingress's limits.
6. Pin one queue ownership copy, chunk allocation counts, retained capacity,
   and Host/Vat footprint deltas under empty, ordinary, and pressure traffic.

Items 1, 2, 4, and 5 are held by
[`test/actors/vat/ingress_test.zig`](../../../test/actors/vat/ingress_test.zig). The allocator
half of items 4 and 6 is held by
[`test/actors/vat_alloc_budget_test.zig`](../../../test/actors/vat_alloc_budget_test.zig)
and [`test/actors/vat_footprint_budget_test.zig`](../../../test/actors/vat_footprint_budget_test.zig).
Item 3 is held by
[`test/driver/core_host_budget_test.zig`](../../../test/driver/core_host_budget_test.zig).
The Host shell ceiling is compile-time enforced in
[`src/driver/core/host.zig`](../../../src/driver/core/host.zig).

## Shipped state and measurements

`actors.Vat` owns opaque ingress ids,
pre-clone atomic admission, per-ingress counters, independently reclaimable
queue chunks, and one-turn fair rotation. The pure-local tests cover turn,
cumulative-byte, and single-chunk refusal independently, causal attribution,
per-ingress FIFO, close-after-drain, nested-drive message lifetime, and
allocator release while another ingress remains runnable.

The standard Host owns one Vat, opens one ingress per session Port, and drives
only the causal ingress at a batch boundary. Multi-session pressure proves that
a sibling flooded through Host routing receives the resource-exhausted verdict
without failing the connection whose handler caused the enqueue.

The checked measurements are:

- a warmed local enqueue-and-drive batch performs zero general-purpose
  allocations
- the Vat is charged once per Host, independent of session count
- the fixed queue chunk is 4,152 bytes, below its 4,224-byte metadata ceiling
- the one Vat-wide spare retains at most 4,096 payload-arena bytes
- the per-session `HostSession` ceiling is 528 bytes

[The footprint table](../../ladder.md#2-performance-at-scale) records the current
session and Host budgets.

## Scope (what this does not decide)

- Host capability identity, Port projection, gifts, and publication are
  ADR-0096's decisions.
- The Vat is single-threaded, with no preemption, parallel actor execution,
  hidden I/O, or scheduler thread.
- Backpressure on transport frame queues remains a net/engine concern. This
  record starts after a delivery becomes actor work.
- Exact policy defaults may change with measurements. Unbounded admission and a
  never-reclaiming queue are forbidden.

## Alternatives Considered

- **Keep one Vat-wide FIFO and arena.** Rejected: one active ingress can retain
  every queued allocation and prevent another from making progress.
- **Let Host schedule one queue per Port.** Rejected: queue ownership and local
  causal sends belong to Vat, and pure-local users need the same contract.
- **Use only a turn-count cap.** Rejected: one deeply owned message can consume
  far more memory than many scalar turns.
- **Admit incrementally and roll back on overflow.** Rejected: partial enqueue
  makes refusal non-atomic and adds cleanup work on the untrusted
  path.
- **Preempt handlers.** Rejected: it changes actor turn semantics and requires a
  runtime the sync no-I/O layer does not own.

## Consequences

- `actors.Vat` has ingress ids, per-ingress counters, bounded queue chunks,
  budgeted drive, and a typed resource-exhaustion result.
- FIFO order is per ingress and a drive may yield at its budget, which amends
  ADR-0036's drive-to-total-quiescence FIFO.
- Host Ports supply ingress identity but do not own actor queues or scheduling
  policy. Host batch drives select one ingress. Generic Vat drives use fair
  rotation.
- Allocation, retained-capacity, and progress checks are acceptance evidence
  for the shared Vat.

## Notes

ADR-0096 widens one Vat from a session shell to a Host composition. This record
owns the actor-layer consequence of that wider lifetime.
