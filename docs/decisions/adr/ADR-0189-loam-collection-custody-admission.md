---
id: ADR-0189
status: accepted
date: 2026-10-04
tags: [loam, persistence, memory, lifecycle]
decision: "Capture live custody once per collection cycle and journal newly admitted mark obligations until their exact collection receipt confirms durable shading."
supersedes: []
superseded_by: []
amends: [ADR-0164]
amended_by: []
---

# ADR-0189 Loam collection custody admission

## Context

Resnapshotting unchanged live custody each batch repeats copying, hashing and
already-marked lookups in proportion to custody times batch count. It also
allocates record scratch each batch. A retained initial snapshot would avoid
that cost but miss later leases and local holds. The collection owner must
preserve those admissions without exporting bookkeeping to applications.

## Decision

The Store owns a bounded journal of unconfirmed mark obligations and reusable
record scratch, allocated lazily when a cycle starts. It captures retained IDs,
pending reads, and pinned portraits with their strong historical edges once.
Registry and Cache remain the authorities for live custody. The journal holds
effects awaiting durable confirmation, never invocation authority.

Before custody escapes, reserve journal space. Append the obligations only
after minting the retention token, lease or read request succeeds. Each exact
immutable resident portrait reports its ID and strong edges on its first lease
exposure in the cycle. Subsequent pins reuse that report. Replacement creates
an unreported portrait. Snapshot promotion does not refresh this marker.

Clean idle starts directly with roots: the prior finishing receipt guarantees
that temporary rows are gone. Initial and tracing batches submit all pending
obligations before phase work. Restart clearing and finishing batches submit
none: clearing may erase marks, and finishing performs no further deletion.
Finishing admissions create no debt. Remaining holders are captured next cycle.
Clearing ends its batch at the transition into root
scanning, so tracing cannot outrun the next custody submission. Confirmed
installation acknowledges only submitted roots.
Abort, unchanged completion and unknown outcomes preserve debt, and unknown
outcomes keep the existing admission fence. Cycle completion releases the
journal. Next-cycle capture accounts for remaining holders. Reopen captures
fresh custody and retains the existing fresh-trace contract.

## Alternatives considered

- Rescan custody with per-entry epochs: avoids some hashes but repeats table
  traversal every batch.
- Keep the first snapshot: misses later claims and newly held historical edges.
- Reuse scratch alone: removes allocations while leaving multiplied root work.
- Submit a root prefix: requires an additional phase barrier to keep sweep from
  deleting targets in the unsent suffix. Full bounded submission keeps one
  refusal and completion contract.

## Consequences and bounds

The journal holds at most `max_collection_roots` IDs. Scratch holds at most
`max_record_bytes`. Admission exhaustion refuses before publishing custody.
Initial capture failure publishes neither cycle state nor portrait markers.
Existing tokens, leases and pending reads remain protected. Releases may leave
conservative debt until its batch settles, without changing borrowed memory.

`work_limit` bounds record visits and phase transitions. Root shading is bounded
separately by journal capacity. It is not charged to that limit. Marks and the
trace queue remain in backend storage. No graph-sized resident index, worker,
runtime, database format change or longer database-reader lifetime is added.

## Evidence and gate

Core collection custody scenarios cover clearing, late claims, historical
portraits, pending reads, refusal before publication and exact acknowledgment.
Existing collection and LMDB tests retain cycle, write-barrier, rollback and
restart coverage. `bench-loam -- --collection-only` varies holds and batch work
over a fixed graph and records preparation allocations, hash inputs and root
lookups separately from tracing and commit count. `check`, `runtime-check` and
the Loam browser lifecycle proof exercise the affected shared implementation.
