---
type: static
description: How to add and operate Loam's LMDB engine, including capacity and maintenance.
audience: human
sources:
  - resource: /src/loam/engines/lmdb/
  - resource: /test/loam/lmdb/
  - resource: /tools/gen/checked_lmdb.zig
  - resource: /tools/build/loam/lmdb.zig
---

# LMDB operations

LMDB is one of Loam's on-disk engines for Zig, C and Rust, beside the default,
[SQLite](sqlite.md). [Stores, transactions and reads](store.md) covers the
Store contract that every engine shares.

## Adding the engine

The LMDB module comes from the same build dependency as glowcap:

```zig
exe.root_module.addImport("glowcap", dependency.module("glowcap"));
exe.root_module.addImport("glowcap_loam_lmdb", dependency.module("glowcap_loam_lmdb"));
```

The module exposes `Lmdb`, which runs blocking storage work on the
thread that calls it. The engine uses the LMDB commit pinned in
`build.zig.zon` and requires the LMDB 1.x disk format.

## Commits

`beginWrite` returns a write transaction that owns one LMDB transaction.
Commit or abort it on the worker that opened it. `commit` runs once and keeps
its result, so calling it again returns the same result. A commit after abort
is refused as closed. `abort` cannot undo a commit or turn an unknown outcome
into absence.

A second writer is refused as `Busy` at once instead of waiting inside LMDB,
so it never starts after another writer's outcome became unknown.

A failed commit is refused with nothing changed only when an LMDB error proves
the write never reached the metadata page. OS errors, including a full disk,
do not say which stage failed, so they leave the outcome unknown. After an
unknown outcome the engine refuses ordinary work with `ReopenRequired`. Join
workers, finish existing readers, and follow the
[Store recovery steps](store.md#when-a-writes-outcome-is-unknown). Recovery
refreshes the LMDB environment under the existing directory lock and flushes it
before it reports the result.

## Read failures

A disk error during a read comes back as an error, and the process keeps
running. Stock LMDB reads its file through a memory map, where a failed read
ends the process with `SIGBUS`. Loam's build reads each page with an ordinary
system call into memory it owns. LMDB sees the page only after the whole read
succeeds, so a short or failed read never reaches its parser.

Those pages form a cache outside the Store's cache budget. Its limit counts
entries, not bytes, and one large value can fill several pages in one entry.
A cache miss allocates memory and copies the page from the OS page cache. A
write also copies its bytes into any cached page it overlaps.

A value you read borrows this memory until your next operation on that
transaction. Reading the borrowed value never touches the disk. The
[engine contract](store.md#adding-a-storage-engine) covers input borrows and
transaction lifetimes.

A commit updates cached pages before it becomes visible. Older readers keep
their snapshots, and new readers see the committed pages. LMDB's reader table,
the small lock file that processes share, is memory-mapped, and the read
failure tests do not cover it.

The build patches the pinned LMDB source and fails if an LMDB update no longer
matches the patch. The file format is LMDB's own. [Stability](../stability.md)
lists what the failure tests cover.

## How full a store is

You choose the largest size the file may reach, so a store can fill. The
setting keeps LMDB's name, `map_bytes`, though Loam maps nothing at that size.

`Lmdb.inspect()` reports that limit, the allocated page high water, the
current tree pages, and the key count. Tree pages exclude the free-page
database and metadata pages. High water includes pages LMDB can reuse, so the
limit minus high water does not tell you how much the next write can consume.

Reaching the limit refuses the whole transaction and leaves the store
unchanged. A full disk is different: it leaves the outcome unknown, as
[Commits](#commits) describes.

## Growing the limit

Recover any write whose outcome is unknown before you grow or compact a store.

`Lmdb.grow(new_map_bytes)` raises the limit between engine operations. It
refuses while another engine operation is active and holds new ones back until
it finishes. A lease you hold on a record stays usable because it owns copied
bytes. Choose a larger page-aligned size from your storage budget, then commit
as usual: the next successful write saves the new limit. `grow` refuses a size
larger than the OS allows for a file. Loam never grows the limit on its own.

## Shrinking the file

[Collection](collection.md) frees database pages for reuse, but the file keeps
its size. Offline compaction writes a compact copy and swaps it in. The
`map_bytes` limit stays as it was.

Before compacting, join storage workers, settle outstanding writes, and retire
the attached Host work and the Store. The engine holds the writer lock while
it copies, checks, installs, and syncs the copy:

```zig
try engine.compact();
try engine.close();
engine = try Lmdb.open(path, .{ .opening = .{ .id = expected_store_id, .mode = .open } });
```

After installation the old engine refuses all work, even when the rename
fails, so close it and reopen.

`beginCompaction` returns an owned operation with `prepare`, `install`,
`finish` and `deinit` for callers that need each phase separately. If
`finish` reports `InstallOutcomeUnknown`, retry the sync without installing
again. Canceling before installation leaves the source usable unless a
concurrent close has already shut it.

Compaction needs disk space for both files, and the directory must stay at
its opened path while the copy is checked. The check streams both files
through fixed-size buffers. Reopening reads only `data.mdb`. An incomplete
`loam-compact.mdb` is ignored, and the next operation deletes it.

The [replacement decision](../decisions/adr/ADR-0181-offline-lmdb-replacement.md)
states the filesystem, synchronization and failure assumptions.
`zig build loam-lmdb-compaction-crash-test` exercises process loss and refused copy
capacity. [Stability](../stability.md) says which platforms and failures it
covers.

## Closing

`Lmdb.close` stops new work and reports `Busy` while an engine operation still
holds the environment. Finish or abort that operation, join its worker, and
close again.

An open store holds an advisory `flock` on its lock file, so another process
that opens it through Loam is refused until it closes. The lock file stays in the
directory after close, so two processes never lock different files at the
same path. Close releases the lock even while a spawned child still holds
inherited descriptors before exec.

- Storage handles belong to the process that created them and cannot be used
  in a forked child.
- Every writer must go through Loam so its page cache stays current. Writing
  to the LMDB file directly is unsupported.

## Measuring a workload

Follow the [workload guide](../../bench/loam/README.md) to measure actors,
managed resources, collection, and the Tasks board app on the relevant engine. The
[recorded results](../../bench/loam/results.md) name each revision, workload,
durability setting, and measurement limit. A result from stock LMDB, which
reads through a memory map, does not measure this build's page cache.
