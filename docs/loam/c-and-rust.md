---
type: static
description: How C and Rust programs create, share, edit, and persist one managed resource without writing Zig.
audience: human
sources:
  - resource: /src/c_abi/loam/
  - resource: /bindings/rust/src/loam/
---

# C and Rust resource lifecycle

C and Rust programs use Loam's managed resources without writing Zig. This
guide covers one shape: a single resource, such as one shared board, that you
create, share, edit, and keep across a restart. The [Loam guide](../loam.md)
explains the terms.

- **Create** the resource and the content record behind it.
- **Share** it by deriving a *facet*: a narrower capability for one grant,
  handed to a peer as an ordinary `Ref`. A separate *control* capability can
  later pause, resume, or revoke that grant.
- **Edit** the content and its access policy, including the references the
  content holds.
- **Restart** and fetch it cold: reopen the store, and a peer fetches the same
  durable name to reach the content again, with nothing loaded at startup.

Loam's Zig code decides who may do what, the order of transactions, and what a
retried request returns. Your C or Rust code supplies the content's behavior
and runs the storage work, as
[ADR-0185](../decisions/adr/ADR-0185-loam-c-and-rust-resource-lifecycle.md)
records. The content behind one resource can span a bounded graph of pages.
Creating, sharing, and moving resources inside a tree
([Zig hosting](access-endpoints.md#calls-that-change-several-resources)) and
the operations only a resource's owner may run are available from Zig only.

## Setting up

Link `libglowcap_loam` beside the Host archives, plus one engine archive:

- `libglowcap_loam_sqlite` for SQLite, the default on disk
  ([SQLite operations](sqlite.md#from-c-and-rust))
- `libglowcap_loam_lmdb` for LMDB
- `libglowcap_loam_volatile` for a store in memory
  ([in-memory operations](volatile.md#from-c-and-rust))

Rust enables the `loam` feature and uses
`loam::{Store, Schema, Limits, Policy, Registration, Content}` with `Host`,
`Ref` and `Session`. Opening, creating, and restoring the owner's capabilities
block on disk, so finish them before you accept connections. Run Host work on
a Tokio `LocalSet` and engine jobs on a blocking executor. The
[browser guide](browser.md) uses the same resource model with IndexedDB, where
those steps are asynchronous.

Each piece of storage work runs as its own task on the `LocalSet`, so the Host goes on
sending and receiving while it runs, and no caller's future holds it. When the
work finishes, its task drives the Host again. A failure that the finished
work cannot hand to an operation becomes the Host's background failure.
Closing the Host or an attachment waits for the storage work in flight and
finishes what it enabled before releasing the attachment.

In Rust, prepare the resource, save its name where your program keeps private
startup data, and only then commit it. `persist_private_resource` below is
your code:

```rust
let store = Store::open(Sqlite { path, identity, mode: OpenMode::Create, capacity_bytes }, &[schema], limits)?;
// or: Lmdb { path, identity, mode: OpenMode::Create, map_bytes }
// or: Volatile { identity, capacity_bytes }
let staged = store.stage_resource(&policy, schema, kind, initial, 2, owner_identity)?;
persist_private_resource(staged.resource().encode())?;
let resource = staged.commit()?;
let attachment = store.attach(&host, registrations)?;
let (access, control) = attachment.restore(resource)?;
```

### Opening refusals

Every engine archive refuses a failed open with a code you can branch on, and
`last_error` names the cause. A refused open leaves no store handle. The
in-memory open has no directory, so it returns `NOT_FOUND` for `create=0` and
never `WOULD_BLOCK`.

| Return code | Cause |
| --- | --- |
| `GLOWCAP_ERR_NOT_FOUND` | Opening with `create=0` found no store, or the directory is missing. |
| `GLOWCAP_ERR_WOULD_BLOCK` | Another process has the directory open. Retry when it closes. |
| `GLOWCAP_ERR_IO` | A storage call failed, or the first commit's outcome is unknown. Reopen to find out. |
| `GLOWCAP_LOAM_ERR_CORRUPT` | The store's metadata is damaged. Retrying cannot repair it, so restore the directory from a backup. |
| `GLOWCAP_ERR_INVALID_ARGUMENT` | The map size, capacity, or schemas are unusable, or the file is not this store (another identity, or a file from another program or a newer version). |

## The lifecycle, step by step

1. Open the store with a stable 16-byte store identity and your bounded
   application schemas.
   - In Rust, the `Sqlite` value names the directory, identity, open mode, and
     `capacity_bytes`, the most the database file may grow to. It must be at
     least 1 MiB, and it is separate from the cache and pending-write limits
     in `Limits`.
   - The `Lmdb` value takes `map_bytes` instead, the largest size its file may
     reach.
   - A write that would pass the capacity is refused and changes nothing. Close
     and reopen with a larger size to make room.
   - Creating refuses an existing store, and opening refuses a missing or
     mismatched one. One process holds the store at a time.
2. Define a policy and create the resource.
   - A policy lists sorted, distinct permission keys and lower and upper
     bounds. `Policy::with_dependencies` also takes
     `(permission, prerequisite)` pairs. Every permission a grant or edit
     allows must bring its prerequisites along, and a refusal grants nothing.
     Each method can require its own permissions.
   - Stage the resource before attaching, save what `Resource::encode()`
     returns, then commit the staged resource. Dropping or aborting it before
     you submit it discards it. The saved name restores nothing until the
     records commit, and the name of an aborted resource is never reused.
   - `create_resource` stages and commits in one call when you do not need to
     save the name first. If it reports `RECOVERY_REQUIRED`, keep the Store
     and call `recover_creation`. It returns `UNCHANGED` if the resource was
     never written and the original result if it was.
   - A saved resource name is private data your program trusts. Use
     `OpenMode::Bootstrap` when your program saved its store identity before
     opening, so a first open creates the store and later opens reuse it.
3. Register content behavior for each schema and version.
   - Each method declares how a retry behaves: `ReadOnly`, `Idempotent`, or
     `Receipt`. It also lists the permission keys and content facts it needs,
     and Zig checks them before the call runs. Receipt methods take the form
     `mutate(sequence, verb, args...)`.
   - `Content::invoke` returns a value that can be sent and may call
     `Call::replace`.
   - `loam::refusal(message)` refuses a call. The message stays local, and the
     peer receives `ApplicationRefused`. A Rust callback that panics also
     refuses the call, and the Host keeps a record of it that
     `Host::take_failures` returns.
4. Attach to the Host, restore the use and control capabilities, and share
   ordinary `Ref` values.
   - `Policy::value(...).derive_arguments(sequence, scope, depth)` builds the
     arguments for a share. The endpoint you call names the resource,
     `Scope::Object` or `Scope::Subtree` says whether the share reaches its
     children, and Zig checks the grant's limits and how far it may be passed
     on.
   - To fetch a shared facet cold after a restart, keep the Host seed and the
     durable name the share returned. Policy keys and object IDs let nobody
     call anything.
5. Ask for a managed child grant with
   `managed_derive_arguments(sequence, scope, depth, powers)`.
   - `ControlPowers` lists separate powers: Inspect, Issue, Edit,
     DelegateControl, and pause, resume, and revoke. Its default grants none.
     `derive-managed` returns two ordinary `Ref` values: use and child control.
   - `set_policy_arguments(sequence, revision)` on a policy value builds a
     `mutate` request for that control. Read the current grant revision with
     `control_revision(&host, &control)`.
   - A grant's policy stays within the limit it was issued with. An edit
     higher up the chain narrows what the child can use without rewriting the
     child's own settings. Editing a paused grant leaves it paused.
6. Narrow or end management.
   - `ControlPowers::attenuation_arguments(sequence)` in a `mutate` call
     narrows a control. `revoke-control` ends that control and the controls
     issued from it, leaving use and unrelated controls in place. `revoke`
     ends the grant itself and every grant derived from it.
   - To get the child pair back after a restart or a lost reply, resend the
     original `derive-managed` request through a source you still hold. A
     revoked grant stays revoked.
   - Issued and narrowed controls answer `durable-name` with their own secret
     name. Save or share it with the peer hosting the control. A use name
     cannot rebuild it. The owner's private controls have no durable name.
7. Close sessions, then the attachment and the Store. Host shutdown detaches
   idle registrations before it frees its C side. Callback contexts are
   dropped only after a successful detach. Releasing the Store is refused
   while anything still borrows from it. Dropping a storage work task waits
   for its worker to finish, which can block the thread.

## Sharing and managing access from C

C programs manage access by calling the endpoint with ordinary Host
arguments, with no extra C functions.
[ADR-0187](../decisions/adr/ADR-0187-held-scope-management-vocabulary.md)
defines these forms.

- A scope is the symbol `object` for the endpoint's resource alone or
  `subtree` for it and every child, including ones added later. The policy's
  kind rules decide which permissions each scope can carry.
- A policy triple is `[identity bytes (16), [permission mask bytes (8)],
  ordered bounds]`, with each bound either Void or eight unsigned big-endian
  bytes.
- A management selection is `[Edit policy triple or Void, Issue policy triple
  or Void, power mask]`. Each policy limit is separate.
- Mask bits 1, 2, 4, 8 and 16 ask for Pause, Resume, Revoke, Inspect and
  DelegateControl.
- A revision is eight unsigned big-endian bytes, even when the value is past
  the signed 64-bit range.

| Endpoint method | Arguments after the method name |
| --- | --- |
| `derive` | Sequence, scope, policy triple's three fields, delegation depth |
| `derive-managed` | The `derive` arguments followed by one management selection |
| `issue-access` on control | Derivation sequence, expected revision, scope, fixed limit policy triple, initial policy triple, depth, management selection, UTF-8 label, initially paused Boolean |
| `inventory` on control | Cursor bytes or Void, limit from 1 through <!-- value ../../src/loam/access/hosting/inventory.zig max_rows -->32<!-- /value --> |
| `mutate` for `set-policy` | Mutation sequence, `"set-policy"`, expected revision, policy triple's three fields |
| `mutate` for `set-label` | Mutation sequence, `"set-label"`, expected revision, UTF-8 label |
| `mutate` for `pause`, `resume`, `revoke` | Mutation sequence, verb, expected revision |
| `mutate` for `attenuate-control` | Sequence, `"attenuate-control"`, management selection |

Zig checks depth, limits, policy identity, and powers. A label holds at most
<!-- value ../../src/loam/access/core/grant_label.zig max_bytes -->120<!-- /value --> UTF-8 bytes and grants nothing. Issuing needs a control with an issue limit
whose chain back to the owner has no revoked grant. It works even while use is
paused, narrowed, or unable to delegate. The child's use keeps every
restriction of its source, and a child with any management powers also needs
DelegateControl.

Rust's `PolicyValue::with_ceiling` builds an `IssuePolicy` from the initial
policy and its fixed limit. Edits can later change the policy within that
limit, and asking for management powers never widens it.

`inventory` needs Inspect and lists the held grant's direct children. Each row
gives the slot, generation, revision, label, the grant's own status, the
status it inherits, its limit and current policies, and its delegation depth.
A row carries no capability or secret name. A cursor is tied to the endpoint
and the Store revision, so any edit invalidates it. Start again from Void on a
conflict.

A resent `issue-access` uses the same receipts as `derive`. Loam checks that
the caller still holds management and an unrevoked source, then returns the
original pair instead of comparing the old revision as if the request were
new. A resent edit likewise finds its receipt first, while a new edit that
changes nothing still checks the expected revision. Application-specific
management data and Rooms behavior are not part of this shared model. The
[session guide](../rooms/session.md) describes how Rooms uses it.

Rust reads management replies through the borrowed views
`ControlDescription`, `PolicyDescription`, `GrantDescription` and
`InventoryPage`. They keep unsigned revisions and typed bounds without copying
labels or keeping a copy of the grant. A full last page may need one more,
empty page to confirm there are no more rows. A row's identity grants no
control. The Rooms `client::access::Control` keeps a held control, expected
revisions, and its `Issuance` request so it can resend it.

## Reference fields

Content declares the references a call needs through `Content::references`:
`ReferenceRequest::Restore(index)` to use a saved one, or
`Save { reference, uri }` to save one. Loam handles these after it has checked
the caller's grant and before the call runs.

- A reference into the same attachment needs no URI.
- A reference to another peer needs an established sturdyref URI that
  restores exactly the capability held.
- A live reference Loam cannot save, or a receipt capability of a kind it
  does not support, is refused before anything is written.
- References to local objects in another attachment are not available from C
  or Rust.

An edit that restores a saved reference can reuse the stored entry that
already holds it. Several fields saving the same reference in one transaction
share one stored entry. An aborted transaction never lends its IDs to a retry.

Content that holds a graph can declare
`ReferenceRequest::RestorePageWithUri` and borrow the stored sturdyref URI with
`Call::page_saved_uri`.

- The URI bytes for another peer stay valid until the callback returns. Local
  and live references return `None`, and a live reference whose process has
  ended still cannot be restored.
- An ordinary restore keeps no copy of the URI and no lease on the stored
  entry. `ReferenceRequest::uri_call_size_bound` gives the extra call memory.
- Reading this URI does not let the reply hand the capability out.

`Call::append_reference`, `replace_reference` and `remove_reference` change
fields in the same transaction as the payload. An exact disclosure returns the
saved capability as it is. A dependent disclosure also checks every call
against the caller's current grant and `Content::dependent_requirement`.
Removing a field does not revoke a copy someone else holds. Indices refer to
the committed fields for the whole call, and appended fields come after the
fields that remain. Editing the same field twice is refused.

Content keeps its link to its managed resource as a protected first strong
edge. Application indices skip it, and `field_count` counts only application
fields, but schema edge limits include it. Content without that link is
refused at call time, so recreate the store.
[ADR-0188](../decisions/adr/ADR-0188-managed-content-reference-fields.md)
records these rules.

A C reference declaration borrows its token only during the callback, and URI
bytes are copied into the call's memory before it returns. A declaration can
name both the fields it restores and the fields it saves: at most twice
<!-- value ../../src/c_abi/loam/common.zig max_content_fields -->514<!-- /value --> requests for one record, or twice the graph's total edge limit. Each URI
is at most `GLOWCAP_LOAM_MAX_URI_BYTES` bytes, which Rust exposes as
`ReferenceRequest::MAX_URI_BYTES`. The Host's shared limits bound the work of
preparing and reviving references.

## Registered content graphs

Set `Registration.graph` to a `Graph` that declares the page schemas and the
total page, payload and edge limits. Register every schema before opening the
Store. The root's application fields become links to its pages. Each page's
protected first edge links the same resource, and its other fields hold
capabilities. Loam checks those roles before the call runs.

`Invocation.graph` borrows the loaded pages. Declare saved fields with
`ReferenceRequest::RestorePage`, then use `Call::page_reference` for a
reference that lives only in the callback, or `disclose_page` for a checked
result. `replace_graph` takes an ordered list of kept handles, payload updates
and written pages:

- A payload update keeps the page's committed fields without restoring their
  targets, so a receipt can commit even while some unrelated peer is
  unreachable. Loam checks the page's revision and the graph's capacity.
- Handles belong to that callback and cannot be saved as durable identities.
- The setter copies the new bytes before the Rust or C buffers go away.
- A written page takes `GraphField::Held` for a capability the call holds and
  `GraphField::Retained { page, index }` for a field already committed on a
  loaded page. A retained field keeps its object and stored reference without
  restoring the target, so reorganizing pages never needs a connection to
  another peer.
- Index zero is the first capability field, never the resource link. Loam
  refuses tokens from another call, bad indices, and weak fields before it
  takes any capability.

Loam releases each page's lease before it reads the next. Memory and limits
follow these rules:

- The loaded pages, the new graph, and the callback's lists all count against
  `Limits.call_bytes`, including allocator overhead. Memory is allocated only
  as it is needed.
- Each call reserves its whole allowance up front. `pending_bytes` bounds all
  of an attachment's reservations, and `ingress_bytes` bounds one session's
  calls once they leave the queue. These allowances do not enlarge the Vat's
  message queue, and the record and transaction limits stay separate.
- A refusal aborts the whole graph, its change event, and its receipt.
- Resending a request whose receipt committed checks the current source and
  target grants and the saved results. It does not load the current graph or
  save new references, so pages that are unavailable cannot block the
  replay.

## Limits and sizing

Loam checks these `Limits` fields before it opens storage:

- `record_capacity` bounds how many managed records one operation can hold in
  memory. Leave two more leases (`max_leases`) for the descriptor and
  directory reads.
- `max_reference_saves` bounds the reference saves in progress, including
  finished ones kept until the transaction's outcome is known.
- `max_retentions` bounds the records kept alive outside the graph, including
  each restored reference until its call finishes. Restoring more references
  does not need more endpoint slots.
- `max_references` bounds the attachment's endpoints.
- `record_bytes` bounds a whole encoded record, including its header and
  checksum. Schema payload limits apply inside that.

The sizing functions compute these limits before the Store opens. None of them
reads storage, allocates, or starts work, and a refused C call zeroes every
output. Each C function's comment in
[`glowcap_loam.h`](../../include/glowcap_loam.h), and its Rust doc comment,
says what the result includes and what you add yourself.

| Rust | C | Computes |
| --- | --- | --- |
| `Schema::encoded_size_bound` | `glowcap_loam_schema_size_bound` | The largest encoded record for one schema. |
| `StagingBounds::content(path, receipt)` | `glowcap_loam_content_staging_size_bound` | The managed rows one content change writes. |
| `StagingBounds::references(saves)` | `glowcap_loam_reference_staging_size_bound` | At most one stored reference per new save. |
| `ReferenceRequest::call_size_bound` | `glowcap_loam_reference_call_size_bound` | What references add to `call_bytes` for one call. |
| `Graph::call_size_bound` | `glowcap_loam_graph_call_size_bound` | What a graph adds to `call_bytes` for one call that replaces it. |
| `InvocationBounds::call_size_bound` | `glowcap_loam_invocation_call_size_bound` | What the call itself adds to `call_bytes`. |

Rules for adding the results together:

- A row bound covers one content change. Add your root and page rows from
  their schema bounds, sum `changes` and `staging_bytes`, and take the largest
  `record_bytes`. Writing one row twice replaces its bytes, and old pages and
  expired history add no rows. Creating resources, editing resources or
  controls, and several managed changes in one call need their own sizing.
- Each `call_bytes` result is one part of a call's memory, not the whole. Add
  the reference, graph, and call parts to your own callback's needs. Store
  staging, capability operations, registration, promise resolution, Rust
  buffers, and Host network state have their own limits.
- A graph bound covers the old and new graph together. Page counts leave out
  the root, payload totals include it, and capability field counts leave out
  the resource link and page links.
  [ADR-0199](../decisions/adr/ADR-0199-retained-resource-content-graphs.md)
  records how graph memory is owned and counted.
- `InvocationBounds` uses `ValueBounds`, which counts every value, each
  struct key, the total copied bytes, and every capability. Argument bounds
  cover the whole incoming argument list, including the `mutate` sequence and
  method name. Reply bounds must cover both new replies and replies saved in
  receipts. A value within these bounds can still fail to encode.
- Single-record content and reference edits, resource and control edits,
  sharing, observation, and forwarding to another peer need their own sizing.

## Callback context

Rust `Content` methods receive one borrowed `Invocation`, and C receives the
same struct generated from it. `bound_resource` gives the resource's identity,
kind, object, and owner revision, beside the content's own object and
revision.

- `Delivery::Local` describes the target that is running, including local
  dependent calls.
- `Delivery::Forwarding` describes only the source passing the call on. The
  capability it forwards to chooses the destination, and nothing about that
  destination is known here.
- These values describe the call and grant nothing if kept.

Loam reads the resource's record before the callback declares anything, and
rebuilds this context when a newer commit makes the call run again. The C
layer checks the protected first edge against that record before your code
runs. A shared trace on Linux and in Chromium checks this identity through
exact and dependent calls and a cold reopen. Rebuild against the generated
headers after any change to them.

## Callbacks, memory, and limits in C

### Work after a receipt commits

`max_continuations`, `continuation_bytes` and `max_continuation_targets` size
the memory for work that waits on a receipt, and a count of zero turns the
feature off. `forward_reply_bytes` bounds each forwarded target's reply,
apart from the source callback and its observer. A zero or overflowing value
is refused before storage opens.

A receipt callback can call `Call::reserve_continuation_copying` with targets
it holds.

- The reservation borrows the callback. Its source and target getters return
  references you own, for the application's own receipt record.
- The returned `PendingContinuation` follows the commit and any recovery.
  `confirmed` hands it over once, without allocating. `absent` reports a
  confirmed absence without taking the observer, and a content callback may
  ask it.
- If the receipt never committed, it returns `UNCHANGED`. An unknown commit
  holds the work until recovery decides. Dropping the observer neither decides
  the commit nor cancels work already accepted.

A confirmed `Continuation` can hand out a public reference that checks the
source again, or `execute` a target privately.

- `EffectExecution::completed` reports `Ready`, `Unsent`, or `Unknown`. Only
  `Unsent` means the target never received the call.
- The execution owns its reply and its borrow of the attachment, so the
  continuation can be dropped at once.
- Each ready result returns owned Rust values and reference guards. C child
  views expire at the next query, and each returned reference must be released
  on its own.
- If handing out the result is refused, the ready result is kept for a retry
  without sending the call again.

The continuation sizing functions report the reservation, the C observer, the
source call's arguments, the reply, and the Host's dispatch separately. These
handles live only as long as the process, so your application saves its own
receipts and handles recovery after a restart. The
[Rooms session guide](../rooms/session.md) shows how Rooms does it.

### Read-only disclosure

Read-only content can call `Call::disclose_reads_copying` over a target it
holds.

- `ReadInterface` lists the allowed verbs. Each `ReadMethod` names the
  interface of every capability its reply returns, in depth-first order. An
  empty list means the reply may return no capabilities.
- Loam keeps the original caller's request, checks it before sending and
  after every wait, and restricts each returned capability the same way. One
  target and interface keep one identity, even across repeated and nested
  replies.
- Content must declare only read operations, and callbacks that change state
  are refused on this path.
- `ReadScopeBounds::size_bound` gives the memory it needs.

[ADR-0206](../decisions/adr/ADR-0206-recursive-read-interfaces-retain-source-admission.md)
records how long these capabilities live and how retries work.

### C callbacks and registration

- Callbacks borrow the payload, verb, and argument views until they return.
  They must not unwind or drive the Host from inside the callback.
- Reply and replacement setters copy into the call's bounded memory.
- `glowcap_loam_store_new_in` allocates the Store and attachment from a
  Context, so keep that Context alive until both are released. The SQLite,
  LMDB, and in-memory archives use the library's allocator.
- Attaching copies declarations and method names. Application and entropy
  contexts stay borrowed until a successful detach.
- A policy allows at most <!-- value ../../src/loam/access/core/policy.zig max_permissions -->64<!-- /value --> permissions and <!-- value ../../src/loam/access/core/policy.zig max_constraints -->16<!-- /value --> unsigned bounds. A registration has at most <!-- value ../../src/c_abi/loam/callbacks.zig max_methods -->64<!-- /value -->
  methods, with names of 1 to 256 bytes. An attachment takes at most <!-- value ../../src/c_abi/loam/attachment.zig max_contents -->128<!-- /value --> content
  registrations and <!-- value ../../src/c_abi/loam/common.zig max_schemas -->128<!-- /value --> schemas.
- `Limits` sets the cache, read-ahead, lease, staging, reference, and
  operation limits. `read_ahead` slots come out of `cache_slots`, so size the
  cache for leases plus that depth.
  The work pool reserves `cache_slots + 1` slots at startup, so storage work
  from C allocates no handle.

### Policy prerequisites and kinds

A C policy carries a table of prerequisites:

- `GlowcapLoamPolicy.prerequisite_masks[i]` lists the bits permission `i`
  requires, in the same sorted order as `permissions`. Unused rows must be
  zero, and a permission that requires itself or an undeclared bit is
  refused.
- The table takes 512 bytes inside the policy and allocates nothing. Checking
  it visits at most 64 permissions.
- Owner records save the table within their 4 KiB payload limit. An owner
  record written without the table or the kind list cannot be read, so create
  a new store with a fresh identity and grant access again. Opening a store or
  importing grants refuses ones that do not fit the policy.

`Policy::with_kinds` declares up to <!-- value ../../src/loam/access/core/policy.zig max_kinds -->16<!-- /value --> sorted resource kinds, each with
the permissions it supports alone and for children added later.

- A nonempty table refuses unknown kinds. A grant issues only the
  permissions the exact kind supports, while the policy keeps the full list.
  Derivation, edits, and control limits follow these rules after a reopen.
- `value_for_kind` builds the terms for one kind through Loam's Zig check. It
  returns data only and grants nothing.
- Kinds add 384 bytes plus a count inside the policy, with no allocation. The
  largest owner policy fits the <!-- value ../../src/loam/access/records/owner_record.zig max_encoded_bytes bytes -->4 KiB<!-- /value --> owner record.

[ADR-0197](../decisions/adr/ADR-0197-scope-aware-permission-applicability.md)
covers mixed selections and how scopes contain each other. General operations
on resource trees are available from Zig only.

## Driving storage from C

A C program runs this loop:

1. Alternate driving the Host and calling `glowcap_loam_advance`.
2. Take storage work with `glowcap_loam_next_work`.
3. Run it through the engine archive and join the thread that ran it.
4. Call `glowcap_loam_work_complete` on the Host thread.

Completion follows these rules:

- `out_completed` says whether Loam took the result, even when the status is
  a refusal. Zero leaves the work and everything it holds in place. One lets
  you call `glowcap_loam_work_release`.
- Join the worker before completing or releasing, because a result flag does
  not show that another thread has finished.
- After an unknown write, recovery is offered only once the original work is
  completed and released. If recovery fails or never starts, the store keeps
  refusing other work.
- A read that finds damaged bytes completes with `GLOWCAP_LOAM_ERR_CORRUPT`,
  and retrying it cannot help. When a commit's result is unknown, every other
  call reports `GLOWCAP_ERR_IO` until recovery succeeds, so keep the Store and
  engine open until then.
- Each work handle is one slot of the attachment's `hosting.Worker`, so C and
  Zig programs follow the same rules for slots, recovery, and shutdown.
- An engine archive's attachment hands out no more reads at once than the
  engine has readers, and `glowcap_loam_next_work` reports `WOULD_BLOCK`
  until one completes. A write is still offered, because it needs no reader,
  so a thread pool of any size can run every handle it receives.

`glowcap_loam_advance` reports new Host work through `out_progress`, including
a fetch sent while a reference is still being prepared. Run that work before
you wait for the reply. Replies still owed by other peers, and work waiting on
the network, do not keep that flag set.

Collection runs in the same loop. `Store::collect(work_limit)` runs one
bounded step and returns whether the cycle has more to do. A step does
`work_limit` units of work, plus whatever finishes the unit it started, so
call it until it returns false. Over an engine archive it calls the archive's
`collect` function (`glowcap_loam_lmdb_collect` for LMDB) and then reads
`glowcap_loam_store_collecting`. A C program that brings its own storage calls
`glowcap_loam_store_collect_plan`, commits the transaction, and finishes with
`glowcap_loam_store_finish(raw, 0, outcome)`. Collection is refused while an
attachment exists or a resource is staged.

## Tests

`zig build loam-abi-test` covers C ownership and recovery.
`zig build loam-rust-test` runs create, share, edit, restart, and cold reopen
over loopback TCP, plus resent requests, panics in callbacks, and worker
cancellation. It shares its management and field traces with the Chromium
test in the [browser guide](browser.md#limits-and-tests).
[Stability](../stability.md) says which platforms these cover.

The Rooms
[largest-reference trace](../../apps/rooms/rust/proofs/src/session_foreign/mod.rs)
checks the most fields and pages Rooms allows, including refusal at capacity
and cold restoration (`zig build rooms-session-foreign-test`).
