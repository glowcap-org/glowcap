---
id: ADR-0164
status: accepted
date: 2026-09-15
tags: [loam, persistence, memory, lifecycle]
decision: "Reclaim unreachable local records through bounded transactional tracing, persisted work queues, live retention roots, and atomic insertion barriers."
supersedes: []
superseded_by: []
amends: [ADR-0162, ADR-0163]
amended_by: [ADR-0165, ADR-0189]
---

# ADR-0164 Loam tracing reclamation

## Decision

The Store owns collection semantics. Each collection batch uses the existing
write ticket, backend transaction, commit receipt, and uncertain-outcome
recovery machinery. The embedding schedules batches and executes storage work;
collection creates no worker or scheduler. Object keys occupy the `o` namespace,
metadata occupies `m`, and temporary tracing rows occupy `g`. Opening claims a
new incarnation and abandons incomplete tracing progress before any new sweep.

Collection clears prior scratch rows, scans durable roots, drains a persisted
FIFO mark queue, sweeps unmarked records, then removes tracing rows. A bounded
batch processes record visits or phase transitions; per-record edge limits
bound queue expansion. Marks and queue entries remain in storage rather than
requiring a resident graph index. LMDB uses ordered cursor seeks. The volatile
backend is a transactional reference implementation with linear cursor scans.

Live retention tokens, pending reads, and pinned record versions seed each
cycle, with later admissions journaled until confirmed shading under
[ADR-0189](ADR-0189-loam-collection-custody-admission.md). Historical pinned versions also seed their old strong edges. Host
endpoints own retention tokens automatically, so held actor capabilities survive
collection without residency or a durable root flag. Releasing custody removes
a root; explicit deletion and revocation retain their separate meanings.
Closing an attachment releases its tokens before the Store can be destroyed.

Preparing a collection batch freezes new leases and retention claims until
settlement. This prevents new authority from becoming usable after the worker
captures roots but before it deletes a candidate. Existing leases remain valid;
releases may proceed because conservative retention is safe. Between batches,
ordinary writes atomically mark every changed object and each new strong edge.
Sweep must drain these additions before another deletion. This is incremental
tracing over current writer transactions, not a long-lived database reader.

Corrupt or unsupported records, exhausted root capacity, and backend failures
stop collection rather than permitting incomplete reachability evidence.
Unknown commit outcomes fence the Store. Sweep progress and object/byte totals
commit with removals. Reopening never resumes a partial mark set as complete.
The store's existing incarnation and monotonic allocation prevent identity reuse.

## Costs and boundaries

One record-sized scratch buffer preserves edge iteration across LMDB writes,
whose borrowed values can otherwise become invalid. Root preparation owns a
bounded array; the Store owns a fixed retention registry. No collector state is
added to CapTP sessions and tracing invokes no actor behavior. Collection writes
advance the global revision. Batches without deletions carry unchanged cache
bytes forward; sweeping batches conservatively invalidate cache residency.
Lease acquisition revisions remain unchanged in both cases.

Marking needs storage headroom. A full map can prevent collection from making
progress; the implementation refuses the batch safely. The native adapter
provides explicit map growth between backend operations. Compaction, scheduling
policy, and broader performance measurements remain in the
[Loam implementation sequence](../../planning/loam/architecture.md).
Physical file shrinkage is separate from removing unreachable records.
Foreign graphs, durable distributed roots, and retained application history
require their own integration. Local retention tokens do not survive restart;
durable roots and strong edges express retention across process lifetimes.

## Evidence

Core tests cover unreachable cycles, weak targets, historical edges, late live
roots, root-capacity refusal, transactional storage exhaustion, and allocation
failure. A mutation after its source has passed the sweep cursor tests the
insertion barrier. Native LMDB tests exercise the same barrier, reopening, and
lost commit acknowledgement. `loam-collection-crash-test` kills a worker before
commit and after commit before installation, then verifies surviving roots and
completion of a fresh trace. This is process-failure evidence, not a power-loss
or performance claim.
