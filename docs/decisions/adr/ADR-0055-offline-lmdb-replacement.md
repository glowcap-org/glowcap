---
id: ADR-0055
status: accepted
date: 2026-10-19
tags: ["loam", "persistence", "lmdb", "maintenance"]
decision: "Offline compaction holds lifetime writer custody, verifies every key and value against the source, and installs one data file by same-directory rename followed by directory sync."
supersedes: []
superseded_by: []
amends: []
amended_by: []
---

# ADR-0055 Offline LMDB replacement

## Context

LMDB compaction produces another database file. Replacing a live store without continuous writer custody or exact candidate verification can lose changes or install the wrong state.

## Decision

Offline compaction holds lifetime writer custody, verifies every key and value against the source, and installs one data file by same-directory rename followed by directory sync. Cancellation and each failure phase retain an explicit outcome.

The lock file remains stable across replacement. The embedding keeps the source closed for the operation, and available space must hold both the original and complete candidate. Map size remains an independent capacity limit.

## Alternatives and consequences

Copying while another writer can commit leaves an ambiguous snapshot boundary. Trusting size or metadata alone does not establish exact data equality. Replacing several files independently would create intermediate combinations without one commit point.

The contract assumes a local POSIX filesystem, advisory locking, atomic same-directory rename and synchronous file/directory operations. Network filesystems, uncoordinated mutation and hostile storage operators are outside it. A refused final sync needs its documented recovery rather than being reported as an unchanged operation.

## Evidence

[Compaction tests](../../../test/loam/lmdb/compaction_test.zig) cover cancellation, rename refusal, final-sync retry, exact data, reader bounds and reclaimed size. Process probes cover interruption. [LMDB operations](../../loam/lmdb.md) owns the procedure and limits.
