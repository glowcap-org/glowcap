---
id: ADR-0062
status: accepted
date: 2026-10-19
tags: ["loam", "persistence", "storage", "sqlite", "lmdb", "benchmark"]
decision: "SQLite is the default disk engine for Zig, C and Rust setup, examples and the managed Rooms session."
supersedes: []
superseded_by: []
amends: []
amended_by: []
---

# ADR-0062 SQLite as the default disk engine

## Context

A first durable application needs one recommended engine. A matched Tasks workload found different costs in LMDB's data/metadata flush protocol and SQLite's WAL, so the default must weigh the operations users actually wait for.

## Decision

SQLite is the default disk engine for Zig, C and Rust setup, examples and the managed Rooms session. LMDB remains supported behind the same transaction contract. Browser storage remains IndexedDB.

The recorded comparison favors SQLite's durable changes and smaller closed store. With CPU placement controlled, LMDB wins the cold record-read comparison. Hot reads call neither engine. The commit savings dominate the measured read gap for the compared interactive workload.

SQLite also compacts in service through one transaction. LMDB uses its separately verified offline replacement procedure. Both preserve the configured synchronous durability posture.

Record-read failures are ordinary errors. Loam's LMDB build reads data pages through system calls rather than letting a failed mapped read terminate the process. Both engines still use small mapped coordination files, which remain outside those read-fault probes.

## Alternatives and consequences

Keeping LMDB would retain its measured commit cost and offline compaction. Naming no default would export the choice into every first program. Removing SQLite's read locks or mapping records could trade away concurrency or ordinary error handling for a small measured saving.

The comparison used one recorded Linux machine and warm operating-system page cache. It does not establish cold-disk performance, every workload, hardware power-loss recovery or immunity to coordination-file faults. The slower SQLite tail mode remains an explicitly unisolated observation.

## Evidence

[The matched report](../../../bench/loam/results.md#tasks-on-lmdb-and-sqlite-october-14-2026) and [controlled CPU comparison](../../../bench/loam/results.md#controlled-cpu-comparison-october-14-2026) own the measurements. Shared durable suites, process-loss tests, Tasks restart and I/O-fault probes establish the scopes described in [stability](../../stability.md).
