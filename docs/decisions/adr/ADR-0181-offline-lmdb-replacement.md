---
id: ADR-0181
status: accepted
date: 2026-10-02
tags: [loam, persistence, lmdb, maintenance]
decision: "Compact offline under continuous lifetime writer custody, verify every key/value before replacement, and install one data file with a same-directory rename and directory sync."
supersedes: []
superseded_by: []
amends: [ADR-0162]
amended_by: []
---

# ADR-0181 Offline LMDB replacement

## Decision

The native backend owns one compaction operation after workers are joined and
the associated Store is retired. Its lifetime owner lock remains on the same
inode throughout copying, source closure, installation and synchronization.
Maintenance blocks new backend work and refuses while a worker or prepared
native commit retains the environment.

Opening resolves an absolute path and retains the source directory descriptor.
The maintenance operation creates its reserved `loam-compact.mdb` file through
that directory. A changed working directory cannot select another store.
The directory must remain at its opened path during validation; moving it can
refuse preparation, and never redirects installation to another directory.

`Lmdb.Compaction.prepare` uses the pinned engine's `MDB_CP_COMPACT` copy,
flushes the candidate, checks store identity and opening incarnation, and
compares all keys and values with the quiescent source. Two streaming cursors
borrow mapped values; Zig allocates no row copies. LMDB owns its bounded copy
buffers and joins its copy worker before returning.
The comparison covers records, indexes, roots, receipts, exact totals,
retirement floors and any future typed restoration records without interpreting
their application schemas.

`install` closes source admission before a same-directory rename replaces
`data.mdb`. `finish` synchronizes the directory entry. After any installation
attempt, the old backend remains fenced until close; normal reopening claims a
fresh incarnation. A failed final sync returns `InstallOutcomeUnknown` and can
retry without repeating copying or rename. Deinitializing the operation releases
its maintenance reservation; closing the backend releases writer custody.

Recovery opens `data.mdb` alone. A leftover temporary file is never selected,
even if it is a valid copy. The next compaction discards it under owner custody.
No backup manifest, alternate authority selection, or rollback operation is
needed because installation preserves the complete logical state.

## Assumptions and evidence

The profile uses a local POSIX filesystem with advisory `flock`, atomic rename
within one directory, synchronous file writes and directory `fsync`. Cooperating
owners use the backend's lock and preserve its lock file. Network filesystems,
uncoordinated filesystem mutation and hostile storage operators are outside
this profile. Disk headroom must hold the current data file and the complete
compacted candidate together; map size remains an independent limit.

The [native tests](../../../test/loam/lmdb/compaction_test.zig) check cancellation,
rename refusal, a refused final sync and its retry, file shrinkage, exact metadata,
one-reader operation and continuous custody. Managed tests compact between
retirement steps and before cold terminal-receipt replay. The
[process proof](../../../test/loam/lmdb/compaction_crash_test.py) interrupts all
public phases, tests a native file-size limit, refuses competing owners, ignores
invalid leftovers and changes working directory after a relative-path opening.

Linux execution establishes those process-failure boundaries. The macOS job
includes the same checks; its configuration does not establish a successful
target-platform run. Hardware power loss and recovery from an older backup
require separate evidence and policy. The operation preserves the current
authority state; it does not repair an already corrupted store.
