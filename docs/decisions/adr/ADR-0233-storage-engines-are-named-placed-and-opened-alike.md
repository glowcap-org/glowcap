---
id: ADR-0233
status: accepted
date: 2026-10-14
tags: [loam, persistence, storage, lmdb, sqlite, bindings]
decision: "Every Loam storage engine has the same shape: a layer and type named by the engine under one engines directory, a C archive with one ten-verb symbol family, a Rust type behind the sealed engine trait, a test root over the shared durable suite, and an operations page. An engine reports a failed commit as refused only when the library's own source proves the write never reached its commit point, and as uncertain otherwise. A value an engine returns is valid until the next operation on its transaction."
supersedes: []
superseded_by: []
amends: [ADR-0185, ADR-0228]
amended_by: []
---

# ADR-0233 Storage engines are named, placed, and opened alike

## Context

Loam asks one thing of a storage engine: transactions over byte-ordered keys.
`src/loam/core/backend.zig` derives the four operations a worker drives from
any engine, and `test/loam/core/engine_scenario.zig` proves one. Two engines
exist, and they are placed and named unevenly. The in-memory engine is one
file inside the core graph with no C or Rust door. LMDB is its own layer with
an archive, a Rust type, an operations page, seventeen test files, and six
crash probes, and all of those name LMDB even where the engine is incidental.
The directory holding both is called backends, while the docs use backend for
the derived worker operations. A second disk engine, SQLite, is planned, and
three engines on three patterns would be three places to get the contract
wrong.

Two contract gaps surfaced while planning it. The LMDB engine reports every
failed commit as uncertain, so a full map goes through recovery as if the
write might have landed. And the lifetime of a value an engine returns was
never written down: LMDB's values live until the transaction ends, the
in-memory engine's until the next write, and SQLite's would live until the
next statement step.

## Decision

**Vocabulary.** An engine is the thing a program opens and that holds bytes:
`Volatile`, `Lmdb`, and `Sqlite`. A backend is the read, commit, lookup, and
recover operations `core.backend` derives from an engine. Code and docs use
the two words that way and no other.

**Placement and names.** Each engine lives in `src/loam/engines/<engine>/`
as the layer `loam_<engine>` exporting one type named for the engine. Its
C archive is `glowcap_loam_<engine>` from the layer `c_abi_loam_<engine>`
under `src/c_abi/loam_<engine>/`, with the header
`include/glowcap_loam_<engine>.h`. Its Rust type is `glowcap::loam::<Engine>`
and implements the sealed `Engine` trait. Its test root is
`test/loam_<engine>_test.zig`, its build step `loam-<engine>-test`, and its
operations page `docs/loam/<engine>.md`. A procedure two disk engines share,
such as the lock file that holds custody of a store directory, lives at
`src/loam/engines/` beside them. A build registration file per engine lives
under `tools/build/loam/`.

**One symbol family.** An archive exports exactly these verbs, prefixed
`glowcap_loam_<engine>_`: `open`, `release`, `work_run`, `restore`, `commit`,
`collect`, `recover`, `last_error`, `clear_last_error`, and
`archive_fingerprint`. Only `open` is engine-specific. Its argument list is
the store identity, the open mode, the schemas, the limits, the two out
handles, and the engine's own physical arguments: a path and a map size for
LMDB, a path and a capacity in bytes for SQLite, a capacity in bytes for the
in-memory engine. The other nine are the bodies in
`src/c_abi/loam/executor.zig` instantiated for the engine.

**One durable suite.** The storage and managed-access tests that need a
durable engine take it from an `engine_fixture` module, and each engine's
test root supplies its own. A test about one engine's physical behavior stays
in that engine's test directory.

**Value lifetime.** A slice returned by `get` or `next` is valid until the
next `get`, `next`, `put`, or `remove` on that transaction, or until the
transaction ends. A caller that needs two values at once copies the first.
The derived backend already copies every record it reads into the request's
buffer, so this is the contract the core lives at today.

**Commit classification.** `commit` returns `committed` when the library
reports success, a refusal error when the library's own source proves the
write never reached its commit point, and `unknown` otherwise. The engine's
error mapping names, beside each refused code, the source fact that proves
it.

For LMDB the commit point is the metadata page write. Only its own
pre-commit error codes prove refusal. OS errors leave the outcome unknown
because they do not identify the failing stage. The adapter stops new engine
operations after an unknown outcome until exclusive recovery settles the write.

For SQLite only a lock conflict proves commit refusal, and the connection
must also be back in autocommit. Autocommit alone does not prove that a failed
WAL write left no commit frame. Disk-full and I/O errors stay unknown and stop
new work until reopen, when recovery reads the metadata row.

A refused `put` or `remove` applied nothing and ends the transaction on every
engine, so a commit never applies part of a batch.

## Scope (what this does not decide)

Which engine is the default is
[ADR-0239](ADR-0239-sqlite-is-loams-default-disk-engine.md)'s decision. The
browser's IndexedDB path through the C key-value callback is
not an engine in this sense and keeps its shape. Open arguments stay physical
and per engine, so there is no engine-neutral open.

## Alternatives Considered

- **Keep the engine directory and vocabulary as they are, and add SQLite
  beside LMDB.** Rejected because the docs already define backend as the
  derived operations, and a third engine would copy LMDB's seventeen named
  test files or skip the suite.
- **An engine-neutral C open taking a tagged union of physical arguments.**
  Rejected because one archive per engine is what lets an embedding link
  only the engine it ships, and the tag would need every archive to know
  every engine.
- **Leave every failed LMDB commit uncertain.** Rejected because recovery
  after a full map reads the store, finds the write absent, and reports
  absence, which is the answer the engine could have given without a read.
- **Values valid until the transaction ends, as LMDB offers.** Rejected
  because the in-memory engine does not offer it and SQLite cannot without a
  copy per value.

## Consequences

- `src/loam/backends/` becomes `src/loam/engines/`, `build.zig`'s layer
  table and `tools/build/loam.zig` follow, and `arch-check` holds the
  layer prefixes.
- `src/loam/engines/lmdb/mod.zig` maps commit codes under the classification
  rule with the proof beside each refusal.
- The in-memory engine gains `src/c_abi/loam_volatile/`, its header, and a
  Rust type. SQLite gains `src/loam/engines/sqlite/`, `src/c_abi/loam_sqlite/`,
  and `docs/loam/sqlite.md`.
- `test/loam/engines/` holds the shared durable suite, and each engine's root
  under `test/` supplies `engine_fixture`.
- `docs/loam/store.md` states the value lifetime and the classification rule
  once, and each operations page links it.

## Evidence and gate

`zig build check` holds the layer table, the generated headers and Rust
layouts, and the doc source paths through the move. Each engine's
`loam-<engine>-test` step runs the shared durable suite, and each crash step
runs its probe once per disk engine. A commit into a full LMDB map returns a capacity
refusal and the store accepts a smaller write afterward, in
`test/loam/lmdb/commit_test.zig`. A put past SQLite's page count is refused
at the put, ends the transaction, and leaves the store taking a smaller
write, in `test/loam/sqlite/engine_test.zig`.

## Notes

Amends ADR-0185 (the archive family is now the template every engine
follows) and ADR-0228 (its default engine gains a sibling behind one contract, and
ADR-0239 chooses between them).
