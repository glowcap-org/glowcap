# Managed access records

Status: living-state surface. Use this guide for Zig resource structure,
held use/control references, hosted access methods and exact retries. The
[store and actor guide](../loam.md) owns backend and Host attachment custody.

## What managed access is for

Passing a reference is often all the sharing an application needs. Alice can
hand Bob a read-only wrapper around her board and cut it later. Managed access
is for applications that also need to see who has access, change it after the
fact, and let Bob share a narrower part onward. It keeps that bookkeeping in
Loam records, in the same transactions as the content it protects.

- A **resource** is something the application owns, arranged in a tree, such
  as a board and its columns.
- A **grant** gives permission over one resource, a chosen set, or a resource
  and everything below it. A grant made from another grant sits under it and
  can never be wider than any grant above it.
- A **use reference** exercises one grant. A **control reference** is a
  separate capability that can pause, resume, or revoke that grant. Bob can
  hold the first without being able to change his own access.

Every use is checked against the whole chain of grants above it at the moment
of use, so revoking a grant cuts off everything shared from it. The
[website's Loam page](https://jimisaacs.github.io/glowcap/loam/#sharing-with-people)
draws this. The rest of this guide is the Zig contract.

`access.core.GrantView` evaluates current grant ancestry alongside a
`ResourceView`. Both consume synchronous record sources; an unloaded row
returns a read demand for the embedding to service. They perform no hidden
storage I/O. The resident graph and ledger use these same views.

`GrantPlan.prepareCopying` prepares a trusted owner's mutation at that view
revision. `plan.changes` returns the proposed grant, optional parent update,
expected previous row revisions, and change event. The owner stages those
records with its content through one Loam transaction and exposes the event
after confirmed commit. The plan does not reserve a transaction or prove the
caller's management authority. Held use and control references still convey
that authority through their owning binding.

`access.records.ResourceRecord` and `ChangeHistoryRecord` decode into scalar values.
`ChangeBatchRecord.decodeOwned(allocator, view)` owns its bounded effect paths;
release them with `deinit(allocator)`.
`ResourceRecord.decode(view)` validates the complete resource row's strong-edge
shape. Its child-index identity comes from that edge; the payload records only
whether the index exists. A logical parent also requires one retaining edge.
`GrantRecord.decodeOwned(allocator, bytes)` owns any selected-resource lists;
call `deinit(allocator)` on that result. None retains the encoded input. The
[record contract](../decisions/adr/ADR-0166-access-grant-records-and-plans.md) defines
limits and borrowed view lifetimes.

## Durable owner operations

`access.storage` connects these views to a Store. Register
`access.records.profile.schemas` alongside the application's schemas. Supporting
the full managed profile requires record limits of at least 64 KiB and 514
edges. The managed payload format is prerelease; use a fresh directory for
this profile. Within a staging transaction, `storage.stage.createOwner` returns the
owner's Loam header reference. Retain that reference after confirmed commit and
use it to reopen the owner. The header persists its complete policy descriptor,
logical revision pair, independent control revision, allocation counters,
directory roots, and a bounded change-history root. Managed resource and grant
depths are at most 64.

Create a `storage.Read` with a bounded model-record capacity, then drive
`advance`. A `.read` result transfers a Loam read request to the embedding's
executor; deliver its exact completion through `completeRead`. `.waiting` means
work is outstanding or the operation yielded after a bounded amount of CPU work. `.ready`
allows the caller to retry its view operation. `resourceView` and `grantView`
share the resident model's evaluator. When an operation returns `RecordUnloaded`,
drive `advance` again and retry after readiness. Malformed records, missing
identities, stale revisions, and capacity exhaustion remain distinct failures.

For creation, prepare a `storage.Append` for the resource or grant family and
drive its `advance` through the same explicit read/completion pattern. A resource
append calls `prepareResource(parent)` after its identity path is ready.
Drive that method through the same read/completion pattern and retry
`RecordUnloaded` through the Read. It prepares parent ancestry and child membership
before `stage.appendResource` can write. For grant mutations, prepare
the shared `GrantPlan` using the Read's views and persisted policy; issuance
uses the header's next grant slot with generation one. Other mutations use the
existing grant identity. Call `storage.stage.prepareGrant(read, plan)` before
staging, driving `RecordUnloaded` through the Read. This prepares retained history
and the immutable ancestry needed for inventory stamps. Plans perform model checks; the trusted owner must
admit management authority before preparing one.

Begin the caller's Store transaction and stage content together with
`storage.stage.appendResource` or `storage.stage.grant`. Loam's existing
prepare/write/complete/recover path commits the whole batch. A failure after
managed staging starts aborts the entire batch, including content. Publish
proposed identities and events only after confirmed commit. Several managed changes can compose in one transaction. Each new preparation
uses the Read's current composed state, and the batch submits one header update
per owner. A preparation from older resource, grant or control state refuses.
The caller that began the batch must abort after this refusal, discarding its
earlier stages. A failure after a participant starts writing aborts the batch
through that participant's staging boundary. Hosted calls assign abort to
their transaction runner.
A Read that consumes proposed owner state belongs to that exact staging
transaction. Reopen it after the batch ends, including abort or known-absent
recovery. Every commit invalidates existing Reads; uncertain writes fence
their views until receipt recovery resolves the outcome.
An aborted unpublished append consumes no committed logical slot.

Read owns decoded header scalars and pins its bounded model working set.
It releases the header lease after decoding and retains its expected revision.
Mutations load the bounded history on demand; ordinary access checks do not. Directory traversal borrows
one additional cache slot and retains its position across misses. Its path is
at most four directory records plus the target. Capacity must fit within
`max_leases - 1`; allow cache space for pinned models and an active
directory or history read. A Read has at most 20 KiB of inline state plus its single binding
allocation; an Append has at most 52 KiB of inline path state. A resource append also owns
one allocated child-index path of the same bound until deinitialization. Grant decoding
uses fixed scratch whose borrow lasts until the next grant lookup. Loaded
evaluation makes no allocator calls. Store cache buffers reserve
`max_record_bytes` per slot, even for short records; these operation bounds
exclude those buffers and transaction staging.

Keep Read and Store at stable addresses while their views, an Append or a
ResourceChange borrow them. Append and ResourceChange take exclusive preparation
custody of the Read; release them before closing it or dropping resource bindings.
Cancellation preserves submitted buffers
until exact completion; `deinit` refuses outstanding work. The owner retains
indexed records, including revoked grants. The header retains a history record
with at most **32** chronological batch edges. Each owner has one batch per Store
transaction, with at most **16** ordered grant, resource, content or independent
control effects. Batch metadata retains no application payload or descriptor
edges. Dropping the oldest edge makes that batch collectible. A seventeenth
effect refuses with `ChangeCapacity` and aborts the entire composed batch.
Unchanged or aborted changes add no batch; a receipt for an unchanged result
can still commit without adding history.

Grant authority and descendant-inventory stamps are separate. Resources likewise
separate placement, subtree and content stamps. Ancestor inventory/subtree
updates cost bounded path writes, with at most 65 identities per affected path.
Equal content or reference replacements settle directly when no other participant
is needed. Hosting loads the content ancestry before invoking a mutable method;
metadata stamping remains an owner-only storage operation.

[ADR-0167](../decisions/adr/ADR-0167-managed-owner-storage.md) defines the profile.
LMDB tests cover reopen, abort, uncertain revocation with matching content,
and collection of expired batches.
[ADR-0179](../decisions/adr/ADR-0179-scoped-change-retention-and-observation.md)
owns retained changes and the implemented
[scoped observation contract](#observing-held-access). Durable capability
bindings build on this profile, as described below.

## Resource moves, deletion and children

A trusted owner prepares `storage.ResourceChange` against a Read, drives its
explicit read demands, and stages it with application content in the same batch.
`.move = parent` changes canonical containment while preserving identity.
`delete_leaf` refuses a resource with children, disconnects its membership and
persists an inactive identity. Content and unrelated capabilities keep their
own retention. Deleted-resource admission returns `Gone`;
[bounded owner cleanup](#bounded-owner-cleanup) reclaims terminal payloads
without reviving their identities.

The shared resource view rejects cycles and checks the deepest descendant
against the owner's depth limit before staging a move. Validation streams the
subtree with at most `max_resource_depth + 1` traversal frames and one transient
row lease. Work grows with descendants, while leaf moves touch bounded index
paths and ancestry. Old membership, new membership, canonical parent and owner
revision commit together. Empty directory paths become eligible for tracing.

Held use operations call `prepareResourceCopying(target, action, requirement)`.
Admission checks the source and both placement parents under that requirement.
After readiness, call `stageResource()` in the current batch. Hosted content
schemas can declare the same structural effect with `ContentBehavior.resource`;
the callback decodes an action, and the shared operation enforces it.
Its payload replacement and mutation receipt commit with that action.

`Operation.children(parent, requirement)` returns an owned Zig cursor.
Each `advance()` produces an authorized resource ID, a read request, waiting,
or completion. Hidden candidates are filtered before returning items. The
cursor holds its operation, keeps one four-level directory path and drops
completed resource bindings. It exposes no raw index position, sibling count,
or owner revision. An intervening commit yields `RevisionConflict`; reopen
and authorize a fresh query. Cancel submitted reads and retire their exact
completions before deinitialization. Release the cursor before its operation.
One operation owns one cursor because its Read has one authority-demand lane.
Iteration and effect preparation are exclusive on that operation: preparation
returns `Busy` while a cursor exists, and opening a cursor after preparing an
effect returns `WrongPhase`. Independent operations can compose; prepare each
against the state already staged by its predecessors.

## Durable use and control references

`storage.Capabilities` borrows one Store and enforces live-reference and operation
quotas. The trusted embedding stages use or control descriptors through
`stageUse` and `stageControl` with a current owner Read. Control powers use
`core.Control.Powers`: a policy ceiling and independent lifecycle permissions.
After confirmed commit, `restoreUse` or `restoreControl` checks a borrowed
descriptor lease to create an opaque Zig reference. Release the lease;
the reference retains the descriptor through Loam's live roots without pinning it.

Each reference's `begin(capacity)` creates an opaque `Operation`. The embedding
drives `advance` and `completeRead` as with Read; storage requests belong to its
executor and must stay out of hosted resource replies. Use operations expose `require` and
`prepareDeriveCopying`; controls expose `prepareEditCopying`. Wrong-role operations
refuse. Calls select the grant bound in the stored descriptor and check current
owner/grant records. An operation exposes no Store, raw model view, or grant
selector. On `RecordUnloaded`, drive the read work and retry the same request;
input slices need remain valid only through each synchronous method call.
Successful preparation owns any copied terms until operation close. One
operation prepares one effect; compose several operations in the owner batch.

The trusted owner stages a prepared operation through `Capabilities.stage` in
the same Store transaction as content. It returns a proposed change and, for
derivation, a `derived_use` descriptor reference. The child grant and descriptor
commit together. Choose root retention or place a strong edge to that descriptor
in content before committing. Direct `storage.stage.grant` similarly returns
both the proposed change and its exact Loam grant-record reference for trusted
composition. Restore or publish results only after confirmed commit.

Operations retain their source reference, so the holder may release its alias
while work remains pending. `cancel` retires work through exact completion;
`deinit` refuses submitted reads. Close finished operations to release their
leases before admitting more work within the same cache budget. Capabilities
cannot close while any reference or operation remains. Descriptor records are
collectible after both durable retention and final runtime custody end.

Each reference allocates at most 96 bytes of binding state. Starting an operation
allocates at most 32 KiB, including separate fixed scratch for control and grant
terms. Opening also allocates the bounded Read binding array; delegation adds
the bounded Append and copied plan terms. Allow two leases for the descriptor
and owner header, plus the model working set and one transient directory page.
Concurrent operations share cache capacity and lease quotas. Loaded checks make
no allocator calls. Every commit invalidates old operations; uncertain outcomes
fence them until receipt recovery resolves the write.

[ADR-0168](../decisions/adr/ADR-0168-durable-managed-capability-bindings.md) defines
the restoration contract. These are Zig admission primitives; bind a use
check to its content effect at the same revision, or use the managed hosting
adapter below. Controls also expose copied attenuation, independent revocation
and scoped inspection through the [management methods](#managing-a-held-control).
Powers are immutable; narrowing creates a dependent control descriptor. Grant
lifecycle and terms remain editable.

## Managed endpoints on the Host

`access.hosting.Service` borrows Capabilities and a table of `ContentBehavior`
descriptors. Add every entry from its `behaviors()` array to the existing
`hosting.Attachment` behavior table. The Service, Capabilities, and behavior
tables must remain at stable addresses until `Attachment.destroy` succeeds. A Busy teardown retains pending
work, so every borrowed application context must remain alive. Outer attachment
behavior descriptors remain immutable during that lifetime. No additional
Host, Vat, worker, or storage queue is created.

The trusted embedding prepares a current owner Read, including its bounded
`prepareIdentities(count)` paths, before calling `stageEndpoint(read, ...)` in a
Store batch. Load the committed descriptor before opening that batch. A use endpoint
retains its exact use descriptor and binds one resource identity to one content
record. A control endpoint retains only its exact control descriptor. This
binding is application authority: the embedding must associate the right
resource with the right content. The recipient receives an ordinary hosted
capability; method arguments cannot replace that binding. Derivation updates the
endpoint's receipt window while preserving its authority and content binding.
After commit, restore the endpoint from a checked
lease. `stagePublication(store, endpoint_lease, entropy)` atomically binds its
one durable publication recipe; restore that recipe after commit. Local
capability edges use the ordinary Attachment capture seam. Descriptors and
endpoints register weak owner membership in their creation transaction.

For use calls, preparation loads the descriptor, content, and current managed
records. The content schema selects one `ContentBehavior` by value for the
retained preparation. Its borrowed `context` is passed to requirement, retry, resource,
reference, dependent-requirement and invocation callbacks. Service decoders
receive the separate `Service.context`; entropy keeps its own callback/context
pair. Selection and sharing entropy bindings survive storage waits. Replacing
`Service.contents` or `Service.entropy` affects future preparations and
revision restarts; old contexts and returned borrows remain valid through settlement. Other Service
configuration remains stable while calls are pending.

The pure `requirement` callback declares permissions and all relevant committed
facts. The inline descriptor and entropy-source snapshots charge existing
bounded call bytes; they allocate no callback context or payload copy. Existing
per-call quotas admit these bytes or refuse preparation normally. Only after the
bound grant admits that requirement does `invoke` run on the existing Vat.
`ContentCall.replace` proposes a new content payload while preserving its edges.
`replaceReference` and `removeReference` update a declared strong field in that
same content transaction. `ContentCall.discloseExact` hands over a stored strong
edge's saved authority. `discloseDependent` instead returns a runtime facet
whose target method must pass the current invoking and target grants. Any
capability the method did not declare is refused before settlement.
[ADR-0172](../decisions/adr/ADR-0172-explicit-disclosure-of-returned-capabilities.md)
defines exact disclosure, and
[ADR-0173](../decisions/adr/ADR-0173-dependent-returned-capabilities-and-reference-edits.md)
defines dependent disclosure and field edits.
The [durable capability field guide](references.md) covers checked local and
foreign recipes, `ContentBehavior.references`, external saves, dependent
forwarding requirements, and unsupported receipt capability kinds.
The attachment commits that content row before settling the reply. The endpoint
portrait is unchanged. Application callbacks are trusted, deterministic Zig
code with no external effects; this API is not a machine-code sandbox.

Control endpoints accept `pause`, `resume`, and `revoke` with no arguments.
Replies are Boolean: true for a committed change and false for an unchanged
request. An optional `decode_control` callback maps application methods to
`core.Control.Edit`, including policy edits. It only decodes requests; the
stored control powers and shared model rules decide whether they are permitted.
The decoder runs after control reads and receives loaded `Control.Powers`.
Its policy ceiling supplies scope for application policy edits. Returned terms
may borrow that scope until settlement; authority admission remains with the
shared operation, including idempotent repeated revocation.
A changed edit stages the grant, owner revision, and retained change batch in
the attachment's transaction. Direct lifecycle edits are idempotent. Use the receipt wrapper below to recover
the exact first result after a lost reply. Held
[receive capabilities](#observing-held-access) project scoped changes through
ordinary CapTP calls.

Preparation and its leases belong to the retained call. Any intervening Store
commit restarts preparation, including calls already queued for invocation.
Outstanding reads retire through exact completion before their buffers or
operation state are released. Unknown writes keep the existing recovery fence;
no affected call replies successfully until recovery resolves it. Resident near
calls return `DurableTurnRequired` for managed endpoints; use eventual sends.

Budget the endpoint and content leases in addition to the managed operation's
descriptor, header, model records, and transient directory page. `record_capacity`
bounds the model working set; Capabilities quotas bound concurrently allocated
operations. These allocations are additional to the attachment's retained-call
arena and share the Store's cache and lease limits. Settled calls release all
operation custody. Content and authority rows remain eligible for ordinary LRU
eviction; sleeping references retain reachability without pinning those rows.

The generic `hosting.Behavior.prepare` seam emits read work through the same
attachment, and `Call.transaction` stages a trusted participant in its batch.
Participants must only stage mutations; the attachment begins and commits. Managed hosting
uses these seams for content, structural, control, and derivation calls.
[Reference recipes](references.md) restore held local and foreign authority;
[scoped observation](#observing-held-access) uses the same preparation and
transaction owners.
[ADR-0169](../decisions/adr/ADR-0169-managed-host-turns.md) records the contract.

## Retrying mutations

Every content method supplies a pure `ContentBehavior.retry` classification:
`read_only`, `idempotent`, or `receipt`. A read cannot stage an effect.
Receipt-backed methods require `mutate(sequence, method, arguments...)`; a
bare call returns `RetryRequired` after current admission and before invocation.
Call `mutation-sequence()` to obtain the next sequence, beginning at one.
All holders of an endpoint share that sequence and must coordinate new requests.

The endpoint retains eight mutation receipts separately from its derivation
receipts. Each receipt records exact method, arguments, dependent target where
present, and first committed result. Capability leaves use durable strong edges.
A matching retry rechecks current authority and returns that result without
invoking the effect. Changed intent yields `OperationConflict`, future sequence
numbers yield `OperationOutOfOrder`, and retired sequence numbers yield
`ReceiptExpired`. Expiry cannot make an old request new. Sequence exhaustion
refuses. Current revocation, deletion or scope loss can prevent replay.

Wrapped idempotent edits retain the first Boolean result, even when a later
bare edit would return false. A wrapped no-op still commits its receipt.
Content, reference edits, resource structure, control state and receipts share
the attachment transaction. Unknown writes keep the existing recovery fence.
These receipts recover bounded local results; they do not promise exactly-once
remote delivery or persistence of arbitrary external effects.

Receipt values allow 32 KiB each, nesting depth 64 and at most 64 distinct
capability leaves across request and result. Combined encoded receipts fit
64 KiB. Binding storage grows only for actual capabilities; scalar calls fit
the workload's existing 4 KiB call arena. Encoding measures before allocation.
Decoding containers owns allocations while byte leaves borrow the receipt
lease. The call arena and receipt lease retain that ownership through settlement.
Expiring source edges makes old receipts eligible for tracing collection.
[Terminal owner cleanup](#bounded-owner-cleanup) preserves the sequence floor
while reclaiming old receipts, so an expired operation cannot execute again.

## Managing a held control

`Operation.describeControl()` reports current availability, grant status and
its own immutable powers. Selected policy-ceiling IDs borrow the operation
until deinitialization. Drive missing records as for other operations.
`prepareAttenuationCopying(powers)` narrows Boolean powers and a selected policy
ceiling. Stage it with `Capabilities.stageAttenuatedControl(operation, rooted)`.
The resulting descriptor retains its parent control and the same exact grant.
`prepareControlRevocation()` and `stageControlRevocation()` disable that
control and its management descendants without changing use authority.

Control dependency walks hold one transient ancestor lease and obey the
owner's grant-depth limit. Creation copies selected ceilings, bounded by the
existing scope-selection limit. Every new operation checks current dependencies;
retained references and receipts do not bypass independent control revocation.
Grant policy and lifecycle still follow shared grant ancestry. A paused grant's
control may resume its own grant; a revoked ancestor cannot regain use access.
Repeating a control's own terminal revocation is harmless.

Hosted controls accept `describe-control()`, `revoke-control()`, and
`mutate(sequence, "attenuate-control", application arguments...)` when the
Service supplies `decode_attenuation`. The decoder receives loaded held powers
and supplies requested powers;
shared rules decide admission. An active `access:control` description contains
status, pause/resume/revoke Booleans, its policy ceiling or false, and whether
that ceiling covers an owned subtree. Unavailable replies contain status alone.
The encoding discloses no resource, owner or ancestor identity.

## Inspecting held access

Call `describe-access()` on a managed use endpoint to inspect its current
access to that endpoint's fixed resource. Active replies include its own
ceiling and configured policy, effective policy after ancestor restrictions,
and remaining delegation depth. Paused, revoked, and out-of-scope replies carry
only status. Control endpoints do not accept this use method.

The tagged `access:description` reply uses stable permission and constraint
keys. [ADR-0171](../decisions/adr/ADR-0171-scoped-access-descriptions.md) defines the
field layout and exact unsigned integer representation. No ancestor identity,
scope inventory, owner revision, or unrelated event counter is disclosed.
This snapshot does not authorize subsequent content effects or provide an event
subscription. Each protected call continues to check current authority.

Zig consumers use `GrantUse.describe(target)` or
`storage.Operation.describe(target)`. The latter returns owned bounded values
with their immutable policy vocabulary. Drive missing reads as for `require`;
stale operations and uncertain writes refuse. Hosted preparation retries stale
snapshots before invocation. Description loads authority records and leaves
application content asleep. Encoding and reply copies share the bounded call
arena; larger vocabularies need sufficient call and frame capacity.
The maximum-policy test exercises all 64 permissions and 16 constraints across
the three policies within the default 64 KiB call arena. Frame capacity remains
a separate limit; this is no throughput measurement.

## Observing held access

Call `mutate(sequence, "observe")` on a managed use or control endpoint to
register observation of its exact descriptor. The two-item result contains a
receiver and an independent canceller. Registration shares the endpoint's eight
mutation receipts: retrying the exact request recovers the same fronts without
creating another context. Set `Service.entropy.fill` before registration.
Runtime dependent facets do not accept this fixed-descriptor method.

The receiver accepts `poll()` or `receive()`, optionally with the last cursor as
one bytes argument. `poll` returns the current result; `receive` waits when that
cursor is unchanged. The tagged `access:observation` reply contains, in order:
a 56-byte cursor, the existing scoped use or control description, a
resynchronization Boolean, a changed Boolean, and a list of notice symbols.
The notice categories are `access`, `target`, `inventory`, and `management`.
They describe retained changes; delivery can coalesce several committed batches
with the current authorized snapshot. A snapshot does not authorize a later call.

The cursor binds one context and carries no authority by itself. Keep the
receiver's durable name and cursor to resume after disconnect or restart.
Hidden sibling commits preserve the cursor, including when requesting a fresh
snapshot without an input cursor. Expired visible history sets resynchronization
and supplies the current snapshot. Paused use discloses status alone; policy or
content edits while paused do not perturb its cursor. Revoked use and unavailable
controls likewise disclose status alone. Delivery rechecks current authority
through the same evaluator and Store revision fence as ordinary calls.

Call `cancel()` on the canceller to close the context. It atomically removes the
owner's retention edge, clears the context's source edges and sealing key, and
retires both durable names. A held canceller returns false after closure; an
exact registration retry refuses instead of reminting the closed context.
Cancellation can run while its receiver waits. Abort preserves the context and
names; uncertain writes use the ordinary recovery and retirement fences.

Each owner admits at most 32 contexts. Cancellation frees that quota. Each
context retains its exact descriptor and optional fixed resource identity, with
a 32-byte unpredictable sealing key and an immutable registration boundary.
Grant and resource dependency stamps pair their revision with the corresponding
committed batch position. The cursor seals only the relevant scoped position
and digest using Zig's AES-128-SIV implementation, with the context identity as
associated data. Neither raw revisions nor owner counters appear on the wire.
[ADR-0179](../decisions/adr/ADR-0179-scoped-change-retention-and-observation.md)
owns retention, privacy and replay.

Zig consumers use opaque `storage.ObservationRegistration`,
`storage.Observation`, and `storage.ObservationCancellation` operations.
Registration borrows an unprepared source `Operation`, takes a target for use
or null for control and an embedding-supplied key, and stages into the caller's
Store transaction. Drive missing source reads before retrying construction,
then drive the registration's reads. Its child custody prevents the source from
closing early. Polling starts from a committed context lease and returns owned
bounded values. Cancellation also starts from a context lease and stages in the
caller's transaction. Published contexts require the hosting retirement bridge;
a Zig caller cannot silently leave their names active. Cancel submitted reads
and join their exact completions before releasing operations.

Record-binding, cache, lease, retention, call-arena, ingress and transport limits
remain independent. Parked hosted receivers release managed operations and model
leases. Ready replies release them after copying their snapshots; Attachment
rechecks the revision before delivery. The maximum-fanout test admits 32 cold
receivers with eight model bindings per call, 296 leases, 80 cache slots, a 5 MiB
resident budget, 168 retention slots, 4 MiB ingress capacity and a 128 KiB
outbound waterline at a 4 KiB frame cap. Smaller budgets refuse explicitly;
32 context slots alone do not promise 32 simultaneous cold calls. Deep paths
need larger binding budgets within the same bounded operations.

## Deriving and recovering a shared facet

Set `Service.decode_derive` to decode application arguments into
`core.GrantLedger.Issue`, and supply `Service.entropy.fill` with fresh unpredictable
entropy across calls and restarts. The decoder receives the endpoint's bound
resource identity. Decoding does not grant permission: current ancestor scope,
terms, lifecycle, and delegation depth constrain every new child.

Managed use endpoints reserve these methods:

| Method | Result |
| --- | --- |
| `derivation-sequence()` | The next derivation sequence for this endpoint, beginning at 1. |
| `derive-managed(sequence, application arguments...)` | A two-item list containing separate use and issuer control capabilities, when `decode_managed_derive` is configured. |
| `derive(sequence, application arguments...)` | A held CapTP use capability for the same content/resource binding. |
| `durable-name()` | The endpoint's durable Swiss name, or `NotPublished` when it has no publication recipe. This is the secret publication component; the existing Host locator APIs supply peer routing. |

These methods check current use authority. `derive` returns use alone.
`derive-managed` decodes a `Service.ManagedIssue` containing grant terms and
control powers, and returns both to the issuer. Its policy ceiling must fit
the child grant. The use endpoint cannot recover its control; recovery requires
the issuing source and exact intent. Publish a control separately if it needs
its own durable locator. Zig `prepareManagedDeriveCopying` and
`Capabilities.stage` expose the same atomic use/control issuance. An initially paused child is minted paused. Exact disclosures preserve a
stored field's saved authority; this API does not automatically attenuate other
capability-valued application replies.

The child grant, use descriptor, optional control descriptor and endpoint,
rooted use publication, retry receipt,
and source sequence update commit in one Store batch. `Call.result` runs at the
top-level Host boundary after Vat staging and before write submission. It reserves
the child actor and a hidden publication through `Host.reserveDurableCapability`.
No fetch can discover that reservation. `Call.confirmation` activates it without
allocation after confirmed commit and before reply projection. Abort releases
the reservation; an unknown write retains it until recovery. Publication
reservations must be moved, then committed or canceled before Host teardown.

The source retains its last **eight** receipts, indexed directly by sequence
through ordered strong edges. A matching retained request returns the same
child; changed decoded terms yield `OperationConflict`. An older sequence yields
`ReceiptExpired`, and a future sequence yields `OperationOutOfOrder`. Expiry never
makes an old sequence eligible to mint again. All holders of one endpoint share
the sequence domain and must coordinate competing new requests. Retries also
check the source and child at the current revision: pause or revocation cannot
be bypassed by replay. This provides bounded recovery of derivation results;
other mutations use the separate mutation window described above.

Receipt eviction drops its source edge, allowing ordinary collection. It does
not retire the child's independently rooted publication. Applications must
explicitly retire publications when durable discovery should end. Terminal managed identities and indexed grant payloads can be retired through
[bounded owner cleanup](#bounded-owner-cleanup).
On startup, enable `publication.listen` for on-demand discovery of these
descriptors. A retained retry can also restore its exact child and publication
after reopen.

Endpoint format version 1 reserves nineteen edges: descriptor, optional content,
optional publication, and eight receipts in each sequence domain. A derivation
receipt permits 32 KiB of canonical intent and two edges, or three when it
retains issuer control. Intent encoding and sharing state use the
bounded call arena. Replay holds three additional record leases and a child
operation while checking authority. Managed replay additionally holds its
control endpoint and a bounded control operation; issuance uses the Zig
Append budget.
Actor and publication allocation happens before submission and may refuse
under pressure. None of these costs apply to unmanaged actors.
[ADR-0170](../decisions/adr/ADR-0170-durable-facet-derivation.md) owns this contract.

## Bounded owner cleanup

A trusted embedding may restore an owner record through the Service's owner
behavior. That capability administers the owner; use and grant-control
capabilities cannot produce it. `sweep(sequence)` starts terminal cleanup while
preserving active authority. `retire-owner(sequence)` closes ordinary admission
before cleanup starts. `maintenance-step(sequence)` advances one prepared unit.
The tagged `access:maintenance` reply carries the next sequence, phase, retired
flag and replay flag. Start at zero; retry the last acknowledged request with its
original sequence. The immediately previous matching command returns its recorded
progress without another effect. Older, conflicting and future requests refuse.

Zig embeddings use opaque `storage.Maintenance` operations with the same
commands and sequence. Drive their read requests before opening a Store batch,
then stage and commit through the owning executor. Operations bind one Store
revision; abort, uncertain outcomes and intervening commits require a fresh
preparation. Submitted reads retain exact ticket and buffer custody through
cancellation and completion. `deinit` refuses outstanding reads.

Cleanup visits the bounded observation index, weak identity directory, grants
and resources. Each indexed step seeks one sparse four-level path and checks
one bounded authority path. A step does not scan unrelated owners. Revoked
management dependencies, revoked grant branches and deleted content targets
retire their affected identities. Grant pruning decreases a surviving parent's
child count and journals its scoped inventory change. Empty directories retain
their allocation high-water marks. New capabilities register in their creation
transaction; weak inventory leaves preserve ordinary collection lifetimes.

Terminal endpoints and descriptors lose payload/dependency edges and become
explicit dead records. Endpoint records preserve both receipt sequence floors
while discarding receipt edges. Held references retain that refusal record,
and checked replay refuses a retired result without reminting it. Retiring an
owner first fences pending ordinary work, cancels its observations, then compacts
its indexed identities and rows before dropping resource and event roots. The
small owner header preserves identity floors and terminal progress.

Active publications remain rooted until explicit retirement. Hosted maintenance
loads their recipes and stages retirement through the Attachment's existing
write and uncertainty fence. Zig maintenance with publication-bearing rows
requires that owning retirement callback; it refuses before effects if none is
provided. The managed publication factory binds the recipe to its endpoint so
cleanup can find it. A generic publication created outside that managed factory
belongs to its embedding's explicit retirement protocol.

Physical collection remains Loam tracing. It protects runtime retains, stored
strong references and pinned historical edges, and reclaims disconnected pages
and payloads after their custody ends. Durable names keep their immutable index
reservation: 25 key bytes plus 33 object-identity bytes, **58 logical bytes per
name**, before backend overhead. Retirement does not shrink the LMDB file;
compaction is a separate maintenance contract. Mint preparation reserves at most
four identity paths; ordinary access reads allocate none of those paths.

The managed owner format is prerelease; create fresh directories for stores made
before this identity inventory and maintenance position existed.
[ADR-0180](../decisions/adr/ADR-0180-bounded-managed-retirement.md),
[Zig cleanup tests](../../test/loam/access/maintenance_test.zig),
[LMDB/reopen tests](../../test/loam/lmdb/maintenance_test.zig), and the
[managed process proof](../../test/loam_managed_crash.zig) own these guarantees.

## C and Rust resources

The [C/Rust lifecycle guide](c-and-rust.md) owns the language projection,
worker retirement, startup and shutdown contract.
