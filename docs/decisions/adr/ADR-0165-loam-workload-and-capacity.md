---
id: ADR-0165
status: accepted
date: 2026-09-15
tags: [loam, persistence, memory, lmdb]
decision: "Measure native application workloads on LMDB before widening the foreign API, preserve unchanged residency without refreshing lease authority, and expose explicit native capacity maintenance."
supersedes: []
superseded_by: []
amends: [ADR-0159, ADR-0162, ADR-0163, ADR-0164]
amended_by: []
---

# ADR-0165 Loam workload and capacity

## Decision

Use Rooms-shaped native workloads to establish the cost of the implemented
LMDB foundation. A SQLite implementation is not a prerequisite for Rooms or
the C/Rust interfaces. Compare engines when measured constraints justify that
experiment. This does not claim that LMDB outperforms another backend.

The benchmark uses the existing Host/Vat, attachment, transactions, and backend
executor boundary. Conversation headers have held actor capabilities; their
message chains remain plain records. It measures residency, edits, cold bursts,
and collection alongside queued reads. The
[benchmark method](../../../bench/loam/README.md) owns interpretation and limits.

Commit installation advances unchanged cached records to the installed revision
without copying their bytes. Changed and removed identities remain stale unless
a prepared replacement becomes resident. A cache entry already stale before
the commit cannot be promoted. Every lease retains its acquisition revision,
independently of the bytes it shares. Old leases and pending reads never acquire
current-authority status through this optimization.

Collection batches without deletions can preserve resident data because tracing
only changes collector rows. A batch that removes objects conservatively leaves
the entire cache stale; its receipt does not enumerate individual removals.
Unknown outcomes still fence reads and restoration until exact receipt recovery.

The native adapter reports map geometry separately from logical record bytes
and Zig allocations. Explicit map growth excludes all backend operations while
LMDB remaps; active operations refuse maintenance. Copied record leases remain
valid. Maintenance preserves a concurrent close fence. A failed remap closes
admission and requires reopening because LMDB may have released the old mapping.
Applications resolve write outcomes before maintenance and select capacity
within their own budget. No scheduler, automatic growth loop, or alternate
durability profile is added.

## Evidence and limits

The native workload runs at 64, 512, and 2,048 conversation endpoints with 256
and 4,096-byte messages. Its smoke case runs under `check`. These are local
service measurements, not full Rooms integration, physical cold-disk latency,
whole-process memory, or the live-session target.

Core tests distinguish a fresh lease from a historical lease sharing unchanged
bytes. They exercise changes, deletion, stale read completion, collection, and
committed or absent recovery receipts. Native tests exhaust a map, grow it,
and commit the formerly oversized transaction. They also exercise refusal
during active transactions and an impossible remap followed by successful reopen.

Compaction and replacement, sustained capacity pressure, and concurrent worker
interference remain in the [implementation sequence](../../planning/loam/architecture.md).
Managed access must prove atomic content, grants, and events before its hosted
foreign interface is frozen. Rooms then exercises a complete shared C/Rust path;
the benchmark does not replace that application evidence.
