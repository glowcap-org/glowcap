# LMDB operations

LMDB is Loam's on-disk backend for Zig, C and Rust. This guide covers adding
it to a build, watching how full a store is, growing and compacting it,
closing it, and measuring it. [Stores, transactions and reads](store.md)
covers the Store contract that every backend shares.

## Adding the backend

The LMDB module comes from the same build dependency as glowcap:

```zig
exe.root_module.addImport("glowcap", dependency.module("glowcap"));
exe.root_module.addImport("glowcap_loam_lmdb", dependency.module("glowcap_loam_lmdb"));
```

The module exposes `Lmdb`, which runs blocking storage work on the
thread that calls it. The backend uses LMDB 1.0.2 and requires the LMDB 1.x
disk format.

## Commit ownership

`beginCommit` returns a handle that owns one LMDB transaction. Finish or abort
it on the worker that opened it. `finish` commits once and retains its outcome,
so calling it again returns the same result. `abort` affects only an active
transaction. It cannot undo a commit or turn an unknown outcome into absence.
The handle releases backend custody once, when it finishes or aborts.

## How full a store is

LMDB maps its file into memory up to a size you choose, so a store can fill.

`Lmdb.inspect()` reports the map size, the allocated page high water, the
current tree pages, and the key count. Tree pages exclude the free-page
database and metadata pages. High water includes pages LMDB can reuse, so map
size minus high water does not tell you how much the next write can consume.

When the map is full, the whole transaction is refused and the store is
unchanged.

## Growing the map

`Lmdb.grow(new_map_bytes)` enlarges the map between backend operations. It
refuses while another backend operation is active, and blocks new operations
while it remaps. A held Loam record lease stays usable because it owns copied
bytes. Choose a larger page-aligned size and commit normally; the next
successful write persists the new map setting. Choosing the size belongs to
your storage budget. Loam never retries with an unbounded map.

Settle outstanding write outcomes before any maintenance. If remapping fails,
`ReopenRequired` fences the backend, because the old mapping may be gone.
Close and reopen the backend and its Store through the normal opening path,
rather than continuing with mapped memory that may be invalid.

## Shrinking the file

[Collection](collection.md) frees database pages for reuse, but the file keeps
its size. Offline compaction writes a compact copy and swaps it in, while the
configured map limit stays as it was.

Before compacting, join storage workers, settle outstanding writes, and retire
the attached Host work and the Store. The backend holds writer custody through
copying, validation, installation and synchronization:

```zig
try backend.compact();
try backend.close();
backend = try Lmdb.open(path, .{ .mode = .{ .open = expected_store_id } });
```

Installation leaves the old backend fenced, even when the rename fails.
Reopening opens the installed file and claims a new incarnation.

`beginCompaction` returns an owned operation with `prepare`, `install`,
`finish` and `deinit`, for callers that need each phase separately. If
`finish` reports `InstallOutcomeUnknown`, retry the sync without repeating
installation. Canceling before installation leaves the source usable, unless a
concurrent close has already fenced it.

Only `data.mdb` counts on reopen. An incomplete `loam-compact.mdb` is ignored,
and the next operation deletes it under the same owner lock. Compaction needs
disk space for both files. It compares by streaming through bounded engine
copy buffers and allocates no Zig row copies. The directory must stay at its
opened path during validation.

The [replacement decision](../decisions/adr/ADR-0181-offline-lmdb-replacement.md)
states the filesystem, synchronization and failure assumptions.
`zig build loam-compaction-crash-test` exercises process loss and refused copy
capacity. Linux results and the macOS CI configuration do not establish macOS
execution or real power-loss behavior.

## Closing

`Lmdb.close` stops new work and reports `Busy` while a backend operation still
holds the environment. Finish or abort that operation, join its worker, and
close again.

The lifetime lock file stays in the directory after close, so two processes
can never lock different files at the same path. This advisory lock, BSD
`flock` on macOS and Linux, coordinates cooperating Loam adapters for the
whole time a store is open. Close explicitly releases the lock even while a
spawned child retains inherited descriptors before exec. Native storage handles
belong to their creating process and cannot be used in a forked child.
LMDB separately serializes write transactions.
Every writer must go through the adapter so Loam's cached state stays current;
writing to the LMDB file directly is outside this profile.

## Measuring a workload

`zig build bench-loam -Doptimize=ReleaseFast` runs ordinary actors and managed
resources through the shipped Host, Vat and LMDB interfaces. It measures:

- hot and cold calls, and unchanged records after edits;
- wakeup bursts, and collection beside queued reads;
- managed resource creation, use and control issuance, control chains, moves,
  child iteration, receipt-backed content edits and grant revocation, at
  shallow and deep ancestry;
- sustained ordinary and managed calls on a shared four-worker executor, with
  deterministic admission refusal and unrelated actor progress;
- foreign restoration through byte-fed sessions, larger held-facet working
  sets, and offline compaction.

Its smoke run, part of `zig build check`, validates replies, warm-record
reuse, commit counts, revocation refusal and complete Zig memory release.

The [workload method](../../bench/loam/README.md) owns populations, limits,
sampling and how to read a report. It separates Loam residency, tracked Zig
allocations, physical page geometry, and process memory it does not measure.
The [recorded results](../../bench/loam/results.md) keep the revision,
durability setting, read and allocation counts, and latency distributions. OS
snapshots report whole-process memory apart from the tracked Zig heap and LMDB
page geometry. Offered load uses a bounded closed-loop window. LMDB is the
first backend, so no comparison with other storage engines has been measured.
