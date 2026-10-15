---
id: ADR-0217
status: accepted
date: 2026-10-13
tags: [loam, persistence, storage, lmdb, c-abi]
decision: "A Loam storage engine is a type that begins read and write transactions over four key-value operations: get, next in key order under a prefix, put, and remove, with commit and abort on a write. The core derives the worker-facing backend (read, commit, lookup, recover) from that contract once and checks the contract at compile time. An engine an embedding supplies reaches the same derivation through the C key-value callback, which gains a next operation so collections run there too. LMDB and the in-memory engine are the two Zig engines, and the Rust binding drives any engine through one executor trait."
supersedes: []
superseded_by: []
amends: [ADR-0162, ADR-0186]
amended_by: []
---

# ADR-0217 Loam storage engines implement one transaction contract

## Context

Loam's core never names a storage engine. It evaluates a batch, a name lookup,
a read, and a recovery against a key-value store taken as a compile-time
parameter. Above the core, though, LMDB is the shape of the system. The LMDB
backend, the in-memory backend, and the C executor each repeat the same glue
between the key-value store and the worker's four operations. The LMDB C
archive is one quarter LMDB and three quarters generic work that a second
engine would copy under its own symbol family. The Rust binding holds the
LMDB handle by type and calls the LMDB symbols from its store, finalizer, and
work modules. One names scenario runs on both Zig backends, and nothing else
would tell a second engine whether it behaves. The callback path in the
portable archive refuses iteration, so an engine an embedding supplies gets
records but no collections.

ADR-0162 named "volatile and optional LMDB realizations" of one record and
transaction contract. ADR-0186 left "collection cursors" to broader consumer
projections. This record settles the seam both left implicit.

## Decision

Two words. A **storage engine** holds bytes: LMDB, the browser's IndexedDB,
or memory. A **backend** is what the worker drives through read, commit,
lookup, and recover. Loam derives the backend from the engine.

**The engine contract is the transaction.** An engine begins a read-only
transaction that answers get and next and ends, and a read-write transaction
that also answers put and remove and then commits or aborts. Get returns the
row the transaction sees, including its own writes. Next returns the first
row in key order under a prefix and strictly after a floor, so a walk resumes
from its last key. Commit reports committed or unknown. A refused commit is
an error, and the transaction then changed nothing. Opening is outside the
contract because its arguments are the engine's own (a path and map budget,
an allocator and byte cap). The store's metadata row, under the core's
metadata key, is written and read inside the same transactions, so the
engine keeps no authority of its own. An open engine holds exclusive custody
of its store and refuses to close while a transaction is active, and after
that refusal it admits no new transaction until the close is retried.

**The core derives the backend once.** A core module owns the four
worker-facing operations as functions generic over any engine: read begins
a read transaction, checks the ticket against the metadata row, copies the
record into the request's buffer, and ends it. Commit begins a write
transaction, applies the batch, and commits or aborts. Lookup and recover
read inside a read transaction. The same module checks an engine against the
contract at compile time with a message that names the missing operation,
and checks a backend the same way where the worker takes one. LMDB and the
in-memory engine expose the four operations as one-line delegations, so
every current consumer compiles as before. Engine-specific operations stay
on the engine type: LMDB's map growth, compaction, and statistics are not
part of the contract.

**An embedding's engine takes the callback path.** The portable archive's
key-value callback is the second way in. Its plan reuses the core's
derivation for read, lookup, and recover and the resumable evaluation for
writes. The callback gains a next operation that returns one row in key order
under a prefix and strictly after a floor, into caller memory, within the
active transaction. An engine that cannot answer next synchronously reports
would-block, and the collection sweep resumes from its durable cursor, the
way a missing get already suspends a batch.

**One C archive shape per engine, generated from the engine.** The portable
archive owns the generic work, restore, commit, and recover bodies as
functions over an engine type. An engine's archive keeps its open options,
release, fingerprint, and one-line exports under its own symbol prefix. The
LMDB archive's symbols, header, and fingerprint do not change.

**The Rust binding drives an executor, not LMDB.** A store holds a trait
object that runs work, restores, commits, recovers, and releases through its
engine's symbol family. LMDB is the one implementation. Rooms opens its
session store through the trait. One indirect call per storage operation is
nothing next to the operation.

## Scope (what this does not decide)

No second engine is built. No asynchronous engine exists in Zig: an engine
that cannot block is an embedding's engine on the callback path. Which engine
ships by default is recorded in
[ADR-0228](ADR-0228-lmdb-is-loams-default-storage-and-applications-declare-their-capacity.md). Parameterizing
the LMDB-hosted behavior tests over the in-memory engine is not done.

## Alternatives Considered

- **The backend stays the seam.** Each engine implements read, commit,
  lookup, and recover itself. Rejected because the glue stays copied and the
  contract stays implicit.
- **The callback is the only seam.** Every engine lives in an embedding.
  Rejected because it loses native engines, native tests, and benchmarks, and
  the Zig product would hold no durable store of its own.
- **A runtime interface with function pointers.** Rejected because every
  current dispatch is compile-time, an indirect call buys nothing here, and
  engine-specific operations would lose their types.

## Consequences

The in-memory engine's overlay becomes its write transaction, and its read
path becomes a read transaction over the same rows. The LMDB engine's
prepared commit becomes its write transaction. The C executor's plan calls
the core's derivation instead of its own copy. One contract suite,
parameterized by engine, runs against both Zig engines and is where a new
engine is proven. The store guide describes the contract and the two ways in
instead of listing engines.

## Evidence and gate

The engine contract suite under `test/loam/` runs on the in-memory engine
in `zig build test` and on LMDB in `zig build loam-lmdb-test`. `zig build
loam-abi-test` proves the callback path, including a collection over the
callback store. `zig build loam-browser-test` sweeps a
collection in Chromium. `zig build gen-header-loam-lmdb-check` holds the LMDB
archive's header unchanged. `zig build source-check` holds this graph.

## Notes

ADR-0185 owns the C and Rust resource lifecycle this record leaves unchanged.
