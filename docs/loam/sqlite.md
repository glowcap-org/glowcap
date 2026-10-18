---
type: static
description: How to add and operate Loam's SQLite engine, including capacity and maintenance.
audience: human
sources:
  - resource: /src/loam/engines/sqlite/
  - resource: /test/loam/sqlite/
---

# SQLite operations

SQLite is Loam's default on-disk engine for Zig, C, and Rust. It keeps records
in a database file and a write-ahead log in the store directory.
[Stores, transactions and reads](store.md) covers the Store contract that every
engine shares.

## Adding the engine

The SQLite module comes from the same build dependency as glowcap:

```zig
exe.root_module.addImport("glowcap", dependency.module("glowcap"));
exe.root_module.addImport("glowcap_loam_sqlite", dependency.module("glowcap_loam_sqlite"));
```

The module exposes `Sqlite`, which runs blocking storage work on the thread
that calls it. It compiles the SQLite amalgamation pinned in `build.zig.zon`,
so no system library is needed. Open it with a store directory, a capacity in
bytes, and the number of reader connections to keep.

The file is `loam.sqlite`. It carries the application id `LOAM` and a user
version that names the row format, so a tool can tell it is a Loam store.
Opening refuses a file with any other application id and leaves it untouched.
Opening an existing store never creates a file and refuses an empty one
without writing to it.

## From C and Rust

`libglowcap_loam_sqlite` is the C archive, with the header
`glowcap_loam_sqlite.h`. It exports the same verbs as the LMDB archive.
The open verb takes `capacity_bytes` where LMDB takes a map size, and opens
the default number of reader connections. Rust enables the `loam` feature
and opens `Sqlite { path, identity, mode, capacity_bytes }` through
`Store::open`. [C and Rust](c-and-rust.md) covers the lifecycle both follow.

An open that fails returns the same codes as the LMDB companion, listed in
[opening refusals](c-and-rust.md#opening-refusals).

## Transactions and connections

One writer connection serves every write, and a write that finds it taken is
refused as `Busy` at once, never queued. Each read transaction takes one of
the reader connections opened with the store, and a read that finds none free
is refused as `ReaderCapacity`. A read sees one snapshot from its first `get`
or `next` until it ends, and a commit never waits for a read.

Each connection fills a page cache on the heap as it reads, up to SQLite's
[cache setting](https://sqlite.org/pragma.html#pragma_cache_size) of
<!-- value ../../src/loam/engines/sqlite/connection.zig page_cache_bytes bytes -->2 MiB<!-- /value -->
of pages. Page headers and SQLite's other working memory come on top. The
writer and each reader have separate caches, outside the Store's cache budget.

A refused `put` or `remove` ends the transaction with nothing applied, as on
every engine. A write past the capacity is refused at the put, not at the
commit. Reader connections are opened read-only. If SQLite ever ends a
transaction on its own, every later operation on it is refused, so a write
can never commit piecemeal.

## Durability

A commit is durable when it returns. SQLite syncs the write-ahead log at each
commit, and the engine sets `fullfsync` so macOS flushes the drive's own cache
with `F_FULLFSYNC`, as LMDB does. Linux builds sync with `fdatasync`.

## Commits

`commit` runs once and keeps its result, so calling it again returns the same
result. A failed commit is refused, with nothing changed, only when
SQLite's own code proves the commit frame never reached the log. A lock
conflict is a refusal. Disk-full and I/O errors leave the outcome unknown,
because a failed write can leave accepted bytes even after the connection
returns to autocommit.

After an unknown outcome the engine refuses ordinary work with
`ReopenRequired`. Follow the
[Store recovery steps](store.md#when-a-writes-outcome-is-unknown). Recovery
refreshes the connections under the existing directory lock and checkpoints
the whole log into the file before it reports the result, so it never reports
a commit that is not on disk.

## How full a store is

The capacity you open with is held as SQLite's page count limit, so the
database file cannot grow past it. The write-ahead log sits beside the file,
outside the capacity, and keeps
<!-- value ../../src/loam/engines/sqlite/mod.zig log_bytes bytes -->4 MiB<!-- /value -->.
A commit that fills it checkpoints the log into the file. A larger
transaction grows the log past that size until a later commit, after a
checkpoint, truncates it.

`Sqlite.inspect()` reports the capacity, the file size, and the bytes on
SQLite's free list, which later writes reuse first. A store can still take
about the capacity minus the file size, plus the free bytes.

## Growing the capacity

`Sqlite.grow(new_capacity_bytes)` raises the capacity to a larger whole number
of pages between engine operations, and refuses while a transaction is open.
The new capacity lasts until close. The next open names its own, so record
the size your storage budget allows and open with it.

## Shrinking the file

`Sqlite.compact()` rewrites the file without its free pages, in place, and
refuses while a transaction is open. SQLite's vacuum runs as one transaction,
so a crash leaves the store as it was or fully compacted. The engine then
checkpoints the log so the file shrinks before `compact` returns. If another
connection holds the log, `compact` returns `Busy` with the rows already
compacted, and the file shrinks at a later checkpoint or at close.

While it runs, the vacuum writes a copy of the live rows to a temporary file
and another to the log, so it needs about twice their size in free disk.
The temporary file goes in the directory `SQLITE_TMPDIR` or `TMPDIR` names,
or else the system's temporary directory.
`zig build loam-sqlite-compaction-crash-test` kills the process during and
after a vacuum and checks every live row in a fresh process.

## Closing

`Sqlite.close` stops new work and reports `Busy` while a transaction still
holds the engine. Finish or abort it, join its worker, and close again.
Closing the last connection checkpoints the log into the file. The lock file
stays in the directory after close, and the
[LMDB page](lmdb.md#closing) describes how it coordinates processes.
