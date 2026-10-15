---
type: static
description: A guide to managed access in Zig, covering resource structure, held use and control references, hosted methods, and exact retries.
audience: human
sources:
  - resource: /src/loam/access/
  - resource: /apps/rooms/rust/browser/src/attached/managed/
---

# Managed access records

This guide builds managed access in Zig: its records, the use and control
references people hold, hosted endpoints, and safe retries. Storage engines and
attaching a Store to a Host are in the [store and actor guide](../loam.md).

## What managed access is for

Passing a reference is often all the sharing an application needs. Alice can
hand Bob a read-only wrapper around her board and cut it later. Managed access
is for applications that also need to see who has access, change it later, and
let Bob share a narrower part onward. It keeps that bookkeeping in Loam
records, in the same transactions as the content it protects.

- A **resource** is something the application owns, arranged in a tree, such
  as a board and its columns.
- A **grant** gives permission over one resource, a chosen set, or a resource
  and everything below it. A grant made from another grant sits under it and
  can never be wider than any grant above it.
- A **use reference** exercises one grant. A **control reference** is a
  separate capability that can pause, resume, or revoke that grant. Bob can
  hold the first without being able to change his own access.

Every use is checked against the whole chain of grants above it at the time
of use, so revoking a grant cuts off everything shared from it. The
[website's Loam page](https://jimisaacs.github.io/glowcap/loam/#sharing-with-people)
draws this.

`access.core.GrantView` checks a grant against the grants above it as they
are now, and `ResourceView` does the same for resources. Both read records
without blocking and never do storage I/O. When a record is not loaded, they
return a read request for your code to serve.

`GrantPlan.prepareCopying` prepares a change to grants as of that view's
revision. `plan.changes` returns the new grant, an optional update to its
parent, the record revisions it expects, and a change event. The owner writes
those records with its content in one Loam transaction and publishes the event
only after the commit is confirmed. A plan neither opens a transaction nor
checks that the caller may manage access. That permission comes from the use
and control references the caller holds.

Records in `access.records` decode without keeping the encoded input.
`ChangeBatchRecord.decodeOwned` and `GrantRecord.decodeOwned` own their paths
and resource lists, so release them with `deinit(allocator)`.
[ADR-0166](../decisions/adr/ADR-0166-access-grant-records-and-plans.md)
defines the limits and how long borrowed views live.

## Policy and interface support

A policy lists every permission the application has.
`Policy.Descriptor.kinds` says, for each kind of resource, whether a grant can
cover one object and whether it can cover a subtree, including children added
later. An empty table applies the policy to every kind, and a nonempty one
refuses kinds it does not list.

- `Terms.validate` checks support for the chosen scope, and
  `GrantView.require` checks each effect's exact target.
- A grant over a chosen set of resources gets the permissions any of them
  supports. Subtree support comes from the subtree's root, without scanning
  its children.
- Pass the owner's policy to `Graph.create` and `Graph.reparent`. Stored
  creates and moves use the owner's current header, and both make sure a
  child's support for future children fits its parent's.
- `Policy.valueForKind` builds the terms for one kind. It returns data and
  allows nothing later.

[ADR-0197](../decisions/adr/ADR-0197-scope-aware-permission-applicability.md)
records the limits and the alternatives.

## Durable owner operations

`access.storage` connects these views to a Store. Register
`access.records.profile.schemas` alongside the application's schemas.

- Managed access needs a record limit of at least 64 KiB and <!-- value ../../src/loam/access/records/grant_record.zig max_edges -->515<!-- /value --> edges.
- The managed record format may still change, so use a fresh directory.
- Inside a transaction, `storage.stage.createOwner` returns a reference to the
  owner's header record. Keep it after the commit is confirmed, to reopen the
  owner. The header saves the policy, revisions, ID counters, directory roots,
  and the root of a bounded change history.
- Resources and grants nest at most <!-- value ../../src/loam/access/storage/stage.zig max_depth -->64<!-- /value --> deep.

### Reading

Create a `storage.Read` with room for a bounded number of records, then call
`advance` until it is ready:

- `.read` hands a Loam read request to your executor. Pass its result to
  `completeRead`.
- `.waiting` means work is still in flight, or the operation paused after a
  bounded amount of CPU work.
- `.ready` means you can retry the view call.

When a view call returns `RecordUnloaded`, call `advance` again and retry once
it is ready. Damaged records, missing identities, stale revisions, and full
capacity each fail with their own error.

### Writing a change

1. Prepare a `storage.Append` for the resource or grant table and run its
   `advance` with the same read and completion loop.
2. To add a resource, call `prepareResource(parent)`. It loads the parent's
   ancestors and child list before `stage.appendResource` can write.
3. To change a grant, prepare the shared `GrantPlan` from the Read's views and
   the saved policy. A new grant takes the header's next grant slot with
   generation one, and other changes keep the grant's identity.
4. Call `storage.stage.prepareGrant(read, plan)`. It loads the history and the
   ancestors needed to update child lists.
5. Begin your Store transaction and write the change with
   `storage.stage.appendResource` or `storage.stage.grant`, together with the
   content. Loam's prepare, write, complete, and recover steps commit the whole
   batch.
6. Publish new identities and events only after the commit is confirmed.

Plans check the model, not the caller, so your owner code must confirm the
caller may manage access before preparing one. A failure after managed
writing starts aborts the whole batch, content included.

### Several changes in one transaction

Several managed changes can go in one transaction. Each new preparation reads
the Read's state including earlier changes, and the batch writes one header
update per owner.

- A preparation made from older resource, grant, or control state is refused,
  and the caller that began the batch must abort it, discarding the earlier
  changes too.
- A failure after a participant starts writing aborts the batch. Hosted calls
  leave the abort to their transaction runner.
- A Read that has seen uncommitted owner state belongs to that transaction.
  Reopen it after the batch ends, including after an abort or after recovery
  finds nothing was written.
- Every commit makes existing Reads stale. After an unknown write, their views
  refuse until recovery decides.
- An aborted, unpublished append uses up no committed slot.

### Memory and lifetimes

A Read owns the decoded header fields and pins the records it needs. It
releases the header's lease after decoding and remembers the revision it
expects.

- Changes load the bounded history when they need it, and ordinary access
  checks never do.
- Walking the directory borrows one more cache slot and keeps its place across
  cache misses. Its path is at most four directory records plus the target.
- The record count must fit within `max_leases - 1`, with cache room for the
  pinned records and one directory or history read.
- A Read holds at most <!-- value ../../src/loam/access/storage/read.zig read_budget_bytes bytes -->21 KiB<!-- /value --> of state inside itself plus one allocation: a
  decoded grant record beside 16 KiB of scratch for its resource list. An
  Append holds at most 52 KiB of path state, and adding a resource also
  allocates one child-list path of the same size.
- A Read lends one grant record at a time (ADR-0230). A lookup while a record
  is on loan fails with `RecordHeld` in every build mode, and the loaned
  record carries what writing and observation need. Checks on loaded records
  call no allocator.
- Store cache buffers reserve `max_record_bytes` per slot, even for short
  records. The sizes above leave out those buffers and the transaction's own
  staging.

Keep the Read and Store at the same addresses while views, an Append, or a
ResourceChange borrow them. An Append or ResourceChange takes the Read for
itself, so release it before closing the Read. Canceling keeps submitted
buffers until their reads complete, and `deinit` refuses while work is
outstanding.

### Change history

The owner keeps every indexed record, including revoked grants. The header
keeps a history of at most **<!-- value ../../src/loam/access/records/change_history_record.zig capacity -->32<!-- /value -->** change batches, oldest first.

- An owner gets one batch per Store transaction, holding at most **<!-- value ../../src/loam/access/records/change_batch_record.zig max_effects -->16<!-- /value -->**
  grant, resource, content, or control changes in order. A seventeenth fails
  with `ChangeCapacity` and aborts the whole transaction.
- A batch keeps no application payload or grant links, and once it falls out
  of the window it can be collected.
- A change that alters nothing, or aborts, adds no batch. A receipt for an
  unchanged result can still commit without adding history.

Grants keep separate stamps for their permissions and for their children
list, and resources keep separate stamps for their place in the tree, their
subtree, and their content. Updating ancestors' child lists and subtrees
writes at most <!-- value ../../src/loam/access/records/change_batch_record.zig max_path -->65<!-- /value --> identities per path. Replacing content or a reference with an
equal value finishes at once when no other participant is involved.

[ADR-0167](../decisions/adr/ADR-0167-managed-owner-storage.md) defines this
storage, and
[ADR-0179](../decisions/adr/ADR-0179-scoped-change-retention-and-observation.md)
covers change history and [observing it](#observing-held-access).

## Resource moves, deletion and children

Owner code prepares a `storage.ResourceChange` against a Read, runs its reads,
and writes it with application content in the same batch.

- `.move = parent` moves a resource to a new parent and keeps its identity.
- `delete_leaf` refuses a resource with children, removes it from its parent,
  and saves its identity as inactive. Its content and unrelated capabilities
  stay alive, and any later use fails as `Gone`.
  [Owner cleanup](#bounded-owner-cleanup) frees what is left without bringing
  the identity back.

Before writing a move, the resource view refuses cycles and checks that the
deepest child stays within the owner's depth limit. The check walks the
subtree with at most `max_resource_depth + 1` frames and one lease at a time,
so its cost grows with the number of children. The old parent, the new
parent, the resource's own record, and the owner's revision commit together.

A held use operation calls
`prepareResourceCopying(target, action, requirement)`, which checks the
source and both parents against that requirement, then `stageResource()` in
the current batch. Hosted content declares the same change with
`ContentBehavior.resource`, on the call's own resource or on a
[participant](access-endpoints.md#calls-that-change-several-resources). The
payload changes and the receipt commit with it.

### Listing children

`Operation.children(parent, requirement)` returns a Zig cursor you own. Each
`advance()` gives a resource ID the caller may see, a read request, a wait,
or the end.

- Children the caller cannot see are filtered out before anything returns, and
  the cursor reveals no index position, sibling count, or owner revision.
- A commit in the middle returns `RevisionConflict`. Start a new query, which
  checks permissions again.
- Cancel submitted reads and wait for them before deinitializing. Release the
  cursor before its operation.
- One operation owns one cursor, and listing and preparing an effect exclude
  each other: preparing returns `Busy` while a cursor exists, and opening a
  cursor after preparing returns `WrongPhase`.

## Durable use and control references

`storage.Capabilities` borrows one Store and enforces limits on live
references and operations.

1. Owner code writes use or control grants with `stageUse` and `stageControl`
   from a current owner Read. Control powers are `core.Control.Powers`:
   separate Inspect, Issue, Edit, and DelegateControl powers beside pause,
   resume, and revoke. Issue and Edit each carry their own copied limit.
2. After the commit is confirmed, `restoreUse` or `restoreControl` checks a
   lease on the grant and creates an opaque Zig reference. Release the lease.

The reference keeps the grant alive through Loam's live roots without pinning
it in memory.

Each reference's `begin(capacity)` creates an opaque `Operation`, which you
drive with `advance` and `completeRead` as with a Read.

- Use operations offer `require` and `prepareDeriveCopying`, and controls offer
  `prepareEditCopying`. Calling the wrong role's method is refused.
- Calls use the grant the reference names and check the current owner and
  grant records. An operation exposes no Store, raw view, or way to pick a
  different grant.
- On `RecordUnloaded`, run the read work and retry the same call.
- Input slices only need to stay valid during each call.
- A successful preparation owns its copied terms until the operation closes.
  One operation prepares one change, so use several operations to make several
  changes in one batch.

Owner code writes a prepared operation with `Capabilities.stage` in the same
Store transaction as content. It returns the proposed change and, when
sharing, a `derived_use` grant reference. The child grant and its record
commit together, so before committing, either make that record a root or point
a strong edge at it from content. Calling `storage.stage.grant` directly
returns the proposed change and a reference to the grant record. Restore or
publish anything only after the commit is confirmed.

An operation keeps its source reference alive, so the holder may drop its own
copy while work is pending.

- `cancel` waits for submitted reads to complete, and `deinit` refuses while
  any are outstanding.
- Close finished operations to release their leases before starting more.
- `Capabilities` cannot close while any reference or operation remains.
- A grant record can be collected once nothing durable keeps it and no live
  reference holds it.

Memory:

- Each reference allocates at most 96 bytes.
- Starting an operation allocates at most <!-- value ../../src/loam/access/storage/capability_operation.zig state_budget_bytes bytes -->40 KiB<!-- /value -->, including its Read and
  scratch for control terms, plus the Read's bounded binding array. Sharing
  adds the Append and the copied plan terms.
- Allow two leases for the grant and the owner header, plus the records the
  check needs and one directory page. Operations running at once share the
  cache and lease limits.
- Checks on loaded records call no allocator.
- Every commit makes old operations stale. After an unknown write, they refuse
  until recovery decides.

[ADR-0168](../decisions/adr/ADR-0168-durable-managed-capability-bindings.md)
defines how references are restored. These Zig calls tie a permission check
to its content change at the same revision, and the
[managed endpoints](access-endpoints.md) do the same for hosted calls.
Controls can also narrow themselves, be revoked on their own, and inspect
their scope through the [management methods](#managing-a-held-control).
Powers never change, so narrowing creates a new, dependent control. A grant's
status and terms stay editable.

## Managed endpoints on the Host

[Managed endpoints](access-endpoints.md) covers the Host service, its behavior
table, and what each hosted method allows.

## Retrying mutations

Every content method declares how a retry behaves through
`ContentBehavior.retry`: `read_only`, `idempotent`, or `receipt`. A read-only
method cannot change anything.

A receipt-backed method must be called as
`mutate(sequence, method, arguments...)`. A bare call returns `RetryRequired`
after the permission check and before the method runs. Call
`mutation-sequence()` to get the next sequence, starting at one. Everyone
holding the endpoint shares that sequence and must coordinate new requests.

The endpoint keeps eight edit receipts, apart from its sharing receipts. Each
receipt records the method, the arguments, any dependent target, and the
first committed result. Capabilities in it are saved as strong edges. A
dependent facet argument is recorded by the endpoint it names, and a reply can
never be restored through that record. A matching retry checks current
permissions and returns the saved result without running the method again.
Other requests fail as follows:

| Request | Result |
| --- | --- |
| Same sequence, different request | `OperationConflict` |
| Sequence from the future | `OperationOutOfOrder` |
| Sequence that has left the window | `ReceiptExpired` |
| No sequences left | Refused |

A revocation, deletion, or loss of scope since the first attempt can stop a
retry.

A wrapped pause, resume, or revoke keeps its first Boolean result, even when a
later bare call would return false, and a wrapped call that changes nothing
still commits its receipt. Content, reference edits, tree changes, control
state, and receipts all share the attachment's transaction. Receipts recover
local results only. They do not deliver a remote message exactly once or save
outside effects.

Receipt limits:

- Each value holds at most <!-- value ../../src/loam/access/records/value_record.zig max_bytes bytes -->32 KiB<!-- /value -->, nests at most <!-- value ../../src/loam/access/records/value_record.zig max_depth -->64<!-- /value --> deep, and the request and
  result together hold at most <!-- value ../../src/loam/access/records/mutation_record.zig max_edges -->64<!-- /value --> distinct capabilities.
- A whole encoded receipt fits in <!-- value ../../src/loam/access/records/mutation_record.zig max_encoded_bytes bytes -->64 KiB<!-- /value -->.
- Only capabilities need extra storage, and calls with plain values fit the
  workload's 4 KiB of call memory.
- Encoding measures before allocating. Decoded containers are owned, while
  byte strings borrow the receipt's lease.

Once a receipt's edge expires, collection can free it.
[Owner cleanup](#bounded-owner-cleanup) keeps the lowest valid sequence while
it frees old receipts, so an expired request can never run again.

## Managing a held control

A control `Operation` offers `describeControl`, `prepareAttenuationCopying`
with `Capabilities.stageAttenuatedControl`, and `prepareControlRevocation`
with `stageControlRevocation`. Their
[source](../../src/loam/access/storage/capability_operation.zig) documents
each.

- Walking a control's chain holds one ancestor lease at a time and stays
  within the owner's grant depth limit. Creating a control copies the chosen
  limits, within the existing limit on how many resources a scope can name.
- Every new operation checks the chain as it is now. Kept references and
  receipts cannot get around revoking a control.
- Grant policy and status still follow the chain of grants. A paused grant's
  control may resume its own grant, but nothing regains use under a revoked
  ancestor.

Hosted controls accept `describe-control()`, `revoke-control()`, and
`mutate(sequence, "attenuate-control", application arguments...)` when the
Service supplies `decode_attenuation`. The decoder receives the control's
current powers and returns the powers requested, and the shared rules decide.

An active `access:control` description holds its status, its pause, resume,
and revoke Booleans, its policy limit or false, and whether that limit covers
a subtree. An unavailable control's reply holds its status alone. No
resource, owner, or ancestor identity is revealed.

## Inspecting held access

Call `describe-access()` on a managed use endpoint to see its current access
to the endpoint's resource. An active reply includes the grant's limit and its
own policy, the policy in effect after restrictions from above, and how many
more times it can be shared. Paused, revoked, and out-of-scope replies carry
only the status. Control endpoints do not accept this method.

The tagged `access:description` reply uses stable permission and constraint
keys, laid out as
[ADR-0171](../decisions/adr/ADR-0171-scoped-access-descriptions.md) defines. It
reveals no ancestor identity, other resources, owner revision, or unrelated
event counter. The reply allows no later change on its own, and each
protected call still checks current permissions.

Zig code uses `GrantUse.describe(target)` or
`storage.Operation.describe(target)`. The second returns owned values with
their policy's fixed vocabulary.

- Run missing reads as for `require`. Stale operations and unknown writes
  refuse, and hosted calls retry a stale snapshot before running.
- Describing access loads permission records and leaves the content asleep.
- Encoding and the reply share the call's bounded memory, so larger
  vocabularies need enough call and frame capacity.
- The largest-policy test uses all <!-- value ../../src/loam/access/core/policy.zig max_permissions -->64<!-- /value --> permissions and <!-- value ../../src/loam/access/core/policy.zig max_constraints -->16<!-- /value --> constraints across the
  three policies within the default <!-- value ../../src/loam/hosting/attachment.zig call_bytes bytes -->64 KiB<!-- /value --> of call memory. Frame capacity is a
  separate limit, and the test measures no throughput.

## Observing held access

The [observation guide](access-observation.md) covers registering, cursors,
the receiver and canceler, restarts, and limits.

## Deriving and recovering a shared facet

Set `Service.decode_derive` to turn application arguments into
`core.GrantLedger.Issue`, and set `Service.entropy.fill` to a source of fresh,
unpredictable random bytes. The decoder receives the endpoint's resource
identity. Decoding grants nothing: the scope, terms, status, and delegation
depth of every grant above limit each new child.

Managed use endpoints reserve these methods:

| Method | Result |
| --- | --- |
| `derivation-sequence()` | The next sharing sequence for this endpoint, starting at 1. |
| `derive-managed(sequence, application arguments...)` | A two-item list with separate use and issuer control capabilities, when `decode_managed_derive` is set. |
| `derive(sequence, application arguments...)` | A CapTP use capability for the same content and resource. |
| `durable-name()` | The endpoint's secret swiss number, or `NotPublished` when it has no durable name. The Host's locator APIs supply the rest of the sturdyref. |

These methods check the caller's current use permission.

- `derive` returns use alone. `derive-managed` decodes a
  `Service.ManagedIssue` with grant terms and control powers, and returns both
  to the issuer. Its policy limit must fit the child grant.
- A use endpoint cannot get its control back. Only the issuing source with the
  same request can. Publish a control separately if it needs its own durable
  name.
- Zig's `prepareManagedDeriveCopying` and `Capabilities.stage` do the same
  sharing in one commit. A child created paused starts paused.
- Beyond handing out stored fields exactly, this API does not narrow
  capabilities that application replies return.

The child grant, its use record, an optional control record and endpoint, the
use's rooted durable name, the retry receipt, and the source's new sequence
commit in one Store batch.

- `Call.result` runs between Host turns, after the Vat work and before the
  write is submitted. It reserves the child actor and a hidden durable name
  through `Host.reserveDurableCapability`, and no fetch can find that
  reservation.
- `Call.confirmation` turns the reservation on, without allocating, once the
  commit is confirmed and before the reply is built.
- An abort releases the reservation, and an unknown write keeps it until
  recovery.
- Move durable name reservations along, then commit or cancel them, before
  tearing down the Host.

The source keeps its last **eight** receipts, found directly by sequence
through ordered strong edges.

- A matching request returns the same child.
- Different terms give `OperationConflict`, an older sequence gives
  `ReceiptExpired`, and a future one gives `OperationOutOfOrder`. An expired
  sequence can never create a child again.
- Everyone holding one endpoint shares the sequence, as for edits.
- Retries check the source and child at the current revision, so a retry
  cannot get around a pause or revocation.

When a receipt leaves the window, its edge is dropped and collection can free
it. The child's durable name stays, so retire names yourself when they should
stop answering, or use [owner cleanup](#bounded-owner-cleanup). At startup,
call `publication.listen` so these names are looked up when fetched. A kept
receipt can also restore its exact child and durable name after a reopen.

Costs and limits:

- Endpoint format version <!-- value ../../src/loam/access/records/endpoint_record.zig version -->2<!-- /value --> reserves edges for the grant, optional content,
  optional owner administration, an optional durable name, and <!-- value ../../src/loam/access/records/retry_window.zig capacity -->8<!-- /value --> receipts
  for each kind of sequence.
- A sharing receipt holds at most <!-- value ../../src/loam/access/records/derivation_record.zig max_encoded_bytes bytes -->64 KiB<!-- /value --> of encoded request and two edges, or
  three when it keeps issuer control.
- Encoding the request and sharing state use the call's bounded memory.
- A retry holds three more record leases and a child operation while it
  checks permissions. A managed retry also holds its control endpoint and a
  bounded control operation.
- Issuing uses the Zig Append's memory. The actor and durable name are
  allocated before the write is submitted and may be refused under pressure.

[ADR-0170](../decisions/adr/ADR-0170-durable-facet-derivation.md) records
these rules.

## Bounded owner cleanup

Your trusted program may restore an owner record through the Service's owner
behavior. That capability administers the whole owner, and no use or grant
control can produce it. Its commands:

| Command | Effect |
| --- | --- |
| `sweep(sequence)` | Starts cleanup of finished grants and resources, leaving active access alone. |
| `retire-owner(sequence)` | Stops all ordinary calls before cleanup starts. |
| `maintenance-step(sequence)` | Runs one prepared step. |

The tagged `access:maintenance` reply holds the next sequence, the phase, a
retired flag, and a replay flag. Start at zero. To retry, resend the last
acknowledged request with its original sequence, and the matching command
returns its saved progress without doing anything again. Older, conflicting,
and future requests are refused.

Zig code uses opaque `storage.Maintenance` operations with the same commands
and sequence.

- Run their read requests before opening a Store batch, then write and commit
  through the executor that owns the Store.
- Each operation is tied to one Store revision. An abort, an unknown outcome,
  or another commit in between needs a fresh preparation.
- Submitted reads keep their ticket and buffer through cancellation until
  they complete, and `deinit` refuses while any are outstanding.

### What cleanup visits

Cleanup walks the observation index, the weak identity directory, grants, and
resources. Each step looks up one path at most four levels deep and checks one
bounded chain of permissions, so it never scans other owners.

- Revoked controls, revoked branches of grants, and deleted content targets
  have their identities retired.
- Pruning a grant lowers its surviving parent's child count and records the
  change in its child list's history.
- Empty directories keep their highest allocated ID.

Finished endpoints and grant records lose their payload and links and become
empty records. Endpoint records keep the lowest valid sequence for both
receipt kinds while dropping the receipts themselves. A reference someone
still holds sees that empty record, and a retry is refused instead of
creating a new result.

Retiring an owner first stops pending ordinary work and cancels its
receivers. It then compacts its identities and records before dropping the
resource and event roots. The small owner header keeps the ID counters and
how far cleanup got.

### Durable names

Active durable names stay rooted until they are retired. Hosted cleanup loads
their recipes and retires them through the attachment's write queue, with the
same handling of unknown outcomes.

- Zig cleanup over records that have durable names needs the attachment's
  retirement callback, and refuses before doing anything if there is none.
- The managed name factory ties each recipe to its endpoint so cleanup can
  find it. A durable name created outside that factory is your program's to
  retire.

### Freeing the space

Loam's collection frees the space. It keeps anything held at run time,
anything a stored strong reference reaches, and old versions a lease still
holds, and frees disconnected pages and payloads once nothing holds them.

- Each durable name keeps its index entry forever: 25 key bytes plus 33
  object identity bytes, **58 bytes per name**, before engine overhead.
- Retiring things does not shrink the database file. Compacting it is a
  separate step on each [disk engine](sqlite.md#shrinking-the-file).
- Creating a new identity reserves at most four identity paths, and ordinary
  access reads reserve none.

[ADR-0180](../decisions/adr/ADR-0180-bounded-managed-retirement.md) records
these rules, and the
[Zig cleanup tests](../../test/loam/access/maintenance_test.zig),
[LMDB reopen tests](../../test/loam/lmdb/maintenance_test.zig), and
[managed process test](../../test/loam_managed_crash.zig) check them.

## C and Rust resources

The [C and Rust guide](c-and-rust.md) covers the C and Rust API, shutting
down workers, startup, and shutdown.
