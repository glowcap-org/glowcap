# Managed access integration with Loam storage

This page specifies the storage and working-set contract managed access needs
from [Loam](architecture.md). It lists consumer requirements and adds no second
storage implementation. The APIs, storage adapters, and budgets below are
proposed unless they are named as existing.
[ADR-0157](../decisions/adr/ADR-0157-access-storage-and-residency.md) records
the decision, and the [access architecture](access-architecture.md) lists the
decision record behind each implemented piece.

These pieces exist and have their own guides:

- [Resource moves, deletion, and children](access.md#resource-moves-deletion-and-children):
  Zig query ownership, hosted structural effects, and scoped observation
- [Observing held access](access.md#observing-held-access): the exact-context
  profile and capacity budgets
- [Bounded owner cleanup](access.md#bounded-owner-cleanup): terminal payload
  reclamation, index pruning, and publication retirement
- [Held-authority reference recipes](references.md): local and foreign
  restoration
- [LMDB maintenance](lmdb.md): map growth, inspection, and offline compaction

The [Loam API](api.md) owns shared leases, transaction phases, and backend
outcomes. The [coverage page](coverage.md) records integration evidence.

## Decisions

Managed access owns resource and access records, admission, and the authority
consequences of transaction and recovery outcomes. Loam owns shared record
residency and atomic commitment below managed access, and its integration with
the Vat and Host coordinates activation and durable execution. The synchronous
cores request storage work as explicit effects, and adapters perform I/O
through the embedding's executor. The
[Loam architecture](architecture.md#product-and-ownership) owns that boundary,
and the [actor contract](actors.md) owns activation and eviction. A custom
physical engine needs comparative evidence.

Use the implemented LMDB adapter for LMDB workload and application integration,
and the [IndexedDB profile](browser.md) for the browser. Compare another engine
when measurements warrant it. Content and managed access records that
participate in one operation share one backend transaction. A volatile adapter
serves local ephemeral applications and runs the same semantic test suite.
Backend selection is explicit, so a failure to open durable storage does not
fall back to the volatile adapter.

Durable state grows independently of resident resources, callable endpoints,
and connections. A reference retains owner custody and stable identity, not
the resource graph, ancestor chain, or message history. Holding an inactive
durable publication does not require a resident actor.

The graph and ledger reserve their whole record capacity in memory. That
representation stays out of any ABI so it can be replaced without keeping
parallel authority algorithms.

## Capability database contract

Managed access supplies resource and grant semantics to an application's
durable object graph. Loam preserves content, references, and managed access
records in the same transaction. The resulting surface behaves as a capability
database, and managed access is not the generic storage engine.

The database's usable objects are capabilities. A held resource reference
permits its supported operations under current authority. A stored reference is
a first-class value whose source authority can be restored. An internal row
key, index entry, or SQL connection is an implementation detail. The ordinary
consumer surface exposes resource operations and scoped queries. The trusted
embedding that owns a backend has custody of its stored authority, so managed
access does not isolate an application from its own database administrator.

The contract has six observable properties:

1. Content and its authority-bearing references commit at the same revision.
2. Saving, copying, loading, and passing a reference preserve its source
   authority. A new editable grant appears only through explicit issuance.
3. Restored controls preserve their own powers and dependencies, including
   changes made after publication. A target's existence cannot restore broader
   management authority than the stored control held.
4. Queries and returned references obey the capability through which the caller
   reached them. Counts, ordering metadata, cursors, and errors do not create an
   unrestricted path to the owner's inventory.
5. Eviction changes residency. Deletion, revocation, and publication retirement
   change durable state through their own operations and remain effective after
   recovery and compaction.
6. The backend stores records. One shared Zig implementation decides authority,
   including when data is loaded late, a write is uncertain, or a call resumes.

### References embedded in application content

A conversation entry, attachment, saved invitation, or application-specific
object field can contain a capability. Opaque application bytes cannot tell
managed access which references must survive, which authority they carry, or
when they may be reclaimed. The content participant therefore declares its
capability-bearing fields in the same transaction as its payload changes.

The illustrative operation `tx.store_ref(held_capability)` registers the local
restoration recipe or already-established foreign sturdyref and returns a typed
stored-reference value for that content field. It consumes or retains the
capability through the Host surface and is not a public constructor from
resource and grant IDs. Typed bindings use this mechanism when encoding
capability fields instead of serializing their runtime handle bytes. Loading
such a field reconstructs the reference under the field's declared return
policy. Copying it does not mint an independent grant.

The reference index records the containing resource and field, source
authority, projection, and dependencies. Payload and reference-index updates
are one transaction. Removing or replacing a field releases its durable
retention edge only on commit. A live-only capability can be retained in
volatile content. A durable field refuses it unless the source supports saving
that authority. Obtaining a foreign durable reference may require a separate
remote call before the local transaction, and never an invented foreign record
ID.

Applications declare whether a method hands over saved authority or keeps the
invoking endpoint as an additional dependency.
`ContentCall.discloseExact` implements direct handoff of a prepared strong
edge under [ADR-0172](../decisions/adr/ADR-0172-explicit-disclosure-of-returned-capabilities.md).
`ContentCall.discloseDependent` returns a runtime facet whose target method
must pass both current grants under
[ADR-0173](../decisions/adr/ADR-0173-dependent-returned-capabilities-and-reference-edits.md).
`replaceReference` and `removeReference` update prepared strong fields in the
content transaction. The [implemented reference guide](references.md) owns
local dependencies, checked foreign saves, and restoration preparation. The
storage codec cannot choose or widen a disclosure mode.

### Queries and consistency

Public queries start from a held collection or resource capability and use a
bounded, typed query surface: selection, order, page size, and cursor. Backend
SQL or IndexedDB indexes supply candidates. Managed access evaluates the
relevant scope and application-declared requirements before disclosing each
result or returned reference. A raw total count or unfiltered index cursor
cannot reveal hidden siblings, and application search indexes have the same
disclosure obligations.

The first consistency model is one committed owner revision per operation.
Content facts and authority come from that revision, and record batches from
different revisions are never assembled into an admission. A deferred read
rechecks current authority before release. A paginated query can restart or
report conflict after changes. It does not retain an old snapshot or disclose
data under authority that has since been revoked.

Durable commit determines recovery. Serialized owner installation advances the
revision visible to calls before mutation completion is returned. Reads
overlapping a pending write may use the last installed committed revision. A
cold read that sees a newer backend revision waits for installation or recovery
instead of exposing part of the pending write. Completed reads and delivered
bytes cannot be retracted.

Atomicity stops at the owner transaction boundary. Remote calls, email, and
other external effects cannot be rolled back with the local store. An
application that needs a durable external action records its intent in the same
transaction and executes it afterward under the receiving interface's retry
contract. Managed access must not advertise exactly-once remote effects or
distributed transactions on the strength of local receipts.

## Ownership and reuse

| Concern | Owner and reuse |
| --- | --- |
| Grant evaluation, scope, lifecycle, preparation, authority consequences of recovery | managed access core, retaining one Zig implementation for Zig and binding consumers. |
| Shared record residency, storage leases, and byte accounting | Loam core, shared with ordinary records and actor persistence. |
| Grant evaluation scratch and resource-specific limits | managed access core with explicit allocation and bounded operations, using shared storage leases. |
| Record encoding and storage integration | `access/records` encodes owners, directories, resources, grants, and events using Syrup. `access/storage` binds model views and staging to Loam, which owns generic records and backend effects. |
| LMDB execution | Optional LMDB adapter. The embedding runs it on its existing blocking-work executor. Backend comparison is conditional on measured constraints. |
| Browser database execution | The optional Rust IndexedDB executor applies shared persistence batches. No browser-specific grant evaluator. Rooms adoption follows its integration plan. |
| Calls, promises, reference custody, active publications | Existing actors, Vat, Host, and their supported public integration APIs. |
| Network I/O and reachability | Existing driver and transports. Database work does not pass through network transports. |
| Content schemas, application indexes, blobs | Application-owned records participating in the backend transaction. Content remains opaque to the access module's authority evaluator. |

The storage codec imports only the lower layers needed to encode records. The
storage backend may depend on its selected database library and is an optional
I/O boundary outside `access/core`. Core-only and browser builds do not link
the LMDB database. Adding these modules requires updating the build's
dependency inventory and architecture checks together. The portable
`loam_access_records` and `loam_access_storage` modules and the optional
blocking LMDB backend are implemented. The companion C archive must keep
optional backend symbols separable so ordinary managed access users need no
database dependency.

The [document worker](../../apps/rooms/rust/services/src/documents.rs) retains
blocking work until completion even if its observer cancels. The
[browser transaction owner](../../apps/rooms/rust/browser/src/storage/transaction.rs)
retains callbacks until terminal transaction events. Reuse those execution and
retirement patterns. Their document and archive formats do not provide the new
atomic owner store.

The Host is not a general database executor. A Zig embedding supplies its
work-execution boundary, and a Rust embedding can use its existing executor.
Workers receive immutable operation inputs and return completions. They do not
mutate a live managed access owner or call into the Host from their thread.

## Durable records and indexes

An owner is an authority and transaction boundary, not necessarily a database
file. One database can contain several owners. Loam admits one prepared write
per persistence domain, with one writer registration per participating owner.
Owners in one SQLite file or LMDB environment still share the physical writer
limit of that engine. Cross-owner content transfer is an explicit capability
operation, and sharing a database grants no cross-owner atomic administration.

| Record family | Durable fields and required lookup |
| --- | --- |
| Owner | Stable owner ID, format/schema identities, monotonic commit revision, allocation high-water marks, writer fencing generation, and receipt/event retention floors. Primary lookup by owner. |
| Resource | Stable ID and generation, kind, lifecycle, canonical parent, content revision and content key. Index children by owner, parent, and stable ordering key. |
| Content | Application records and authority-relevant facts at the resource's committed content revision. Application indexes participate in the same transaction. |
| Content reference | Containing resource/field, exact stored capability recipe, projection, and retention edges. Index outgoing references and incoming durable dependencies. |
| Use grant | Grant ID, selected target/scope, issuance ceiling, configured terms, status, parent/dependencies, delegation bounds, and revision. Index immediate children by parent grant. |
| Grant control | Stable control identity, target grant or explicitly supported management scope, management ceiling, permitted operations, lifecycle, and dependencies. Use authority is not recovered from a control unless explicitly granted. |
| Publication | Existing Host durable publication identity, exact original/use/control restoration recipe, target generation, and dependencies. Point lookup by publication identity. No resource-ID-to-original shortcut. |
| Held dependency | Exact local capability recipe or retained foreign sturdyref, source owner, lifetime and dependency role. Index dependents for bounded cleanup. |
| Operation receipt | Owner and operation identity, source capability identity, intent digest, committed revision, result/publication identities, and retirement epoch. Unique operation lookup. |
| Change event | Owner-local sequence, commit revision, event kind, and affected resource/grant branch. Ordered retention index. Delivery still checks observer authority. |
| Retirement metadata | Non-reusable identity high-water marks, dead generations and publication retirement information needed to refuse obsolete access after compaction. |

The table lists the full set of records. The implemented profile stores owner,
resource, grant, and bounded change-batch records in ordinary Loam records.
Four-level sparse radix directories map resource and grant slots to Loam object
references. The owner header retains directory roots and persists the full
policy descriptor. Strong record edges make retention visible to Loam's
collector. Both volatile and LMDB backends execute this profile.

The directories add bounded logical lookups above the physical engine's index.
Measure that cost before adding an engine-specific secondary index. Child
listing and scoped queries need transactional projections of canonical records,
and an index cannot authorize a result without current record evaluation.

Managed access owns a versioned record codec with field names, bounds, and
schema identities. It reuses Syrup encoding without copying CapTP session
records into storage. The owner persists stable permission and constraint keys
and operators, and grant masks refer to that immutable descriptor. Process
pointers, struct layouts, and runtime type names have no durable meaning.
Decoders check lengths and canonical ordering before allocating. An unknown
required schema or format version refuses opening. Prerelease replacement never
resets an existing store or accepts an old format through a second policy path.

Publication secrets and retained foreign sturdyrefs are bearer authority.
Their storage, backups, and diagnostic redaction follow the embedding's secret
custody, and exporting resource metadata must not export those records.
Encryption and backup keys belong to the deployment and storage adapter. An
opaque on-disk encoding does not protect authority by itself.

Application content is not copied wholesale into Zig. A prepared operation owns
a bounded content batch or a retained backend-specific content participant.
That participant executes on the same transaction or connection as the managed
access batch, under an expected content revision. It may encode domain data but
cannot supply a replacement grant evaluator or commit its half independently.

## Backend transaction contract

The [Loam transaction API](api.md#atomic-mutations) and
[adapter contract](api.md#adapter-effects-and-failure) own batches, tickets,
completion outcomes, and recovery. Managed access supplies the following data
to those shared operations:

| Shared operation | Managed access participation |
| --- | --- |
| Bounded record read | Owner identity, generation, required revision, and resource/grant keys or ranges. |
| Atomic prepared batch | Resource and grant deltas, content participants, publication recipes, receipt, and authorized event intentions. |
| Recovery | Exact operation identity and intent bound to the owner, plus validation of restored resource authority. |

The access API reports an indeterminate shared commit as `OutcomeUnknown` or
`RecoveryRequired`. It submits no other write to settle the uncertainty.

One backend transaction compares owner, writer, and content revisions and
writes content, resource relationships, grants, controls, publications,
indexes, receipt, and events. It advances the owner revision once. An operation
stores only its delta, and neither preparation nor commit clones an owner's
graph or content. The adapter maps one prepared decision to one atomic commit
and infers no new decisions from storage errors.

Unknown outcomes fence protected access for that owner. Recovery first retires
or joins the old write, then queries its receipt from an authoritative backend
view. A receipt with a different intent is a conflict, not a retry. Known
absence can mean unchanged only after proving the old writer cannot later
commit. After a process restart, reload committed metadata and affected rows
before reopening admission. A worker timeout or abandoned future does not prove
abort.

Managed access uses Loam's [receipt retirement contract](api.md#atomic-mutations).
An operation epoch belongs to the issuer's capability context. Receipt lookup
and replay recheck current authority and cannot resurrect a revoked publication
or disclose an otherwise inaccessible result.

### Storage candidates

Loam owns the backend implementations, and the research plan owns comparative
selection and physical layouts. An LMDB profile must bound map and reader
lifetimes, coordinate resizing, use durable commit settings, and materialize
any data that must outlive a transaction. Cold mapped reads can block on page
faults, so they run off the Host turn. Graph records and indexes commit in one
environment transaction. The SQLite profile below defines a comparison if
measurements warrant that experiment.

### Optional SQLite comparison

Use one database transaction for the owner mutation, including application
content. Default the persistent profile to WAL with `synchronous=FULL` and
verify the effective settings when opening. Keep database operations off the
Host turn, and run checkpoints through the existing executor with byte and time
budgets. Record WAL growth, busy time, checkpoint latency, and outstanding read
age. SQLite documents concurrent readers with a single writer in
[WAL mode](https://www.sqlite.org/wal.html), and the durability distinction in
[its synchronous setting](https://www.sqlite.org/pragma.html#pragma_synchronous).
These settings define the comparison profile and are not a measured managed
access result.

Bound connection counts, queued writes, read duration, and the database page
cache. Do not open a connection or start a task per resource or per capability.
Use bounded lock waits and typed busy outcomes. A lease and fencing generation
in owner state prevents an obsolete registration from committing after a newer
writer takes custody. Hold an exclusive lifetime lock through worker
retirement. Do not steal custody from a running owner by expiring a timer.
Generation checks fence writes but do not alone stop a former owner serving
cached reads, and database locking is not a replication protocol.

### Browser IndexedDB

Place all participating owner records and content stores in one IndexedDB
database and one readwrite transaction. Separate localStorage checkpoints or
independent archive transactions cannot commit half of the operation. Prepare
inputs before starting the transaction, issue dependent requests during active
request callbacks, and report commit only on the transaction's completion
event. The [IndexedDB specification](https://www.w3.org/TR/IndexedDB/#transaction-lifecycle)
defines that activity window. Do not hold a transaction across a network await
or user interaction.

Request strict durability for authority writes and report the backend's
supported durability profile. Browser-managed retention and eviction remain
limitations, and a durability hint is not permanent custody. Failure or quota
exhaustion refuses publication instead of using memory. Multi-tab hosting must
hold an exclusive owner Web Lock without stealing it, and fence stale commits
with an atomic owner-generation comparison.
[Web Locks](https://www.w3.org/TR/web-locks/) provides the storage-bucket-scoped
custody primitive. Without it, this multi-tab durable hosting profile refuses.
A timeout lease would let a suspended tab resume serving stale cached
authority. Origin storage access is trusted embedding access and does not
isolate hostile scripts from each other.

## Large content and blobs

Store small content records with their metadata transaction. Large files use
immutable blobs and a committed manifest. Stage bounded chunks outside the
owner write reservation, verify and durably finish the blob, then atomically
commit its manifest reference with the content and access change. The
committed manifest never points at an unfinished blob. Failure before manifest
commit can leave an orphan to reclaim but no published dangling content. A
backend that cannot establish that ordering keeps blobs in its transactional
store or refuses the durable operation.

Reading a blob streams bounded chunks under current access, rechecking before
each chunk released after an asynchronous wait. Delivered bytes cannot be
recalled. Do not copy the file into a frame, owner snapshot, or Wasm bridge
buffer. Shared immutable blob data uses explicit pins. Publishing a digest
never grants permission to fetch its bytes.

## Resident records and page faults

A shared, synchronous record-view interface replaces direct array-only
dependencies. The same Zig scope, delegation, and transaction algorithms
consume this view in resident and persistent modes. Lookup returns a validated
record, a known absence, or a typed request for missing records. Storage
adapters provide records and revisions, never answers such as "is ancestor" or
"allowed." An unloaded record is not a missing resource and must not produce
`Gone`.

A cold operation retains a bounded continuation containing its held capability,
requirements, target identities, requested keys, and expected revisions. It
returns a read effect to the embedding. The completion carries owner
generation, request identity, and snapshot revision, and stale or mismatched
completions are discarded. The operation resumes against current state with a
bounded restart budget. Negative lookups are revision-scoped too. A foreign
reference remains a retained capability dependency, and loading a foreign grant
row cannot replace invoking it.

Grant ancestry and relevant resource ancestry load in bounded batches. The
configured depth and selection limits bound admission's working set, and no
admission pins an entire subtree to check membership. Selected scopes keep the
current semantics for stale members, even when that requires validating more
than the requested target. Traversal starts explicit and bounded. Add indexes
or memoization only with equivalence and invalidation tests.

Pins belong to active operations, not every live endpoint. Cache entries hold
immutable record versions, and endpoints retain identities and owner leases. A
mutation installs its changed records and invalidates derived access decisions
before returning its event. Since the owner is the exclusive writer, unchanged
cached rows stay valid across a known complete local delta. Whole-decision
caches are keyed by the owner authority revision. Reads completing from an
older backend snapshot cannot overwrite newer resident records.

Pinned and dirty or prepared bytes have separate limits from evictable cache
bytes. Admission reserves its bounded working set before taking the mutation
slot. If it cannot fit, it returns pressure without starting an unfinishable
transaction. Eviction releases only unpinned, clean rows. It does not revoke a
capability, destroy content, or require a durable write. Opening an owner
allocates nothing for the total capacity of a large cold store.

Canonical containment stores parent edges. Depth is derived or a validated
index value, so a move rewrites no descendant. Cycle and maximum-depth
validation stay in Zig. A large subtree move uses bounded, resumable preflight
over a consistent owner revision to establish subtree height and audience
effects, followed by a revision-checked commit. Continuation state is bounded.
Elapsed-work limits may refuse an oversized move before mutation, and revision
drift restarts or conflicts. A partly validated move never commits.

## Buffer and completion ownership

| Value | Lifetime and release owner |
| --- | --- |
| Synchronous arguments and content facts | Borrowed for the owning turn only. An asynchronous operation must retain or copy its bounded inputs before returning. |
| Backend read buffers | Owned by the read completion until transferred into validated cache storage or discarded. Decoding cannot retain a released database cursor's memory. |
| Record pins and operation scratch | Owned by one active managed access operation until settlement, cancellation completion, or recovery transfers custody. |
| Prepared mutation and content participant | Retained through the real write outcome, including uncertainty. Caller cancellation cannot free them underneath storage. |
| Host capabilities and answer completion | Retained/released by existing Host custody. Workers carry operation tickets rather than thread-unsafe live owner pointers. |
| Completed return buffers | Explicit transfer or bounded borrow through the existing Zig/FFI conventions, with one release owner. |

SQLite row data and browser database values can require bounded materialization
before their backend callback ends. Name and measure that copy at the adapter,
claim no zero-copy storage, and hide no copy in a language binding. Coalesced
reads share immutable buffers only while explicit pins keep them live. Owner
shutdown stops admission, retires or joins effects, then releases pins and
buffers. Stale completion tickets refuse without touching freed state.

## Calling patterns

Consumer APIs remain capability calls. Holding the invoked reference supplies
its authority, and the local and remote entry points feed the same managed
access operation. No caller supplies an additional grant credential or drives
a cache. A full application binding returns an immediate result or its
language's usual future or promise. The lower-level embedding API exposes
effects explicitly.

| Call | Execution and cost contract |
| --- | --- |
| Warm scalar read | Check current authority and borrow resident content facts in the same owning turn. No managed access heap allocation, storage operation, durable receipt, or extra queue hop. Reply encoding may have its existing transport cost. |
| Cold read | Retain one bounded operation. Batch missing records through storage. Resume on the owning executor and recheck authority before disclosing content. |
| Mutation | Load facts, prepare one bounded delta, reserve memory/publication capacity, run one backend commit, install synchronously without allocation, then emit events and settle. |
| Share existing authority | Retain/pass the exact existing capability through Host custody. No new grant or storage write unless new durability/publication is explicitly requested. |
| Issue a durable facet | Commit grant, optional control, publication recipe and receipt together. Return the exact publication after commit. |
| Long read or listing | Use bounded chunks/pages and recheck current authority on each delivery. Release database snapshots between pages. An access-scoped cursor may report conflict after reorganization. |
| Remote dependency | Use existing send/forward/deferred-answer operations. Never hold a local database transaction while waiting on the network or report a remote timeout as revocation success. |

Local hosted calls use the near-call and eventual-send mechanisms. A warm
operation may finish in its turn. An operation needing storage defers through
the Host answer mechanism. Direct non-hosted Zig calls use the same core and
storage effect contract without dialing a dummy session. Blocking convenience
APIs, if exposed, are named as such and forbidden on the Host execution thread.
No synchronous core lookup hides an I/O wait.

Clients may use CapTP promise pipelining for deferred results. A
capability-producing promise resolves only after its authority is committed and
installed, so pipelined calls cannot invoke a proposed grant early. Host and
promise queue limits apply alongside managed access pending-call budgets.
Managed access adds no second pipeline or per-grant progress loop. Bounded
multi-resource commands can share one owner transaction when the application
declares their combined authority and all-or-nothing effect. Independently
acknowledged operations are never batched under weaker durability.

A content handler supplies operation requirements and facts, prepares opaque
content changes, and receives admission bound to that effect and revisions. It
must not run a reusable `require` check, await arbitrary work, then mutate
content without another admission. Returned capabilities are checked or wrapped
before disclosure, including after deferred content reads and event delivery.

Once a durable commit has completed, the accepted mutation has happened even if
its caller disconnected. Reply delivery and event fanout can fail without
undoing it, and retained receipts allow recovery. Cancellation before storage
starts can discard preparation. Cancellation during storage retires the
observer and joins the operation before state is released.

## Publication and restoration

Durable publication uses the Host's publication identity and capability
custody. Store the authority recipe, including control ceilings and lifecycle,
instead of serializing a process-local opaque pointer. Restoring a control must
not construct an unrestricted controller from its target grant. Original
publications retain original authority, and facet publications retain their
grant dependency. Deployment custody and backup must preserve the peer and
restorer identity that existing locators need.

Opening an owner loads its header, schemas, recovery metadata, and requested
working set. A durable publication resolves by indexed lookup and loads only
its needed resource, grant, and control records. Startup neither enumerates
every stored publication nor spawns every actor. The active publication
registry remains Host-owned, and the access module's store owns the restoration
recipes.

Two integration requirements must be proven against the Host API: reserve an
endpoint or publication's installation capacity before committing issuance, and
defer a cold durable lookup while its recipe is loaded. If current public APIs
cannot do either, extend the owning Host publication or answer seam. Managed
access implements no second export table or publication server.
[ADR-0176](../decisions/adr/ADR-0176-on-demand-durable-publication-discovery.md)
records the on-demand discovery that implements these reservations.

A crash after commit but before publication installation leaves a restorable
recipe and receipt. Retry installs or returns that publication and mints no new
grant. Installation failure keeps the committed result recoverable and reports
its state accurately. Network transmission can fail. The local post-commit
state transition is allocation-free and non-reentrant.

Restore validates records lazily at their bounded trust boundary and checks
referential consistency on use. Missing required grant ancestors, unavailable
foreign dependencies, or malformed control definitions refuse access. An
operator consistency scan can validate the full store incrementally, so a
normal open never scans the whole store.

## Reclamation and backup

Live reference release, cache eviction, content deletion, grant revocation,
publication removal, and owner retirement are distinct operations. Durable
roots include application-owned content roots, active publications, retained
capability dependencies, and recoverable operations. A live operation's pins
also prevent reclamation of its records and buffers.

Start with explicit deletion and bounded maintenance, not distributed garbage
collection. Revoke or retire authority transactionally, then reclaim payloads
when no durable dependency or active pin needs them. Reference counting cannot
collect cyclic content links, so periodic bounded tracing or explicit owner
deletion determines their durable reachability. Remote peers holding a
sturdyref do not report their last release, so an active publication remains a
root until its owner retires it.

Compact terminal grants and removed publications into dead-identity metadata.
Never reuse an old grant, control, or publication identity, reinterpret an old
slot after generation reset, or expire a receipt into permission to reissue. A
missing compacted ancestor refuses, and surviving dependents cannot become
independent roots. Benchmark reclamation and retired-ID storage under
sustained issue and revoke churn as well as a live-record steady state.

A backup contains a consistent owner revision, blobs reachable from its
manifest, publication and restorer custody, schemas, and retirement and receipt
floors. Use the selected engine's consistent backup facility, such as SQLite's
[backup API](https://www.sqlite.org/backup.html), and never copy a live
database file without its transaction state. Pin reachable blobs while backing
up, and serialize backup and reclamation decisions through the same owner
revision contract.

Restoring an older backup under the same public identity can undo later
revocations. Same-identity recovery therefore requires a complete authoritative
recovery history, including committed revisions that may already have been
exposed, and it cannot roll behind acknowledged changes. If that completeness
cannot be established, restore as a new owner and publication identity and
reshare. A database snapshot alone gives no rollback-resistant revocation.

## Performance contract and measurements

Measure the access module's incremental cost separately from database caches,
application content, actor objects, transport buffers, and page cache, and
count all of them in end-to-end resident-memory results. An ordinary
non-managed actor pays zero managed access allocation and retains no managed
access state.

Use a per-owner memory budget with sublimits for clean record cache, pinned
records, prepared deltas, live endpoint contexts, pending calls, and retained
event and receipt pages. Share database connections and immutable schema state
at their owning scope. Track current bytes and high-water marks, and refuse
pressure before unbounded allocation. Warm invocation and final commit make
zero managed access general-purpose allocations. Cold loading and issuance have
named bounded allocation budgets established by their implementation tests.

Benchmark these proposed workloads. Numbers describe test inputs and are not
capacity or latency claims:

| Workload | Required observation |
| --- | --- |
| Warm reads with 1, 8, and maximum grant/resource depths | p50/p95/p99 CPU time, traversal steps, allocations, and policy-intersection cost. |
| Cold indexed reads with 10 thousand and 1 million stored resources under a fixed 32 MiB Loam record-cache budget | Records/bytes read, page-fault batches, bounded working set, cold latency, and no full-store scan or eager actor creation. Database cache is separately capped and reported. |
| Exact, maximum-selection, and subtree scopes | Work versus depth and selection size. No total-owner scan for a scalar admission. |
| Issue/edit/revoke at increasing descendant counts | Durable bytes/rows changed and commit latency. Parent revocation changes constant authoritative state. Observer fanout is measured separately and bounded. |
| Hot reads during slow writes, cold loads, and checkpoint pressure | Host turn duration, unrelated actor latency, busy responses, queue bytes, and recovery fencing. |
| Repeated sharing, release, eviction, deletion, and revoke churn | Quiescent memory, allocator high-water marks, tombstone growth, WAL growth, and reclamation work. |
| Browser JavaScript/Wasm boundary and IndexedDB | Copies and crossings per read/write batch, UI responsiveness, transaction completion latency, quota refusal, and abandoned-observer cleanup. |

Do not put one FFI call or one database transaction around each grant ancestor.
Batch backend reads and foreign completions, and let the Zig continuation
traverse records. On a cold chain, bounded sequential fault batches may still
be necessary, so measure them before adding materialized indexes. Yield long
preflight and listing work at a configured traversal budget through the
executor. No microsecond target is a release claim until a recorded machine,
build, dataset, durability setting, and repeatable run establish it.
