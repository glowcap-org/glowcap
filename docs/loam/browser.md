---
type: static
description: How Rust stores Loam resources in the browser with IndexedDB so they survive a page reload.
audience: human
sources:
  - resource: /bindings/rust/src/loam/
  - resource: /apps/rooms/rust/browser/src/storage/
---

# Browser resource storage

In the browser, Rust stores the same single-resource model as the
[C and Rust guide](c-and-rust.md) in IndexedDB, so it survives a page reload.
Rust's `loam` feature uses IndexedDB when compiled for
`wasm32-unknown-unknown`, linking `libglowcap_loam` with the Host and OCapN
Wasm archives. Loam's Zig code still checks records and permissions, commits
transactions, and runs recovery.
[ADR-0048](../decisions/adr/ADR-0048-loam-persistence-foundation.md)
records how the work is split.

Schemas, policies, and content registrations are the same as in the C and
Rust guide. Opening, creating, and closing are asynchronous:

```rust
let mut store = Store::open("documents", identity, true, &[schema], limits).await?;
let staged = store.stage_resource(&policy, schema, kind, initial, 2, owner_identity)?;
persist_private_resource(staged.resource().encode()).await?;
let resource = staged.commit().await?;
let mut attachment = store.attach(&host, registrations)?;
let (access, control) = attachment.restore(resource).await?;
```

`persist_private_resource` is your code, and it must save the resource's name
before the resource is committed. The browser store opens by name, because
IndexedDB is the only engine there. `Store::open_bootstrap` opens the store
for a saved identity, or creates it if it is missing. Once your program knows
the store holds its application root, use `Store::open` with `create=false`
and the same identity, so a missing store or a different identity is an error.

The Rust binding drives IndexedDB work on the browser-driven Tokio `LocalSet`,
alongside `Host`, `Ref`, and `Session`. Storage callbacks run on the browser's
main thread and queue the next IndexedDB requests while the current request
event is still active. No transaction stays open across a network or user
wait.

## Opening, closing, and failure

- Each open takes an exclusive Web Lock, never steals it from another tab,
  and starts a new Store. A browser without Web Locks refuses the open. Transactions refuse writes from an older Store or
  revision.
- A Store with an attachment cannot close until its Host work and callbacks
  finish. A successful detach releases content contexts once.
- Await `store.close()` before reopening, so the database and the Web Lock are
  released. Dropping that future does not cancel the close, which runs until
  the lock is free.

A storage task keeps its callbacks on the browser's executor until IndexedDB
reports a final event, even if your program destroys its Tokio `LocalSet`, and
the binding creates no executor of its own. If the `LocalSet` ends, the next
call that drives the Host finishes the waiting work
([`browser.rs`](../../bindings/rust/src/loam/browser.rs)).

Every Loam write requires IndexedDB's `strict` durability setting, and a
browser that cannot provide it refuses the write. Rooms, glowcap's chat
application, writes its private startup record with the same setting and
compares the whole previous record in that transaction, so a slow preparation cannot
replace a root another tab has already saved.

- A refusal from Loam keeps its Rust error code through the final abort event,
  so "nothing was written" stays distinct from bad data or an I/O failure
  with an unknown outcome.
- Running out of quota aborts the whole owner, grant, and content batch, and
  nothing falls back to memory.
- The browser can still evict an origin's storage, and any script in the same
  origin can read it, so it offers no isolation from a hostile script on that
  origin.

Dropping an observer leaves the submitted transaction and its callbacks alive
until the database reports a final event. If a creation result was abandoned,
await `recover_creation()` to learn how it ended, as in the
[C and Rust lifecycle](c-and-rust.md#the-lifecycle-step-by-step).

Save resource metadata only after a successful commit or recovery.

## Limits and tests

When Loam checks a write batch and needs a row it has not read yet, it
remembers where it stopped and resumes once the row arrives. It checks the batch once, then writes straight into the open
IndexedDB transaction.

- Rust keeps the metadata, one row passed in, and one row being walked, each
  copied once from JavaScript.
- Each write is copied once into a JavaScript byte array, which IndexedDB
  serializes before the callback returns.
- Rust keeps no copy of pending writes and no growing list of rows.
- A completed read releases its callback at once.
- C cursors live inside the fixed work slots or the Store.
- Collection walks rows with one IndexedDB cursor request per row, which
  returns the key and value together.

`Limits.record_bytes` bounds one encoded record, including its header and
checksum. The engine's input limit follows from that value, the metadata, the
key sizes, and the planner's fixed state. The Store's own limits on staging,
changes, edges, and call memory bound each transaction separately. IndexedDB
still owns the memory for its queued writes and its cache, and the input
limit neither bounds that memory nor guarantees the origin has quota left.

Each read is its own IndexedDB transaction. A transaction's latency overlaps
only with other transactions already in flight, so the reads ahead that
`Limits.read_ahead` allows set how much of that latency a long restore hides.

`storage_statistics()` reports transactions, planning passes, database rows,
writes, copied bytes, the largest input seen, the input limit, the largest
write per transaction, and the crossings between Rust and JavaScript
(`js_calls` and `callbacks`). Copied bytes leave out IndexedDB's own
structured cloning, the browser's database cache, and Loam's Zig code.
[`plan.rs`](../../bindings/rust/src/loam/browser/plan.rs) defines each count.

`zig build loam-browser-test` runs the linked program in Chromium
([`bindings/proofs/loam_browser/`](../../bindings/proofs/loam_browser/)). It
runs the create, share, edit, cold fetch, and resend lifecycle, and the same
managed-child, inventory, and field traces as the disk-engine tests, with a
page reload between steps. It also covers the Web Lock, abandoned creation,
quota rollback, and restoring while storage is blocked or the executor is
gone.

The test prints the change in `storage_statistics()` around a cold read, a
warm read, an edit, a resent request, and a share of its one resource. It
checks that JS calls equal transactions plus writes on an open database, and
that warm reads and resent requests touch no storage. The
[recorded results](../../bench/loam/results.md) keep the other numbers by
date. They are not a throughput benchmark or a large-dataset measurement.

Two Rooms tests use the same callbacks and transactions:

- `rooms-rust-browser-host-test` stores the session's record graph, reloads
  the page, and restores its exact fields and receipt in a fresh Wasm
  instance. It also stores two sets of remote fields in <!-- value ../../apps/rooms/rust/application/src/content/session/records.rs MAX_PAGES -->64<!-- /value -->-page graphs under
  call and transaction limits, and checks restoring, refusal at capacity, and
  resending.
- `zig build rooms-session-graph-browser-test` runs the graph trace alone. It
  hides one acknowledgement after a real commit and one after a late quota
  rollback, and no unconfirmed result escapes before recovery decides. When
  nothing was written the old graph stays, and a recovered commit does not
  run the content again.

`zig build rooms-session-foreign-browser-reload-test` uses two pages. One page
keeps the Host that exported the capabilities, while the other closes and
reloads, then restores every field and resends the receipt without running
content again. Restarting the exporting Host and deployment signaling are not
covered, and none of these tests shows the full Rooms capacity or replaces
production session storage.

The browser supports single-resource content, the use and control methods,
and bounded collection steps. Owner-only operations and general operations on
resource trees stay in Zig, as the
[managed access API](access-api.md#c-and-rust-bindings) describes.
