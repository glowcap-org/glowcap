# Loam storage memory costs

The [memory ledger](../SKILL.md) owns the naming procedure. This reference
holds engine caches, staged records, and record residency costs.

- **Loam record staging**: `Record.encodeAlloc` measures before allocation and
  copies payload and typed edges once into the prepared record.
- **Loam record residency**: `Cache.acquire` reserves one bounded read buffer,
  because the backend reports a record's length only when it returns it.
  `Cache.complete` copies the record once into an exact-size buffer and frees
  the reservation, so the byte budget charges real record sizes and a cache of
  small records holds many more than its budget over `max_record_bytes`.
  During the copy, heap holds one record beyond the byte budget.

  Completion and leases retain the record until their owner releases it. `Slot` owns
  an exclusive empty/loading/resident state and one checked envelope beside
  resident bytes. The initialized slot array pays this fixed metadata cost.
  Borrowing a view allocates nothing and repeats no record validation.
- **Loam sparse directory staging**: `DirectoryEdit.stage` encodes and copies
  each changed page once. Unchanged child mappings propagate their existing
  identity without another proposal. An existing leaf edit stages one page
  with two allocations, pinned by the directory cost test.
- **Engine read materialization**: `core.backend.readRecord` copies the
  requested row into that buffer before ending the engine's read transaction,
  for every engine.
- **SQLite page cache**: `connection.openHandle` requests `page_cache_bytes`
  per connection, filled as pages are read. The writer and each reader have
  separate caches outside Store residency. Page headers and other SQLite
  working memory add to this target.
- **LMDB checked page cache**: `Lmdb` uses bounded page-entry tables owned by
  LMDB, outside Store residency. A miss copies a page or complete overflow
  extent with checked reads before parsing. Anonymous backing keeps returned
  borrows independent of later disk faults. Accepted writes update cached
  copies before commit publication. The disk format and capacity stay separate
  from resident cache bytes.
- **Disk engine recovery configuration**: `Lmdb.directory` and
  `Sqlite.directory` retain a fixed canonical path beside capacity and reader
  settings for the engine's lifetime. Recovery can close failed handles and
  retry opening them under the same owner lock without a new allocation or
  incarnation. This fixed engine memory is outside Store residency.

- **Borrowed LMDB inputs**: every `Kv` operation in
  [`kv.zig`](../../../../src/loam/engines/lmdb/kv.zig) copies only slices that
  overlap the preceding returned row (`Kept`). LMDB can evict that row's
  cached page or move the row while consuming an input. Copies that fit two
  keys use a stack buffer, and longer inputs
  take one temporary C allocation the call frees. Caller-owned inputs take no
  allocation or copy. SQLite instead keeps the source statement alive
  through the write. Its `Connection.next` preserves a borrowed prefix in a
  fixed `max_key_bytes` stack buffer before resetting the source statement.
- **Loam committed residency**: `Store.retainOnCommit` transfers prepared
  record buffers to eligible cache slots during installation, without another
  allocation or copy. Admission establishes the checked envelope once. Views
  reuse it. Pinned snapshots cannot be displaced. A full cache leaves
  the buffer with its transaction owner for release.
- **Loam collection custody**: `Store.captureCollectionCustody` creates one
  bounded `Custody` journal and record-sized worker scratch per cycle.
  - Root capacity grows only within `max_collection_roots`. New custody reserves
    before publication. A resident portrait reports its strong edges once per
    cycle, and its marker fits the existing slot.
  - `Store.prepareCollection` borrows pending obligations and reuses scratch.
    Backend tracing copies the current row there before writes invalidate mapped
    borrows. Allocations survive batch abort and commit-outcome recovery, and are
    freed at completed idle or Store teardown.
  - `Store.retain` uses the fixed registry allocated at Store initialization.
    Marks and pending trace entries occupy backend storage, not actor residency.
  - Confirmed collection receipts alone acknowledge submitted roots. The
    collection-cost smoke profile holds one submission per unchanged root and
    one scratch allocation per cycle.
