---
id: ADR-0162
status: accepted
date: 2026-09-14
tags: [loam, persistence, memory, lmdb]
decision: "Implement one portable record and transaction contract with volatile and optional LMDB realizations, bounded leases, and durable opening incarnations. Retain immutable collections as Loam's dependency-free leaf."
supersedes: []
superseded_by: []
amends: [ADR-0061, ADR-0161]
amended_by: [ADR-0163, ADR-0164, ADR-0165, ADR-0181, ADR-0182]
---

# ADR-0162 Loam records, transactions, and native storage

## Decision

`glowcap.loam` exposes `collections`, `records`, `core`, `Volatile`, and `access`.
Collections remain a dependency-free immutable HAMT. The record vocabulary and
Syrup envelopes sit below the transaction core, which validates graph changes
and owns completion, recovery, and bounded leases. Neither depends on managed
access, actors, Host, or database I/O.

The optional Zig module `"glowcap_loam_lmdb"` executes the same batches as the
volatile backend. LMDB 1.0.2 is pinned from OpenLDAP, with its unmodified
sources and license notices. Ordinary networking and portable Loam consumers
do not link it. The initial native profile supports POSIX lifetime locking and
uses LMDB's synchronous durability settings without weaker flush flags.

A store opening claims an exclusive backend and durably advances its
incarnation before returning. Object names include store identity, opening
incarnation, and a monotonic sequence. Creation names are valid only in the
transaction that allocates them. Abort, deletion, and reopen never recycle one.
Existing records retain their names across openings. No identifier becomes a
CapTP reference merely by being stored.

A batch owns encoded record deltas and expected revisions. The common Zig
validator checks the complete delta inside the backend transaction before any
write. Records, strong-reference validation, root flags, byte/object totals,
revision, and the current submission receipt commit together. Cycles between
new records are permitted. Explicit destruction refuses a rooted object.
Incoming references to a destroyed unrooted object resolve as gone.

The core emits read requests with bounded owned buffers. Native reads copy one
row from its mapped value, then end the LMDB reader before completion delivery.
Leases retain validated data snapshots. They do not grant authority or preserve
historical permission. Cancellation retains a read's buffer until the worker
reports completion. Backend close stops new work and remains busy until active
calls and prepared native commits release the environment.

Preparation copies only changed records. Known-unchanged failure discards the
batch. An unknown outcome fences use until the original worker has retired and
an authoritative receipt lookup resolves it. Installation allocates nothing.
The receipt covers the one outstanding local submission. Remote operation
retry, durable inboxes, and historical receipt retention remain separate work.

## Evidence and limits

The native suite proves cyclic graph reopen, identity preservation, atomic
abort, lost-acknowledgement recovery, map exhaustion, and exclusive custody.
The process proof sends SIGKILL before native commit and after native commit
but before core installation, then verifies both records in a fresh process.
This establishes those process-failure boundaries, not hardware power-loss
behavior or a performance comparison with another engine.

The [Loam guide](../../loam.md) owns current usage and limitations.
[ADR-0181](ADR-0181-offline-lmdb-replacement.md) extends the native profile
with offline compaction and installation under continuous writer custody.
[ADR-0163](ADR-0163-record-backed-sleepy-actors.md) extends this foundation with
record-backed sleepy actors and local capability restoration. Managed access
participation, foreign/browser APIs, and backend comparison
remain in the [implementation plan](../../loam/architecture.md).
