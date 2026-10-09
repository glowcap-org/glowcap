# Browser resource storage

This guide is the browser half of the [C/Rust guide](c-and-rust.md): the same
resource profile, stored in the browser so it survives a page reload.

Rust's `loam` feature uses IndexedDB when compiled for `wasm32-unknown-unknown`.
It links the portable `libglowcap_loam` with the existing Host and OCapN Wasm
archives. The shared Zig engine owns record validation, managed admission,
transaction installation and recovery. The
[execution decision](../decisions/adr/ADR-0200-resumable-loam-batch-evaluation.md)
records the ownership boundary.

Use the schemas, policies and content registrations from the
[C/Rust lifecycle guide](c-and-rust.md). In the browser, opening, creation,
restoration and close are asynchronous:

```rust
let mut store = Store::open("documents", identity, true, &[schema], limits).await?;
let staged = store.stage_resource(&policy, schema, kind, initial, 2, owner_identity)?;
persist_private_resource(staged.resource().encode()).await?;
let resource = staged.commit().await?;
let mut attachment = store.attach(&host, registrations)?;
let (access, control) = attachment.restore(resource).await?;
```

The embedding supplies `persist_private_resource` and commits the private
anchor before resource submission. `Store::open_bootstrap` asynchronously opens
the exact persisted store identity or initializes known missing metadata.
Once an application root is confirmed, ordinary `Store::open` with `create=false`
requires its existing store. Both modes retain exclusive Web Lock custody.

Run Host work through the browser-driven Tokio `LocalSet`, using the existing
Host, Ref and Session. Browser storage callbacks run on that browser thread.
They schedule dependent IndexedDB requests during active request events;
they never hold a transaction across network or user interaction awaits.

## Custody and failure

Creation and reopening are explicit. Reopen uses `create = false` and the same
stable identity; missing storage or an identity mismatch refuses. Each opening
holds an exclusive Web Lock without stealing an existing owner and atomically
claims a new incarnation. Transactions fence old incarnations and revisions.
An attached Store cannot close until its Host work and callback custody end.
Successful detach releases content contexts exactly once.
Await `store.close()` to join database and Web Lock retirement before reopening.
Dropping its observer preserves the close task until lock release.

Physical storage tasks retain callbacks on the browser executor through the
terminal event, even if the embedding destroys its Tokio LocalSet. Host-bound
operations admit a delivery task on the existing LocalSet before starting I/O.
That task completes Work and releases abandoned results on the Host executor.
Restoration holds raw capability occurrences until the caller consumes them;
an acknowledgement keeps abandonment cleanup alive after result delivery.
Buffered results do not keep attachment or Host close waiting after physical
retirement. If the LocalSet itself ends, later explicit Host progress drains
the parked obligations; the binding does not create another executor.

Authority writes require the browser to confirm strict transaction durability.
Rooms private bootstrap writes use the same durability requirement and compare
the complete previous metadata in their transaction. A delayed preparation
cannot replace a root that another owner has already confirmed. Planner
refusals preserve their Rust error codes through the terminal abort event, so
proven absence remains distinguishable from malformed data or uncertain I/O.
Quota exhaustion aborts the complete owner, grant and content batch. There is
no volatile fallback. Origin storage can still be evicted, and same-origin
storage access is trusted embedding access. This is not isolation from hostile
scripts in the same origin.

Dropping an observer leaves the submitted transaction and its callbacks owned
until a terminal database event. If a creation result was abandoned, await
`recover_creation()` to observe that retained outcome. A committed creation
returns its original Resource; a known abort returns `UNCHANGED` and clears it.
An indeterminate write preserves the core barrier until exact receipt recovery.
Save resource metadata only after successful commitment or recovery.

## Bounds and evidence

The shared batch evaluator retains a cursor across missing reads. It validates
the immutable batch once, then emits writes directly into the active IndexedDB
transaction. Rust retains metadata and one supplied row, each copied once from
JavaScript. A write copies once into an owned JavaScript byte array; IndexedDB
serializes it before the callback returns. No Rust write overlay or growing row
snapshot exists. Completed read requests release their callback immediately.
C cursors live inline in the existing fixed Work slots or startup Store owner.

`Limits.record_bytes` bounds one encoded record, including its envelope and
checksum. The adapter's input allowance derives from that value, metadata,
bounded physical keys and fixed Plan state. Core staging, changes, edges and
retained calls bound submitted transaction work independently. IndexedDB still
owns the memory for its queued writes and database cache; the input allowance
does not bound that browser memory or guarantee available origin quota.

`storage_statistics()` reports transactions, planning passes, database rows,
emitted writes, copied bytes, peak input bytes, the derived input allowance and
maximum submitted write bytes per transaction. Copy accounting covers each
supplied row, missing key and write at the Rust/JavaScript boundary. It excludes IndexedDB's
internal structured cloning, browser database cache and Zig core costs.

`zig build loam-browser-test` drives the actual linked consumer under Chromium.
It creates, shares and edits a resource, reloads the page, cold-fetches the
original publication and replays a committed mutation receipt. It also checks
the same bounded managed-child/control trace as LMDB, including policy edits,
ancestor restriction, independent control retirement, persisted management
receipts and retained descendant revocation after page reload.
The shared inventory trace additionally exercises control-owned issuance while
use is paused and unable to delegate, independent inspection, label replay,
revision conflicts and cold indexed membership after reload. The shared field
trace checks append, replacement, removal, exact and dependent disclosure,
refused edits and cold restoration after reload. It checks
dependency-breaking and inapplicable raw derivation, policy editing and control attenuation
before and after reload, followed by valid requests with the same sequence. It checks
exclusive custody, content-context retirement, abandoned creation, quota rollback, mutation retry after refusal
and another actor's progress while storage is blocked. It checks configured
record bounds above the default and immediate reopen after awaited close.
Restoration proofs cover cancellation during blocked storage, buffered abandonment
with endpoint reuse on a live Host, buffered results through Host close,
partial endpoint failure and executor destruction before
physical retirement, followed by cleanup on later Host progress.
The runner reports
adapter costs for that bounded fixture; those figures are not a throughput
benchmark or a large-dataset browser measurement.

Registered content graphs use the same callback and transaction boundary.
`rooms-rust-browser-host-test` stages the actual session codec graph, reloads
the whole page and restores its exact fields and mutation receipt in a fresh
Wasm instance. That trace exceeds cache residency; it does not establish the
full Rooms capacity profile or replace production session storage.
`zig build rooms-session-graph-browser-test` runs that trace alone. The test
front masks one acknowledgment after a real commit and one after late quota
rollback, then holds the real recovery response. No provisional result escapes
before resolution; known absence preserves the old graph and sequence, while
applied recovery and receipt replay do not reinvoke content. The held response
is an observer of retired IndexedDB work, not an open physical transaction.

`rooms-rust-browser-host-test` also stores two disjoint populations of 3,592 foreign fields in
64-page graphs under derived call and transaction quotas. It checks exact URI
bindings after cold source Store/Host restoration, capacity refusal and receipt
replay. Its exporter survives in the same Wasm realm.
`zig build rooms-session-foreign-browser-reload-test` runs a separate two-page
trace. One page retains the exporter Host and publications while the source
page closes its owners and reloads completely. The fresh source restores every
exact field, probes actor identities and replays the receipt without invoking
content. The controlled RTC fixture pins the actual live Host keys and adopts
both readers before handshake. Its pages, RTC signaling, arrival promises and
proof inventories have separate test owners. Exporter restart and deployment
signaling are outside these traces.

This profile covers fixed-resource content and use/control methods. General
resource-graph operations, collection cursors and owner lifecycle
remain in the [foreign-language contract](../planning/loam/access/api.md#the-foreign-language-boundary).
Rooms still needs its own application storage and authority integration.
