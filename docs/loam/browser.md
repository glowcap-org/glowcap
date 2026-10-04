# Browser resource storage

This guide is the browser half of the [C/Rust guide](c-and-rust.md): the same
resource profile, stored in the browser so it survives a page reload.

Rust's `loam` feature uses IndexedDB when compiled for `wasm32-unknown-unknown`.
It links the portable `libglowcap_loam` with the existing Host and OCapN Wasm
archives. The shared Zig engine owns record validation, managed admission,
transaction installation and recovery. The
[execution decision](../decisions/adr/ADR-0186-loam-browser-transaction-execution.md)
records the ownership boundary.

Use the schemas, policies and content registrations from the
[C/Rust lifecycle guide](c-and-rust.md). In the browser, opening, creation and
restoration are asynchronous:

```rust
let mut store = Store::open("documents", identity, true, &[schema], limits).await?;
let resource = store.create_resource(&policy, schema, kind, initial, 2).await?;
let mut attachment = store.attach(&host, registrations)?;
let (access, control) = attachment.restore(resource).await?;
```

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

Authority writes require the browser to confirm strict transaction durability.
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

The adapter admits at most 1,024 loaded rows and 1,024 tentative writes per
transaction. Snapshots and tentative writes share a byte allowance equal to
the configured resident and staging budgets combined. Each loaded row copies
once into Rust; tentative values copy from Zig into the owned overlay and then
into JavaScript for IndexedDB. Re-evaluation discards its tentative overlay;
the retained snapshot remains bounded. C plans use the existing fixed Work slots.

`storage_statistics()` reports transactions, planning passes, database rows,
copied bytes and peak snapshot/overlay bytes. Copy accounting includes repeated
evaluation and the Rust/JavaScript adapter boundary. It excludes IndexedDB's
internal structured cloning, browser database cache and Zig core costs.

`zig build loam-browser-test` drives the actual linked consumer under Chromium.
It creates, shares and edits a resource, reloads the page, cold-fetches the
original publication and replays a committed mutation receipt. It also checks
the same bounded managed-child/control trace as LMDB, including policy edits,
ancestor restriction, independent control retirement, persisted management
receipts and retained descendant revocation after page reload. The shared field
trace checks append, replacement, removal, exact and dependent disclosure,
refused edits and cold restoration after reload. It checks
dependency-breaking raw derivation, policy editing and control attenuation
before and after reload, followed by valid requests with the same sequence. It checks
exclusive custody, content-context retirement, abandoned creation, quota rollback, mutation retry after refusal
and another actor's progress while storage is blocked. The runner reports
adapter costs for that bounded fixture; those figures are not a throughput
benchmark or a large-dataset browser measurement.

This profile covers fixed-resource content and use/control methods. General
graph operations, collection cursors and owner lifecycle
remain in the [foreign-language contract](../planning/loam/access/api.md#the-foreign-language-boundary).
Rooms still needs its own application storage and authority integration.
