---
id: ADR-0167
status: accepted
date: 2026-09-15
tags: [loam, access, storage, memory]
decision: "A durable managed owner keeps its header and sparse identity directories in Loam records, with bounded resumable loading and the shared grant evaluator."
supersedes: []
superseded_by: []
amends: [ADR-0166]
amended_by: [ADR-0168, ADR-0178, ADR-0179, ADR-0180, ADR-0230]
---

# ADR-0167 Managed owner storage

## Decision

`loam.access.storage` binds the managed model to one existing Loam Store.
An owner header persists its identity, policy descriptor, logical revision
pair, independent control revision, identity allocation counters, directory
roots, and latest change record.
Opening an owner starts from its exact Loam header reference. Local record
lookup supplies data to the shared resource/grant views and does not create
a use capability or control.

Resource and grant slots each use a sparse radix directory. Four byte-sized
digits cover a 32-bit slot. Each directory page carries a 256-bit occupancy
mask and strong Loam edges in digit order. A lookup visits at most four pages
and its target record. A page validates its owner, family, level, and prefix
against the selected path. Record identity remains authoritative after lookup.

These pages participate in ordinary Loam transactions and tracing collection.
They work with both current backends without a second index-commit protocol,
backend-specific authority logic, or an untracked retention structure. The
cost is additional record lookups and page updates above LMDB's physical tree.
Measure it before choosing an engine-specific secondary-index mechanism.
This is an application identity index, not a replacement physical database.

A read operation pins its bounded working set through Loam leases. Index
traversal retains its position across storage misses, so a cache smaller than
the directory path still makes progress. The operation carries the store's
snapshot revision. A commit requires reopening it before further authority
evaluation. Reads that consume composed owner proposals also bind the exact
staging transaction and expire when it ends, even after abort or absent recovery.
An uncertain write refuses reads until Loam resolves its receipt.
The embedding executes explicit read work and delivers completion. Close
refuses while that operation still owns submitted storage work.

New identities advance durable owner counters atomically with their records
and directory entries. This profile never reuses committed slots. Exhaustion
refuses issuance. An aborted, unpublished proposal consumes no logical slot.
Resource and grant IDs remain distinct from Loam object IDs. Policy
descriptors persist stable keys and bound operators, preserving the meanings
of grant masks after reopening.

## Mutation boundary

The storage participant stages owner metadata, resource/grant records,
directory changes, and the latest grant-change record in the caller's existing
Loam transaction. The caller may stage content in that same transaction.
Shared `GrantPlan` rules decide grant changes. Loam owns preparation, commit,
uncertain outcomes, and recovery. No managed owner introduces an executor or
independent write-completion state machine.

> **Composition amendment (2026-09-22).** Transactions compose several
> managed changes into one owner mutation: each stage validates and stages
> against the transaction's own composed state and re-proposes shared records
> (the owner header, a parent grant row) in place, so the submitted batch still
> holds exactly one mutation per record. The re-propose rule lives in the
> [atomic mutations contract](../../loam/api.md#transactions). The
> [owner transaction tests](../../../test/loam/access/owner_test.zig) and the
> [LMDB composed reopen test](../../../test/loam/lmdb/owner_test.zig) hold the
> evidence.

One transaction stages at most one mutation per managed owner in the submitted
batch. A prepared append borrows
its read operation until explicit close. Close refuses while submitted work
still owns a buffer. The caller publishes proposed identities and events only
after confirmed commit.

The initial stored change is the latest owner event. Retained replay and
subscriptions need explicit retention/disclosure policy and remain separate
work. Replacing the header's event edge releases the old event for ordinary
tracing collection unless another record or live lease retains it.

## Scope and evidence

This profile establishes owner creation/opening, indexed resources and grants,
bounded data loading, and local grant mutations. Durable native use/control
bindings, publication restoration, resource reorganization/deletion, child
listing indexes, and remote event delivery remain integration work in the
[storage plan](../../loam/access-storage.md).

Portable tests exercise abort, mixed owners and generations, stale reads during
mutation, malformed directory paths, allocation failure and cleanup, and a
258-resource directory traversed with two cache slots. A read has at most 20 KiB
of inline state plus one bounded binding allocation. An append has at most
52 KiB of inline path state. Loaded grant evaluation makes no allocator calls.
These bounds exclude Store cache buffers and transaction staging.

Native LMDB tests reopen the owner, resolve committed and aborted uncertain
revocations with matching content, and collect replaced latest events. Portable
tests use the same records and operations with Loam's volatile backend. Neither
set establishes a new OCapN protocol claim or a managed workload throughput bound.
