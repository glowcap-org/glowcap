---
id: ADR-0239
status: accepted
date: 2026-10-14
tags: [loam, persistence, storage, sqlite, lmdb, benchmark]
decision: "SQLite is Loam's default disk engine for Zig, C and Rust. The Tasks comparison favors its durable mutation latency. LMDB remains supported behind the same transaction contract."
supersedes: []
superseded_by: []
amends: [ADR-0228]
amended_by: []
---

# ADR-0239 SQLite is Loam's default disk engine

## Context

[ADR-0228](ADR-0228-lmdb-is-loams-default-storage-and-applications-declare-their-capacity.md)
made LMDB the default without a second engine to compare.
[ADR-0233](ADR-0233-storage-engines-are-named-placed-and-opened-alike.md) added
SQLite behind the same transaction contract, with the same C verbs, Rust trait,
durable test suite and crash probes. `bench-loam` now runs the Tasks workload
on either engine, and the
[recorded comparison](../../../bench/loam/results.md#tasks-on-lmdb-and-sqlite-october-14-2026)
holds the numbers. They were measured while LMDB still read through a memory
map, before its page reads moved to system calls. Both engines use synchronous
durability on Linux. The report names the hardware, kernel and filesystem.
LMDB flushes its data pages and then writes metadata through an `O_DSYNC` descriptor. SQLite
syncs the WAL. Their durability protocols require different I/O sequences,
which are part of the measured cost.

The [controlled CPU comparison](../../../bench/loam/results.md#controlled-cpu-comparison-october-14-2026)
separates CPU placement from engine cost. On logical CPU 5 of the recorded
NVIDIA DGX Spark, LMDB wins cold reads
and SQLite wins durable changes. The earlier read comparison did not control
CPU placement and does not establish that SQLite's reads are faster.

The rule set before measuring was that the default goes to the engine no more
than a tenth slower on commit latency, hot and cold reads and file size. It
chose neither. LMDB commits took about 70 percent longer at p50. A five-read
share took about 30 percent longer on SQLite, because each SQLite read
transaction takes and releases a lock on the log's shared-memory index.

## Decision

**SQLite is the default disk engine.** Loam's guides, the C and Rust setup,
[Example 07](../../../examples/zig/07_durable_card.zig), the Tasks app and the
Rooms session server open `Sqlite`. The Rooms storage proofs that reopen a
session store also run on LMDB, so Rooms' data model exercises both engines.
LMDB keeps its archive, Rust type, suite and probes, and an application may
choose it. The browser still stores through IndexedDB.

**The choice weighs cost per operation a person waits on.** Every reply after a
change waits for its commit's flush:

- A commit took about 1.4 ms less on SQLite at p50 and about half as long at
  p95, in every phase that commits.
- A five-read share cost about 7 µs more, under one percent of one commit. A
  20-read cold chain is faster on LMDB with CPU placement controlled, and hot
  reads call neither engine. The recorded comparison owns the matched timings.
- The closed store was 6 percent smaller on SQLite.

**SQLite also keeps a store in service.** It compacts in place as one
transaction (`Sqlite.compact`), and a crash probe kills a vacuum mid-run. LMDB
compacts only through an offline replacement. On macOS both engines flush
through the drive's cache with `F_FULLFSYNC`, so the default changes no
durability claim.

**Both disk engines return a failed record read as an error.** SQLite reads
records with ordinary system calls. Stock LMDB reads through a memory map, where
a failed read ends the process with `SIGBUS`. Loam's LMDB build reads each page
with a system call before LMDB parses it, so it fails the way SQLite does. The
[LMDB operations guide](../../loam/lmdb.md#read-failures) says what that page
cache costs. Each engine still maps one small file to coordinate processes.

## Scope (what this does not decide)

- Faults in the coordination files. The read tests fail read system calls and
  cut data files short. They never damage the small mapped file each engine
  uses to coordinate processes.
- Power loss. Which assumptions either engine's flush supports across power
  loss is still unestablished, and the roadmap holds it.
- Other platforms and disks. The comparison ran on the
  [recorded NVIDIA DGX Spark](../../../bench/loam/results.md#october-14-measurement-environment)
  with a warm OS page cache.
- The slower cold-read mode near 400 µs that set p95 in two of eight SQLite
  runs and no LMDB run. Its cause is not isolated.
- The other `bench-loam` workloads keep measuring LMDB and say so in their
  rows.

## Alternatives Considered

- **Keep LMDB.** Rejected because its commits cost about 1.4 ms more each, and
  its compaction takes the store offline.
- **Name no default.** Rejected because a first durable program needs one
  engine, and two equal first paths would be two ways to do one job.
- **Close SQLite's read gap first.** Exclusive locking or a heap-held log
  index removes the per-read lock, but it confines the store to one connection
  and gives up the reader pool. Memory-mapped reads would cut read system
  calls, but they turn an I/O error into a process signal. Each costs more
  than 7 µs buys.
- **Catch LMDB's `SIGBUS` and substitute a page of zeros.** A prototype was
  rejected. LMDB keeps parsing the fake page before Loam can check for the
  fault, and a zeroed metadata page made LMDB abort. Pinning those pages would
  not protect a record value the caller is still reading after the transaction
  returns. Keeping zeros out of a commit would also need every reader to
  coordinate with the writer. Reading each page with a system call refuses a
  bad page before LMDB sees it, with no signal handler.

## Consequences

- `apps/tasks/zig/server.zig` and `board_test.zig` open `Sqlite`, and
  `tasks-app-test` restarts a SQLite store.
- Example 07, `docs/loam.md` and the C and Rust setup in
  `docs/loam/c-and-rust.md` open SQLite first.
- ADR-0228's measurements of LMDB stand as records. Its capacity declaration
  and exact-size record charge are unchanged.

## Evidence and gate

- `zig build bench-loam -Doptimize=ReleaseFast -- --tasks-only --cpu=5
  --engine=<engine>` runs the comparison on the recorded CPU. Choose an allowed
  CPU on other hosts. `--smoke` runs both engines under `check`.
- `zig build tasks-app-test` runs the board server across a restart of its
  SQLite store, and `zig build examples` runs Example 07.
- `zig build loam-sqlite-test` holds the full flush setting and every commit
  refusal, and the SQLite crash probes run under `runtime-check`.
- `zig build loam-io-fault-test` fails reads and cuts data files short on both
  engines, including while the caller still holds a value it read. Every
  process must survive, and every injected failure must fire.
