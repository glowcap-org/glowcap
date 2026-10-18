---
id: ADR-0228
status: accepted
date: 2026-10-14
tags: [loam, persistence, storage, lmdb, indexeddb, benchmark]
decision: "Loam's default storage is LMDB with a synchronous flush at every commit for Zig, C and Rust, and IndexedDB in the browser. No second engine is added, because the Tasks, scale and browser measurements located no limit in LMDB, within the scope this record lists. An application declares its capacity limits from its own data shape, and the Store's defaults size only a small embedding. The record cache charges each resident record its encoded size."
supersedes: []
superseded_by: []
amends: [ADR-0159]
amended_by: [ADR-0233, ADR-0239]
---

# ADR-0228 LMDB is Loam's default storage, and applications declare their capacity

## Context

Rooms was the only application on Loam, so nothing showed whether the storage
setup fit anything but chat. Tasks is a second application with a different
shape: a board of lists of tasks, moves that change three resources in one
call, read-only shares, and watchers that catch up after a restart
([ADR-0227](ADR-0227-hosted-calls-create-share-and-change-several-resources.md)).
`bench-loam` measures Tasks, cold reads over 10 thousand and 1 million
stored resources, and the browser binding's crossings per operation. The
[recorded results](../../../bench/loam/results.md) hold the numbers.

The open question was whether those numbers point at the storage engine. The
storage research
([ADR-0159](ADR-0159-memory-and-persistence-research.md)) names SQLite or a
custom pager only once a measurement locates a limit in LMDB itself.

## Decision

**LMDB with synchronous commits is the default.** Zig, C and Rust embeddings
store through LMDB, and every acknowledged commit is flushed before it is
reported. The browser stores through IndexedDB. There is no asynchronous or
no-sync profile, because a reply that says a change happened must survive a
crash.

**No second engine now.** None of these measurements found LMDB to be the limit:

- A Tasks change costs 3 to 4 ms at p50 on the recording machine, and an
  ordinary one-record edit with the same synchronous flush costs about 2.4 ms.
  This measures LMDB's flush protocol, not a cost shared by every equally
  durable engine. [ADR-0239](ADR-0239-sqlite-is-loams-default-disk-engine.md)
  compares its data and metadata flushes with SQLite's WAL. The rest of the
  gap, from the change history, receipts and hosted call, was not isolated.
  An application makes fewer flushes by changing several resources in one hosted
  call, which already commits once.
- A cold read reads a fixed number of records. Going from 10 thousand to 1
  million resources under one owner added one read per call, because the
  resource index has fixed depth, and no phase scanned the store or created an
  actor per resource.
- Hot reads touch no storage at all.

[ADR-0217](ADR-0217-loam-storage-engines-implement-one-transaction-contract.md)
keeps another engine cheap to add once a measurement does locate a limit.

**An application declares its capacity.** The Store's limits and the hosting
attachment's call memory and endpoint count have defaults sized for a small
embedding. Tasks outgrew them at its own documented maximum: moving a task
between two full lists needs more than the default call memory, and clients
holding every task on a full board need more live capabilities than the
default allows. Tasks derives both from its board shape as named
constants, and a test fills a list to its limit. Every application does the
same from its own shape. A larger default would only move the cliff.

**The record cache charges real sizes.** A cold read reserves a maximum-size
buffer because the engine reports a record's length only when it returns it.
Completion copies the record into a buffer of its encoded size and frees the
reservation. Charging the reservation alone would let a 32 MiB cache with
64 KiB records hold only 512 records whatever their real size.

## Scope (what this does not decide)

- Power loss. Which LMDB assumptions hold across power loss is its own roadmap
  item, and its evidence is a hardware test.
- Cold disk. The measurements leave the OS page cache warm, so cold means
  evicted from Loam's record cache only.
- Several processes or concurrent writers on one store. Each store has one
  exclusive owner.
- Browser latency and UI responsiveness. The browser figures count crossings,
  transactions and copies. A cold browser read after a reload makes 18
  IndexedDB transactions, and their latency is not measured.
- Bulk loading. One transaction holds at most `ChangeBatchRecord.max_effects`
  resource changes for one owner (ADR-0179), so loading 1 million resources took
  62,500 commits.
- Machines other than the one recorded.

## Alternatives Considered

- **Build a SQLite engine to compare.** Rejected because no measurement pointed
  at LMDB, and a comparison without a located limit cannot change the choice.
- **Asynchronous commits by default.** Rejected because an acknowledged change
  must survive a crash. Batching changes into one call buys the same throughput
  without losing that.
- **Larger Store defaults.** Rejected because only the application knows its
  record sizes, fan-out and how many capabilities its clients hold.

## Consequences

- `Cache.complete` (`src/loam/core/residency.zig`) copies each loaded record to
  its exact size. A read that cannot get memory for the copy fails and leaves
  nothing resident.
- `apps/tasks/zig/storage.zig` declares its record, call and live-capability
  limits from `board.max_lists` and `board.max_tasks`.
- `bench-loam` gains `--tasks-only` and `--scale-only`, and the browser proof
  reports each operation's crossings.

## Evidence and gate

- `zig build bench-loam -- --smoke` runs the Tasks and scale workloads under
  `check`, with their read ceilings, residency budget and actor checks.
- `zig build tasks-app-test` fills a list to its limit and moves a task between
  two full lists.
- `zig build loam-browser-test` asserts that JavaScript calls equal
  transactions plus writes, and that warm reads and receipt replays touch no
  storage.
- `zig build test -Dtest-layer=loam` holds the cache's exact-size charge
  through its allocation tests.
