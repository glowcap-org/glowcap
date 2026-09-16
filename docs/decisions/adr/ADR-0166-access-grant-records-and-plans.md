---
id: ADR-0166
status: accepted
date: 2026-09-15
tags: [loam, access, storage, grants]
decision: "Resident and loaded grants share one revision-checked evaluator and mutation planner; bounded resource, grant, and change records participate in Loam transactions."
supersedes: []
superseded_by: []
amends: [ADR-0155, ADR-0158]
amended_by: [ADR-0167]
---

# ADR-0166 Managed grant records and plans

## Decision

`access.core.GrantView` supplies grant records at one owner and resource/grant
revision pair. It shares `ResourceView`'s synchronous data-source contract:
unloaded records produce exact read demands; missing, malformed, stale, and
uncertain state refuses evaluation. The embedding performs loading outside the
core and restarts evaluation at a current revision. Grant ancestry has a depth
bound and reads current ancestor lifecycle, configured terms, and issuance
ceilings. A cached positive result never authorizes a later effect.

`GrantPlan` prepares issuance, delegation, policy changes, pause, resume, and
revocation over these views. It owns copies of changed selections; lifecycle
changes allocate nothing. Its `changes` result describes the changed grant,
the optional parent's child-count update, expected previous row revisions, and
the proposed change event. All changes carry the next grant revision. Event
data becomes a committed event only when its transaction commits.

The resident `GrantLedger` uses this evaluator and planner. It continues to own
its memory, graph reservation, native capability bindings, and pending-write
lifecycle. Grant ancestry depth is computed from the shared view instead of
being separately stored in resident entries. Durable integration does not copy
the ledger's authority algorithm or serialize its allocation layout.

A plan is a trusted-owner operation. It neither conveys invocation authority
nor reserves storage. The submitting owner must possess management authority,
reserve a fresh non-reused grant identity when issuing, and hold or check the
base owner revision through the encompassing content transaction. Comparing
the plan with a view does not independently establish backend currency. Loam's
lease validation, transaction ownership, and exact completion govern that part.
The owner revision pair, a Loam snapshot revision, and a Loam row's last changed
revision are distinct. Access-plan preconditions use the first; Loam batch
preconditions use the latter two. A store can host multiple owners and ordinary
records without unrelated writes incrementing each owner's logical revision.

## Encoding and ownership

`access.records` uses the existing canonical Syrup field syntax:

| Record | Contents | Decode ownership and bound |
| --- | --- | --- |
| `ResourceRecord` | Identity, kind, parent, changed revision | Scalar value; 192 bytes maximum. |
| `GrantRecord` | Identity, parent, changed revision, ceiling and configured terms, own lifecycle, delegation budget, child count | At most two exact selected-resource allocations; 32 KiB encoded maximum. |
| `ChangeRecord` | Resource/grant revision pair, affected grant, issuance parent or lifecycle transition | Scalar value; 256 bytes maximum. |

All grammars start at version 1. They store stable fields rather than native
pointers. Each selected scope contains at most 256 strictly sorted, unique
identities. Policy values contain their schema identity, permission mask, and
16 optional unsigned bounds. The immutable policy descriptor still defines
what those bits and bounds mean. Structural decoding cannot establish current
scope, permission, control powers, or the authority to publish an event.

`GrantRecord.decodeOwned` retains no input-byte borrow. Its result must be
deinitialized with the supplied allocator. Encoding returns an exact owned
byte slice. A grant view's selected terms remain borrowed until its next grant
lookup; resource lookups must not invalidate them. Callers encode or copy a
plan's borrowed unchanged fields before another grant lookup. Prepared changed
terms remain owned by the plan until installation or cancellation.

## Atomic participation and remaining integration

The native test stages a grant revocation, content change, typed retention
edges, and change record in one ordinary Loam transaction. An aborted backend
transaction preserves the old grant and content and leaves no event. A committed
transaction with a lost local acknowledgement fences reads until receipt
resolution. Closing and reopening LMDB then restores the matching content,
revoked grant, and event. Restored records use the same evaluator.

This evidence holds exact Loam object references in its fixture. A production
managed owner still needs its durable header and indexes, logical revision
tracking, bounded demand continuation, control/publication definitions,
publication-capacity reservations, and event retention/disclosure. Managed IDs
are distinct from Loam object IDs; decoding either is not capability restoration.
No control, owner snapshot, or CapTP publication is reconstructed by these codecs.

The [managed access acceptance plan](../../planning/loam/access/acceptance.md) owns those
remaining parts. They must use Loam's leases, batches, and recovery and the
existing Host/Vat. The native record test is not a process-kill, power-loss,
remote event, or complete Rooms integration proof.

## Evidence

The access suite covers loaded and faulting views, ancestor revocation, cycles,
depth limits, mixed revisions, resource movement, non-publishing preparation,
allocation-free lifecycle edits, bounded canonical encoding, truncated records,
selected-input ownership, and every selection allocation failure.
`loam-lmdb-test` owns the atomic record participation and reopen evidence.
These are internal managed access contracts; they assert no new OCapN semantics.
