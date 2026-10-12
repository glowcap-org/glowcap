# Managed access records

Status: living-state surface. This guide covers Zig resource structure, held
use and control references, hosted access methods, and exact retries. The
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
draws this.

`access.core.GrantView` evaluates current grant ancestry alongside a
`ResourceView`. Both consume synchronous record sources. An unloaded row
returns a read demand for the embedding to service, and neither view performs
storage I/O. The resident graph and ledger use these same views.

`GrantPlan.prepareCopying` prepares a trusted owner's mutation at that view
revision. `plan.changes` returns the proposed grant, optional parent update,
expected previous row revisions, and change event. The owner stages those
records with its content through one Loam transaction and exposes the event
after confirmed commit. The plan does not reserve a transaction or prove the
caller's management authority. Held use and control references still convey
that authority through their owning binding.

`access.records.ResourceRecord` and `ChangeHistoryRecord` decode into scalar
values. `ChangeBatchRecord.decodeOwned(allocator, view)` owns its bounded effect
paths, and `GrantRecord.decodeOwned(allocator, bytes)` owns any
selected-resource lists. Release both with `deinit(allocator)`. None retains the
encoded input. `ResourceRecord.decode(view)` validates the resource row's
strong-edge shape. Its child-index identity comes from that edge, and the
payload records only whether the index exists. A logical parent also requires
one retaining edge. The [record
contract](../decisions/adr/ADR-0166-access-grant-records-and-plans.md) defines
limits and borrowed view lifetimes.

## Policy and interface support

A policy keeps one complete permission vocabulary. `Policy.Descriptor.kinds`
declares exact-object and future-subtree support by resource kind. An empty
table makes the policy kind-independent. A nonempty table refuses
unknown kinds. `Terms.validate` checks support for the selected scope, and
`GrantView.require` checks each effect's exact target. Mixed selections use the
union of their interfaces. Subtree support comes from the root declaration,
without scanning descendants.

Pass the owner's immutable policy to `Graph.create` and `Graph.reparent`, as
for grant operations. Stored creation and moves use the current owner
header. Both enforce that a child's future support fits its parent's. The
[scope decision](../decisions/adr/ADR-0197-scope-aware-permission-applicability.md)
records bounds and alternatives. `Policy.valueForKind` prepares exact-interface
terms. Its result supplies data, not admission for a later effect.

## Durable owner operations

`access.storage` connects these views to a Store. Register
`access.records.profile.schemas` alongside the application's schemas. The full
managed profile requires record limits of at least 64 KiB and 514 edges. The
managed payload format is prerelease, so use a fresh directory for this
profile. Within a staging transaction, `storage.stage.createOwner` returns the
owner's Loam header reference. Retain that reference after confirmed commit and
use it to reopen the owner. The header persists its complete policy descriptor,
logical revision pair, independent control revision, allocation counters,
directory roots, and a bounded change-history root. Managed resource and grant
depths are at most 64.

Create a `storage.Read` with a bounded model-record capacity, then drive
`advance`. A `.read` result transfers a Loam read request to the embedding's
executor. Deliver its exact completion through `completeRead`. `.waiting` means
work is outstanding or the operation yielded after a bounded amount of CPU
work. `.ready` allows the caller to retry its view operation. `resourceView` and `grantView`
share the resident model's evaluator. When an operation returns `RecordUnloaded`,
drive `advance` again and retry after readiness. Malformed records, missing
identities, stale revisions, and capacity exhaustion remain distinct failures.

For creation, prepare a `storage.Append` for the resource or grant family and
drive its `advance` through the same explicit read/completion pattern. A
resource append calls `prepareResource(parent)` after its identity path is
ready. Drive that method through the same read/completion pattern and retry
`RecordUnloaded` through the Read. It prepares parent ancestry and child
membership before `stage.appendResource` can write. For grant mutations, prepare
the shared `GrantPlan` using the Read's views and persisted policy. Issuance
uses the header's next grant slot with generation one. Other mutations use the
existing grant identity. Call `storage.stage.prepareGrant(read, plan)` before
staging, driving `RecordUnloaded` through the Read. This prepares retained
history and the immutable ancestry needed for inventory stamps. Plans perform
model checks, so the trusted owner must admit management authority before
preparing one.

Begin the caller's Store transaction and stage content together with
`storage.stage.appendResource` or `storage.stage.grant`. Loam's existing
prepare/write/complete/recover path commits the whole batch. A failure after
managed staging starts aborts the entire batch, including content. Publish
proposed identities and events only after confirmed commit.

Several managed changes can compose in one transaction. Each new preparation
uses the Read's current composed state, and the batch submits one header update
per owner. A preparation from older resource, grant or control state refuses.
The caller that began the batch must abort after this refusal, discarding its
earlier stages. A failure after a participant starts writing aborts the batch
through that participant's staging boundary. Hosted calls assign abort to their
transaction runner. A Read that consumes proposed owner state belongs to that
exact staging transaction. Reopen it after the batch ends, including abort or
known-absent recovery. Every commit invalidates existing Reads. Uncertain writes
fence their views until receipt recovery resolves the outcome. An aborted
unpublished append consumes no committed logical slot.

Read owns decoded header scalars and pins its bounded model working set.
It releases the header lease after decoding and retains its expected revision.
Mutations load the bounded history on demand, and ordinary access checks do
not. Directory traversal borrows one additional cache slot and retains its
position across misses. Its path is at most four directory records plus the
target. Capacity must fit within `max_leases - 1`, with cache space for pinned
models and an active directory or history read. A Read has at most 20 KiB of
inline state plus its single binding allocation. An Append has at most 52 KiB
of inline path state, and a resource append also owns one allocated child-index
path of the same bound until deinitialization. Grant decoding uses fixed
scratch whose borrow lasts until the next grant lookup. Loaded
evaluation makes no allocator calls. Store cache buffers reserve
`max_record_bytes` per slot, even for short records. These operation bounds
exclude those buffers and transaction staging.

Keep Read and Store at stable addresses while their views, an Append or a
ResourceChange borrow them. Append and ResourceChange take exclusive preparation
custody of the Read. Release them before closing it or dropping resource
bindings. Cancellation preserves submitted buffers until completion. `deinit`
refuses outstanding work. The owner retains indexed records, including revoked
grants. The header retains a history record with at most **32** chronological
batch edges. Each owner has one batch per Store transaction, with at most **16**
ordered grant, resource, content or independent control effects. Batch metadata
retains no application payload or descriptor edges. Dropping the oldest edge
makes that batch collectible. A seventeenth effect refuses with `ChangeCapacity`
and aborts the entire composed batch. Unchanged or aborted changes add no batch.
A receipt for an unchanged result can still commit without adding history.

Grant authority and descendant-inventory stamps are separate. Resources likewise
separate placement, subtree and content stamps. Ancestor inventory/subtree
updates cost bounded path writes, with at most 65 identities per affected path.
Equal content or reference replacements settle directly when no other
participant is needed. Hosting loads the content ancestry before invoking a mutable method.
Metadata stamping remains an owner-only storage operation.

[ADR-0167](../decisions/adr/ADR-0167-managed-owner-storage.md) defines the profile.
LMDB tests cover reopen, abort, uncertain revocation with matching content,
and collection of expired batches.
[ADR-0179](../decisions/adr/ADR-0179-scoped-change-retention-and-observation.md)
owns retained changes and the implemented
[scoped observation contract](#observing-held-access). Durable capability
bindings build on this profile, as described below.

## Resource moves, deletion and children

A trusted owner prepares `storage.ResourceChange` against a Read, drives its
read demands, and stages it with application content in the same batch.
`.move = parent` changes canonical containment while preserving identity.
`delete_leaf` refuses a resource with children, disconnects its membership and
persists an inactive identity. Content and unrelated capabilities keep their
retention. Deleted-resource admission returns `Gone`. [Bounded owner
cleanup](#bounded-owner-cleanup) reclaims terminal payloads without reviving
their identities.

The shared resource view rejects cycles and checks the deepest descendant
against the owner's depth limit before staging a move. Validation streams the
subtree with at most `max_resource_depth + 1` traversal frames and one transient
row lease. Work grows with descendants, while leaf moves touch bounded index
paths and ancestry. Old membership, new membership, canonical parent and owner
revision commit together. Empty directory paths become eligible for tracing.

Held use operations call `prepareResourceCopying(target, action, requirement)`.
Admission checks the source and both placement parents under that requirement.
After readiness, call `stageResource()` in the current batch. Hosted content
schemas can declare the same structural effect with `ContentBehavior.resource`.
The callback decodes an action, and the shared operation enforces it.
Its payload replacement and mutation receipt commit with that action.

`Operation.children(parent, requirement)` returns an owned Zig cursor.
Each `advance()` produces an authorized resource ID, a read request, waiting,
or completion. Hidden candidates are filtered before returning items. The
cursor holds its operation, keeps one four-level directory path and drops
completed resource bindings. It exposes no raw index position, sibling count,
or owner revision. An intervening commit yields `RevisionConflict`. Reopen
and authorize a fresh query. Cancel submitted reads and retire their exact
completions before deinitialization. Release the cursor before its operation.
One operation owns one cursor because its Read has one authority-demand lane.
Iteration and effect preparation are exclusive on that operation: preparation
returns `Busy` while a cursor exists, and opening a cursor after preparing an
effect returns `WrongPhase`. Independent operations can compose when each
prepares against the state its predecessors staged.

## Durable use and control references

`storage.Capabilities` borrows one Store and enforces live-reference and operation
quotas. The trusted embedding stages use or control descriptors through
`stageUse` and `stageControl` with a current owner Read. Control powers use
`core.Control.Powers`: independent Inspect, Issue, Edit and DelegateControl
powers beside lifecycle permissions. Issue and Edit each have a copied ceiling.
After confirmed commit, `restoreUse` or `restoreControl` checks a borrowed
descriptor lease to create an opaque Zig reference. Release the lease.
The reference retains the descriptor through Loam's live roots without pinning it.

Each reference's `begin(capacity)` creates an opaque `Operation`. The embedding
drives `advance` and `completeRead` as with Read. Storage requests belong to its
executor and stay out of hosted resource replies. Use operations expose `require` and
`prepareDeriveCopying`. Controls expose `prepareEditCopying`. Wrong-role operations
refuse. Calls select the grant bound in the stored descriptor and check current
owner/grant records. An operation exposes no Store, raw model view, or grant
selector. On `RecordUnloaded`, drive the read work and retry the same request.
Input slices need to remain valid only through each synchronous method call.
Successful preparation owns any copied terms until operation close. One
operation prepares one effect. Compose several operations in the owner batch.

The trusted owner stages a prepared operation through `Capabilities.stage` in
the same Store transaction as content. It returns a proposed change and, for
derivation, a `derived_use` descriptor reference. The child grant and descriptor
commit together. Before committing, either root that descriptor or place a strong edge to it in
content. Direct `storage.stage.grant` similarly returns
both the proposed change and its exact Loam grant-record reference for trusted
composition. Restore or publish results only after confirmed commit.

Operations retain their source reference, so the holder may release its alias
while work remains pending. `cancel` retires work through exact completion.
`deinit` refuses submitted reads. Close finished operations to release their
leases before admitting more work within the same cache budget. Capabilities
cannot close while any reference or operation remains. Descriptor records are
collectible after both durable retention and final runtime custody end.

Each reference allocates at most 96 bytes of binding state. Starting an operation
allocates at most 32 KiB, including separate fixed scratch for control and grant
terms. Opening also allocates the bounded Read binding array. Delegation adds
the bounded Append and copied plan terms. Allow two leases for the descriptor
and owner header, plus the model working set and one transient directory page.
Concurrent operations share cache capacity and lease quotas. Loaded checks make
no allocator calls. Every commit invalidates old operations. Uncertain outcomes
fence them until receipt recovery resolves the write.

[ADR-0168](../decisions/adr/ADR-0168-durable-managed-capability-bindings.md) defines
the restoration contract. These are Zig admission primitives. Bind a use
check to its content effect at the same revision, or use the managed hosting
adapter below. Controls also expose copied attenuation, independent revocation
and scoped inspection through the [management methods](#managing-a-held-control).
Powers are immutable. Narrowing creates a dependent control descriptor. Grant
lifecycle and terms remain editable.

## Managed endpoints on the Host

`access.hosting.Service` borrows Capabilities and a table of `ContentBehavior`
descriptors. Add every entry from its `behaviors()` array to the
`hosting.Attachment` behavior table. The Service, Capabilities, and behavior
tables must stay at stable addresses until `Attachment.destroy` succeeds. A
Busy teardown retains pending work, so every borrowed application context must
stay alive, and outer attachment behavior descriptors stay immutable during
that lifetime. The Service creates no Host, Vat, worker, or storage queue.

The trusted embedding prepares a current owner Read, including its bounded
`prepareIdentities(count)` paths, before calling `stageEndpoint(read, ...)` in a
Store batch. Load the committed descriptor before opening that batch. A use endpoint
retains its exact use descriptor and binds one resource identity to one content
record. A control endpoint retains only its exact control descriptor. This
binding is application authority, so the embedding must associate the right
resource with the right content. The recipient receives a hosted capability,
and method arguments cannot replace that binding. Derivation updates the
endpoint's receipt window while preserving its authority and content binding.
After commit, restore the endpoint from a checked
lease. `stagePublication(store, endpoint_lease, entropy)` atomically binds its
one durable publication recipe. Restore that recipe after commit. Local
capability edges use the ordinary Attachment capture seam. Descriptors and
endpoints register weak owner membership in their creation transaction.

For use calls, preparation loads the descriptor, content, and current managed
records. The content schema selects one `ContentBehavior` by value for the
retained preparation. Its borrowed `context` is passed to requirement, retry, resource,
reference, dependent-requirement and invocation callbacks. Service decoders
receive the separate `Service.context`, and entropy has its own callback and
context pair. Selection and sharing entropy bindings survive storage waits.
Replacing `Service.contents` or `Service.entropy` affects future preparations
and revision restarts, and old contexts and returned borrows stay valid through
settlement. Other Service configuration stays stable while calls are pending.

The pure `requirement` callback declares permissions and all relevant committed
facts. `ContentInvocation` pairs the selected content with canonical resource identity,
kind, object and owner resource revision. Local dependent calls describe the
selected target. Forwarding describes only its mediating source. One inline
snapshot survives storage waits and is rebuilt on Store revision restart
([callback context](../decisions/adr/ADR-0198-trusted-content-callback-context.md)).
These snapshots charge existing bounded call bytes without a new allocation,
lease or payload copy. Declaration can load the admission row even when it
refuses, and per-call quotas admit these bytes or refuse preparation. Only
after the bound grant admits that requirement does `invoke` run on the Vat.
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
The attachment commits that content row before settling the reply. Application
callbacks are trusted, deterministic Zig code with no external effects, and the
API is not a machine-code sandbox.

Control endpoints accept `pause`, `resume`, and `revoke` with no arguments.
Replies are Boolean: true for a committed change and false for an unchanged
request. A revoke writes one descriptor, and every later use checks it, so it
takes effect at once and costs the same however far the grant was shared.
Publications in the revoked branch keep resolving, and calls through them fail
as revoked, until [bounded owner cleanup](#bounded-owner-cleanup) retires them.

An optional `decode_control` callback maps application methods to
`core.Control.Edit`, including policy edits. It only decodes requests, and the
stored control powers and shared model rules decide whether they are permitted.
The decoder runs after control reads and receives loaded `Control.Powers`. Its
policy ceiling supplies scope for application policy edits, and returned terms
may borrow that scope until settlement. Authority admission stays with the
shared operation, including idempotent repeated revocation. A changed edit
stages the grant, owner revision, and retained change batch in the attachment's
transaction. Direct lifecycle edits are idempotent, and the receipt wrapper
below recovers the first result after a lost reply. Held
[receive capabilities](#observing-held-access) project scoped changes through
ordinary CapTP calls.

Preparation and its leases belong to the retained call. Any intervening Store
commit restarts preparation, including calls already queued for invocation.
Outstanding reads retire through exact completion before their buffers or
operation state are released. Unknown writes keep the recovery fence, and no
affected call replies successfully until recovery resolves it. Resident near
calls return `DurableTurnRequired` for managed endpoints. Use eventual sends.

Budget the endpoint and content leases in addition to the managed operation's
descriptor, header, model records, and transient directory page. `record_capacity`
bounds the model working set. Capabilities quotas bound concurrently allocated
operations. These allocations are additional to the attachment's retained-call
arena and share the Store's cache and lease limits. Settled calls release all
operation custody. Content and authority rows remain eligible for ordinary LRU
eviction. Sleeping references retain reachability without pinning those rows.

The `hosting.Behavior.prepare` seam emits read work through the same
attachment, and `Call.transaction` stages a trusted participant in its batch.
Participants only stage mutations, and the attachment begins and commits. Managed hosting
uses these seams for content, structural, control, and derivation calls.
[Reference recipes](references.md) restore held local and foreign authority.
[Scoped observation](#observing-held-access) uses the same preparation and
transaction owners.
[ADR-0169](../decisions/adr/ADR-0169-managed-host-turns.md) records the contract.

## Retrying mutations

Every content method supplies a pure `ContentBehavior.retry` classification:
`read_only`, `idempotent`, or `receipt`. A read cannot stage an effect.
Receipt-backed methods require `mutate(sequence, method, arguments...)`. A
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
the attachment transaction, and unknown writes keep the recovery fence. These
receipts recover bounded local results and do not promise exactly-once remote
delivery or persistence of external effects.

Receipt values allow 32 KiB each, nesting depth 64 and at most 64 distinct
capability leaves across request and result. Combined encoded receipts fit
64 KiB. Binding storage grows only for capabilities. Scalar calls fit the
workload's 4 KiB call arena. Encoding measures before allocation.
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
existing scope-selection limit. Every new operation checks current dependencies.
Retained references and receipts do not bypass independent control revocation.
Grant policy and lifecycle still follow shared grant ancestry. A paused grant's
control may resume its own grant. A revoked ancestor cannot regain use access.
Repeating a control's own terminal revocation is harmless.

Hosted controls accept `describe-control()`, `revoke-control()`, and
`mutate(sequence, "attenuate-control", application arguments...)` when the
Service supplies `decode_attenuation`. The decoder receives loaded held powers
and supplies requested powers.
Shared rules decide admission. An active `access:control` description contains
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
with their immutable policy vocabulary. Drive missing reads as for `require`.
Stale operations and uncertain writes refuse. Hosted preparation retries stale
snapshots before invocation. Description loads authority records and leaves
application content asleep. Encoding and reply copies share the bounded call
arena. Larger vocabularies need sufficient call and frame capacity.
The maximum-policy test exercises all 64 permissions and 16 constraints across
the three policies within the default 64 KiB call arena. Frame capacity is a
separate limit, and the test measures no throughput.

## Observing held access

The [observation guide](access-observation.md) owns registration, scoped cursors,
receiver/canceller custody, restart and the independent runtime budgets.

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
| `durable-name()` | The endpoint's durable Swiss name, or `NotPublished` when it has no publication recipe. This is the secret publication component. The existing Host locator APIs supply peer routing. |

These methods check current use authority. `derive` returns use alone.
`derive-managed` decodes a `Service.ManagedIssue` containing grant terms and
control powers, and returns both to the issuer. Its policy ceiling must fit
the child grant. The use endpoint cannot recover its control. Recovery requires
the issuing source and exact intent. Publish a control separately if it needs
its own durable locator. Zig `prepareManagedDeriveCopying` and
`Capabilities.stage` expose the same atomic use and control issuance. An
initially paused child is minted paused. Exact disclosures preserve a stored
field's saved authority, and this API does not attenuate other
capability-valued application replies.

The child grant, use descriptor, optional control descriptor and endpoint,
rooted use publication, retry receipt, and source sequence update commit in one
Store batch. `Call.result` runs at the top-level Host boundary after Vat staging
and before write submission. It reserves the child actor and a hidden
publication through `Host.reserveDurableCapability`. No fetch can discover that
reservation. `Call.confirmation` activates it without allocation after confirmed
commit and before reply projection. Abort releases the reservation. An unknown
write retains it until recovery. Publication reservations must be moved, then
committed or canceled before Host teardown.

The source retains its last **eight** receipts, indexed directly by sequence
through ordered strong edges. A matching retained request returns the same
child. Changed decoded terms yield `OperationConflict`. An older sequence yields
`ReceiptExpired`, and a future sequence yields `OperationOutOfOrder`. Expiry
does not make an old sequence eligible to mint again. All holders of one
endpoint share the sequence domain and must coordinate competing new requests.
Retries also check the source and child at the current revision, so replay
cannot bypass pause or revocation. Other mutations use the separate mutation
window described above.

Receipt eviction drops its source edge, allowing ordinary collection. It does
not retire the child's rooted publication, so applications retire publications
when durable discovery should end. Terminal managed identities and indexed
grant payloads can be retired through
[bounded owner cleanup](#bounded-owner-cleanup).
On startup, enable `publication.listen` for on-demand discovery of these
descriptors. A retained retry can also restore its exact child and publication
after reopen.

Endpoint format version 1 reserves nineteen edges: descriptor, optional content,
optional publication, and eight receipts in each sequence domain. A derivation
receipt permits 32 KiB of canonical intent and two edges, or three when it
retains issuer control. Intent encoding and sharing state use the bounded call
arena. Replay holds three additional record leases and a child operation while
checking authority. Managed replay additionally holds its control endpoint and a
bounded control operation. Issuance uses the Zig Append budget. Actor and
publication allocation happens before submission and may refuse under pressure.
None of these costs apply to unmanaged actors.
[ADR-0170](../decisions/adr/ADR-0170-durable-facet-derivation.md) owns this
contract.

## Bounded owner cleanup

A trusted embedding may restore an owner record through the Service's owner
behavior. That capability administers the owner. Use and grant-control
capabilities cannot produce it. `sweep(sequence)` starts terminal cleanup while
preserving active authority. `retire-owner(sequence)` closes ordinary admission
before cleanup starts. `maintenance-step(sequence)` advances one prepared unit.
The tagged `access:maintenance` reply carries the next sequence, phase, retired
flag and replay flag. Start at zero. Retry the last acknowledged request with its
original sequence. The immediately previous matching command returns its recorded
progress without another effect. Older, conflicting and future requests refuse.

Zig embeddings use opaque `storage.Maintenance` operations with the same
commands and sequence. Drive their read requests before opening a Store batch,
then stage and commit through the owning executor. Operations bind one Store
revision. Abort, uncertain outcomes and intervening commits require a fresh
preparation. Submitted reads retain exact ticket and buffer custody through
cancellation and completion. `deinit` refuses outstanding reads.

Cleanup visits the bounded observation index, weak identity directory, grants
and resources. Each indexed step seeks one sparse four-level path and checks
one bounded authority path. A step does not scan unrelated owners. Revoked
management dependencies, revoked grant branches and deleted content targets
retire their affected identities. Grant pruning decreases a surviving parent's
child count and journals its scoped inventory change. Empty directories retain
their allocation high-water marks. New capabilities register in their creation
transaction. Weak inventory leaves preserve ordinary collection lifetimes.

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
requires that owning retirement callback. It refuses before effects if none is
provided. The managed publication factory binds the recipe to its endpoint so
cleanup can find it. A generic publication created outside that managed factory
belongs to its embedding's explicit retirement protocol.

Physical collection remains Loam tracing. It protects runtime retains, stored
strong references and pinned historical edges, and reclaims disconnected pages
and payloads after their custody ends. Durable names keep their immutable index
reservation: 25 key bytes plus 33 object-identity bytes, **58 logical bytes per
name**, before backend overhead. Retirement does not shrink the LMDB file.
Compaction is a separate maintenance contract. Mint preparation reserves at most
four identity paths. Ordinary access reads allocate none of those paths.

[ADR-0180](../decisions/adr/ADR-0180-bounded-managed-retirement.md),
[Zig cleanup tests](../../test/loam/access/maintenance_test.zig),
[LMDB/reopen tests](../../test/loam/lmdb/maintenance_test.zig), and the
[managed process proof](../../test/loam_managed_crash.zig) own these guarantees.

## C and Rust resources

The [C/Rust lifecycle guide](c-and-rust.md) owns the language projection,
worker retirement, startup and shutdown contract.
