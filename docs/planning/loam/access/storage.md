# Managed access integration with Loam storage

Status: active plan. This document specifies the storage and working-set
contract for the access module's application hosting integration. These are
consumer requirements on [Loam](../architecture.md), not a second storage
implementation. The [Loam API](../api.md) owns shared leases, transaction
phases, backend outcomes, and adapter execution. The
[roadmap](../../../roadmap.md#durable-applications) owns priority; the
[architecture](architecture.md) owns layering and the
[API sketch](api.md) owns the consumer vocabulary. The
[completion queue](../completion.md#execution-order) owns remaining implementation task
priority and dependencies; the [acceptance plan](acceptance.md) owns integration
evidence. The
[shipped inventory](../../../shipped.md#resource-models) describes implementation.
The APIs, storage adapters, and budgets below are proposed unless explicitly
identified as existing. They are requirements to implement and measure.
[ADR-0157](../../../decisions/adr/ADR-0157-access-storage-and-residency.md) records
the decision and its relationship to the implemented primitives.
[ADR-0158](../../../decisions/adr/ADR-0158-access-resource-record-views.md) implements
the first revision-checked resource view and structural record codec.
[ADR-0166](../../../decisions/adr/ADR-0166-access-grant-records-and-plans.md)
adds shared grant views, preparation, and codecs.
[ADR-0167](../../../decisions/adr/ADR-0167-managed-owner-storage.md) implements
durable owner headers and identity indexes, bounded resumable reads, and
transaction staging.
[ADR-0168](../../../decisions/adr/ADR-0168-durable-managed-capability-bindings.md)
adds durable Zig use/control restoration and opaque operations.
[ADR-0169](../../../decisions/adr/ADR-0169-managed-host-turns.md) adds fixed-resource
managed Host turns and ordinary publication restoration. ADR-0170 adds
fixed-resource derivation, reserved publication admission, and bounded retry
receipts.
[ADR-0172](../../../decisions/adr/ADR-0172-explicit-disclosure-of-returned-capabilities.md)
adds declared exact disclosure of stored reference fields.
[ADR-0173](../../../decisions/adr/ADR-0173-dependent-returned-capabilities-and-reference-edits.md)
adds dependent local disclosure plus transactional replacement and removal of
strong reference fields.
[ADR-0178](../../../decisions/adr/ADR-0178-managed-lifecycle-and-mutation-receipts.md)
adds transactional child indexes, persistent moves and leaf deletion, independent
control dependencies and shared mutation receipts. The
[usage guide](../../../loam/access.md#resource-moves-deletion-and-children) documents
Zig query ownership, hosted structural effects and scoped observation.
The [observation guide](../../../loam/access.md#observing-held-access) owns the
implemented exact-context profile and capacity budgets.
[Bounded owner cleanup](../../../loam/access.md#bounded-owner-cleanup) implements
terminal payload reclamation, index pruning and publication retirement.
[Held-authority reference recipes](../../../loam/references.md) implement local
and foreign restoration. [LMDB maintenance](../../../loam/lmdb.md)
implements map growth, inspection and offline compaction; macOS validation
remains maintainer-owned in the completion queue.
The [glowcap memory and persistence research](../research/memory-persistence.md)
now evaluates the generic substrate beneath this contract and storage backend
selection. [ADR-0159](../../../decisions/adr/ADR-0159-memory-and-persistence-research.md)
records that change of scope.

## Decisions

Managed access owns resource/access records, admission, and the authority consequences of
transaction and recovery outcomes. Loam owns shared record
residency and atomic commitment below managed access. Its integration with the existing
Vat and Host coordinates activation and durable execution. The synchronous
cores request storage work as explicit effects; adapters perform I/O through
the embedding's executor. The
[Loam architecture](../architecture.md#product-and-ownership) owns that boundary;
the [actor contract](../actors.md) owns activation and eviction. The two-consumer
experiment proves the API; a custom physical engine needs comparative evidence.

Use the implemented LMDB adapter for LMDB workload and application integration.
Compare another engine when measurements warrant it; use the
[IndexedDB profile](../../../loam/browser.md) for browser execution. The profiles
below specify requirements, not a measured winner. Content and managed access records that
participate in one operation share one backend transaction. Keep a volatile adapter for local ephemeral
applications and the same semantic test suite. Backend selection is explicit;
failure to open durable storage cannot silently select the volatile adapter.

Durable state grows independently of resident resources, callable endpoints,
and connections. A reference retains owner custody and stable identity, not
the entire resource graph, ancestor chain, or message history. Holding an
inactive durable publication does not require a resident actor.

Persistence and bounded loading precede the hosted Rooms integration. The
current graph and ledger reserve their whole record capacity in RAM; that is
an implemented primitive, not the storage architecture to freeze into an ABI.
Replace representation constraints where necessary before prerelease rather
than maintaining parallel authority algorithms or compatibility readers.

## Capability database contract

Managed access supplies resource and grant semantics to an application's durable object
graph. Loam preserves content, references, and managed access records in
the same transaction. The resulting application surface behaves as a capability
database without making managed access the generic storage engine. Its success is an
application that can persist and restore its graph without reconstructing grant
rules, activation, or recovery machinery in application code.

The database's externally usable objects are capabilities. A held resource
reference permits its supported operations under current authority. A stored
reference is a first-class value whose exact authority can be restored. An
internal row key, index entry, or SQL connection is an implementation detail;
the ordinary consumer surface exposes resource operations and scoped queries.
The trusted embedding that owns a backend has custody of its stored authority.
Managed access does not claim to isolate an application from its own database administrator.

The contract has six observable properties:

1. Content and its authority-bearing references commit at the same revision.
2. Saving, copying, loading, and passing a reference preserve its exact source
   authority; a new editable grant appears only through explicit issuance.
3. Restored controls preserve their own powers and dependencies, including
   changes made after publication. A target's existence cannot restore broader
   management authority than the stored control held.
4. Queries and returned references obey the capability through which the caller
   reached them. Counts, ordering metadata, cursors, and errors do not create an
   unrestricted path to the owner's inventory.
5. Eviction changes residency. Deletion, revocation, and publication retirement
   change durable state through their own operations and remain effective after
   recovery and compaction.
6. The backend stores records; one shared Zig implementation decides authority,
   including when data is loaded late, a write is uncertain, or a call resumes.

### References embedded in application content

A conversation entry, attachment, saved invitation, or application-specific
object field can contain a capability. Opaque application bytes alone cannot
teach managed access which references must survive, which authority they carry, or when
they may be reclaimed. The content participant therefore declares its
capability-bearing fields in the same transaction as its payload changes.

The illustrative operation `tx.store_ref(held_capability)` registers the exact
local restoration recipe or already-established foreign sturdyref and returns
a typed stored-reference value for that content field. It consumes or retains
actual capability custody through the existing Host surface. It is not a public
constructor from resource/grant IDs. Typed bindings use this mechanism when
encoding capability fields, rather than serializing their runtime handle bytes.
Loading such a field reconstructs that reference under the field's declared
return policy; copying it does not mint an independent grant.

The reference index records containing resource/field identity, source authority,
projection, and dependencies. Payload and reference-index updates are one
transaction. Removing or replacing a field releases its durable retention edge
only on commit. A live-only capability can be retained in volatile content;
a durable field refuses it unless the source actually supports saving that
exact authority. Obtaining a foreign durable reference may require a separate
remote call before the local transaction, never an invented foreign record ID.

Applications explicitly declare whether a method hands over exact saved
authority or keeps the invoking endpoint as an additional dependency.
`ContentCall.discloseExact` implements direct handoff of a prepared strong
edge under [ADR-0172](../../../decisions/adr/ADR-0172-explicit-disclosure-of-returned-capabilities.md).
`ContentCall.discloseDependent` returns a runtime facet whose target method
must pass both current grants under
[ADR-0173](../../../decisions/adr/ADR-0173-dependent-returned-capabilities-and-reference-edits.md).
`replaceReference` and `removeReference` update prepared strong fields in the
content transaction. The [implemented reference guide](../../../loam/references.md)
owns local dependencies, checked foreign saves and restoration preparation. The storage codec cannot choose or widen a disclosure
mode.

### Queries and consistency

Public queries start from a held collection/resource capability and use a
bounded, typed query surface: selection, order, page size, and cursor. Backend
SQL or IndexedDB indexes supply candidates. Managed access evaluates the relevant scope
and application-declared requirements before disclosing each result or returned
reference. A raw total count or unfiltered index cursor cannot reveal hidden
siblings. Application search indexes have the same disclosure obligations.

The first consistency model is one committed owner revision per operation.
Content facts and authority come from that revision; record batches from
different revisions are never assembled into an admission. A deferred read
rechecks current authority before release. A paginated query can restart or
report conflict after changes rather than retain an indefinitely old snapshot
or disclose data under authority that has since been revoked. Durable commit
determines recovery; serialized owner installation advances the revision visible
to calls before mutation completion is returned. Reads overlapping a pending
write may use the last installed committed revision. A cold read that sees a
newer backend revision waits for installation/recovery rather than exposing
part of the pending write. Already completed reads and delivered bytes cannot
be retracted.

Atomicity stops at the owner transaction boundary. Remote calls, email, or other
external effects cannot be rolled back with the local store. Where an application
needs a durable external action, it records its intent in the same transaction
and executes it afterward with the receiving interface's retry contract. Managed access
must not advertise exactly-once remote effects or distributed transactions on
the strength of local receipts. This does not introduce a general job scheduler.

## Ownership and reuse

| Concern | Owner and reuse |
| --- | --- |
| Grant evaluation, scope, lifecycle, preparation, authority consequences of recovery | managed access core, retaining one Zig implementation for Zig and binding consumers. |
| Shared record residency, storage leases, and byte accounting | Loam core, shared with ordinary records and actor persistence. |
| Grant evaluation scratch and resource-specific limits | managed access core with explicit allocation and bounded operations, using shared storage leases. |
| Record encoding and storage integration | `access/records` encodes owners, directories, resources, grants, and events using Syrup. `access/storage` binds model views and staging to Loam, which owns generic records and backend effects. |
| LMDB execution | Optional LMDB adapter. The embedding runs it on its existing blocking-work executor. Backend comparison is conditional on measured constraints. |
| Browser database execution | The optional Rust IndexedDB executor applies shared persistence batches; no browser-specific grant evaluator. Rooms adoption follows its integration plan. |
| Calls, promises, reference custody, active publications | Existing actors, Vat, Host, and their supported public integration APIs. |
| Network I/O and reachability | Existing driver and transports. Database work does not pass through network transports. |
| Content schemas, application indexes, blobs | Application-owned records participating in the backend transaction; content remains opaque to the access module's authority evaluator. |

The storage codec imports only the lower layers needed to encode records. The
storage backend may depend on its selected database library and storage support,
and is an optional I/O boundary outside `access/core`. Core-only and browser
builds do not link the LMDB database. Adding these modules requires updating
the build's dependency inventory and architecture checks together. The portable
`loam_access_records` and `loam_access_storage` modules and optional blocking LMDB
backend are implemented. The companion C archive must keep optional backend symbols
separable so ordinary managed access users need no database dependency.

The existing [document worker](../../../../apps/rooms/rust/services/src/documents.rs)
already retains blocking work until completion even if its observer cancels.
The [browser transaction owner](../../../../apps/rooms/rust/browser/src/storage/transaction.rs)
already retains callbacks until terminal transaction events. Reuse those
execution and retirement patterns. Their existing separately written document
and archive formats do not provide the new atomic owner store.

The Host is not a general database executor. A Zig embedding supplies
its work-execution boundary; a Rust embedding can use its existing executor.
Workers receive immutable operation inputs and return completions. They never
mutate a live managed access owner or call into the Host from their worker thread.

## Durable records and indexes

An owner is an authority and transaction boundary, not necessarily a database
file. One database can contain several owners. Loam admits one prepared write
per persistence domain, with one writer registration per participating managed access
owner. Multiple
owners in one SQLite file or LMDB environment still share the physical writer
limit of that engine.
Cross-owner content transfer remains an explicit capability operation; sharing
a database does not silently grant cross-owner atomic administration.

| Record family | Durable fields and required lookup |
| --- | --- |
| Owner | Stable owner ID, format/schema identities, monotonic commit revision, allocation high-water marks, writer fencing generation, and receipt/event retention floors. Primary lookup by owner. |
| Resource | Stable ID and generation, kind, lifecycle, canonical parent, content revision and content key. Index children by owner, parent, and stable ordering key. |
| Content | Application records and authority-relevant facts at the resource's committed content revision. Application indexes participate in the same transaction. |
| Content reference | Containing resource/field, exact stored capability recipe, projection, and retention edges. Index outgoing references and incoming durable dependencies. |
| Use grant | Grant ID, selected target/scope, issuance ceiling, configured terms, status, parent/dependencies, delegation bounds, and revision. Index immediate children by parent grant. |
| Grant control | Stable control identity, target grant or explicitly supported management scope, management ceiling, permitted operations, lifecycle, and dependencies. Use authority is not recovered from a control unless explicitly granted. |
| Publication | Existing Host durable publication identity, exact original/use/control restoration recipe, target generation, and dependencies. Point lookup by publication identity; no resource-ID-to-original shortcut. |
| Held dependency | Exact local capability recipe or retained foreign sturdyref, source owner, lifetime and dependency role. Index dependents for bounded cleanup. |
| Operation receipt | Owner and operation identity, source capability identity, intent digest, committed revision, result/publication identities, and retirement epoch. Unique operation lookup. |
| Change event | Owner-local sequence, commit revision, event kind, and affected resource/grant branch. Ordered retention index; delivery still checks observer authority. |
| Retirement metadata | Non-reusable identity high-water marks, dead generations and publication retirement information needed to refuse obsolete access after compaction. |

The table specifies the complete integration destination. The implemented
profile stores owner, resource, grant, and bounded change-batch records in ordinary Loam
records. Four-level sparse radix directories map resource/grant slots to exact
Loam object references; the owner header retains directory roots and persists
the full policy descriptor. Strong record edges make retention visible to
Loam's collector. Both volatile and LMDB backends execute this same profile.

This adds bounded logical directory lookups above the physical engine's index.
Measure that cost before adding an engine-specific secondary index. Future
child listing and scoped queries need transactional projections of canonical
records; an index cannot authorize a result without current record evaluation.

Managed access owns a versioned record codec with explicit field names, bounds, and
schema identities. Reuse Syrup encoding without copying CapTP session records
into storage. The owner persists stable permission/constraint keys and operators;
grant masks refer to that immutable descriptor. Process pointers, struct layouts,
and runtime type names have no durable meaning. Decoders check
lengths and canonical ordering before allocating. Unknown required schema or
format versions refuse opening; prerelease replacement never silently resets
an existing store or accepts an old format through a second policy path.

Publication secrets and retained foreign sturdyrefs are bearer authority.
Their storage, backups, and diagnostic redaction follow the embedding's secret
custody; exporting resource metadata must not silently export those records.
Encryption and access to backup keys belong to the deployment/storage adapter,
with no claim that an opaque on-disk encoding protects authority by itself.

Application content is not copied wholesale into Zig. A prepared operation
owns a bounded content batch or a retained backend-specific content participant.
That participant executes on the same transaction/connection as the managed access batch,
under an expected content revision. It may encode domain data, but cannot
supply a replacement grant evaluator or independently commit its half.

## Backend transaction contract

The [Loam transaction API](../api.md#atomic-mutations) and
[adapter contract](../api.md#adapter-effects-and-failure) own batches, tickets,
completion outcomes, and recovery. Managed access supplies the following data
to those shared operations:

| Shared operation | Managed access participation |
| --- | --- |
| Bounded record read | Owner identity, generation, required revision, and resource/grant keys or ranges. |
| Atomic prepared batch | Resource and grant deltas, content participants, publication recipes, receipt, and authorized event intentions. |
| Recovery | Exact operation identity and intent bound to the owner, plus validation of restored resource authority. |

The access API reports an indeterminate shared commit as `OutcomeUnknown` or
`RecoveryRequired`; it does not submit another write to settle the uncertainty.

One backend transaction compares owner/writer/content revisions and writes
content, resource relationships, grants, controls, publications, indexes,
receipt, and events. It advances the owner revision once. An operation stores
only its delta; neither preparation nor commit clones an owner's entire graph
or content. The adapter maps one prepared decision to one atomic commit; it
does not infer new decisions from storage errors.

Unknown outcomes fence protected access for that owner. Recovery first retires
or joins the old write, then queries its receipt from an authoritative backend
view. A receipt with a different intent is a conflict, not a retry. Known absence
can mean unchanged only after proving the old writer cannot subsequently commit.
After process restart, reload committed metadata and affected rows before
reopening admission. A worker timeout or abandoned future does not prove abort.

Managed access uses Loam's [receipt retirement contract](../api.md#atomic-mutations).
An operation epoch belongs to the issuer's capability context. Receipt lookup
and replay recheck current authority and cannot resurrect a revoked publication
or disclose an otherwise inaccessible result.

### Storage candidates

Loam owns these backend implementations. The research plan owns comparative
selection and physical layouts; the profiles below specify managed access acceptance
requirements on the shared adapters. An LMDB
profile must bound map/reader lifetimes, coordinate resizing, use durable commit
settings, and materialize any data that must outlive a transaction. Cold mapped
reads can block on page faults and therefore run off the Host turn. Its graph
records and indexes must commit in one environment transaction. The SQLite
profile below defines a comparison if measurements warrant that experiment.

### Optional SQLite comparison

Use one database transaction for the owner mutation, including application
content. Default the persistent profile to WAL with `synchronous=FULL` and
verify the effective settings when opening. Keep database operations off the
Host turn. Run checkpoints through the existing executor with byte/time budgets;
record WAL growth, busy time, checkpoint latency, and outstanding read age.
SQLite documents concurrent readers with a single writer in
[WAL mode](https://www.sqlite.org/wal.html), and the durability distinction in
[its synchronous setting](https://www.sqlite.org/pragma.html#pragma_synchronous).
These settings define the comparison profile, not a measured managed access result.

Bound connection counts, queued writes, read duration, and the database page
cache. Do not open a connection or start a task per resource or per capability.
Use bounded lock waits and typed busy outcomes. A lease/fencing generation in
owner state prevents an obsolete registration from committing after a newer
writer takes custody. Hold an exclusive lifetime lock through worker retirement;
do not steal custody from a still-running owner by expiring a timer. Generation
checks fence writes but do not alone stop a former owner serving cached reads.
Database locking alone is not a replication protocol.

### Browser IndexedDB

Place all participating owner records and content stores in one IndexedDB
database and one readwrite transaction. Separate localStorage checkpoints or
independent archive transactions cannot commit half of the operation. Prepare
inputs before starting the transaction; issue dependent requests during active
request callbacks and report commit only on the transaction's completion event.
The [IndexedDB specification](https://www.w3.org/TR/IndexedDB/#transaction-lifecycle)
defines that activity window. Do not hold an IndexedDB transaction across an
arbitrary network await or user interaction.

Request strict durability for authority writes and report the backend's actual
supported durability profile. Browser-managed retention and eviction remain
explicit limitations; a durability hint is not permanent custody. Failure or
quota exhaustion refuses publication rather than silently using memory.
Multi-tab hosting must hold an exclusive owner Web Lock without stealing it,
and fence stale commits using an atomic owner-generation comparison.
[Web Locks](https://www.w3.org/TR/web-locks/) provides the storage-bucket-scoped
custody primitive; lack of that supported primitive refuses this multi-tab
durable hosting profile. Do not use a timeout lease that lets a suspended tab
resume serving stale cached authority. Origin storage access is trusted
embedding access, not a capability isolation boundary between hostile scripts.

## Large content and blobs

Store small content records with their metadata transaction. Large files use
immutable blobs and a committed manifest. Stage bounded chunks outside the
owner write reservation, verify and durably finish the blob, then atomically
commit its manifest reference with the content/access change. The committed
manifest must never point at an unfinished blob. Failure before manifest commit
can leave an orphan to reclaim; it cannot leave published dangling content.
A backend that cannot establish that ordering keeps blobs in its transactional
store or refuses the durable operation.

Reading a blob streams bounded chunks under current access. Recheck before
releasing each subsequent chunk after an asynchronous wait. Already delivered
bytes cannot be recalled. Do not copy the entire file into a frame, owner
snapshot, or Wasm bridge buffer. Shared immutable blob data uses explicit pins;
publication of a digest alone never grants permission to fetch its bytes.

## Resident records and page faults

Replace direct array-only dependencies with a shared, synchronous record-view
interface. The same Zig scope, delegation, and transaction algorithms consume
this view in resident and persistent modes. Lookup returns a validated record,
a known absence, or a typed request for missing records. Storage adapters
provide records and revisions, never answers such as "is ancestor" or "allowed."
An unloaded record is not a missing resource and must not produce `Gone`.

A cold operation retains a bounded continuation containing its held capability,
requirements, target identities, requested keys, and expected revisions. It
returns a read effect to the embedding. The completion carries owner generation,
request identity and snapshot revision. Stale or mismatched completions are
discarded; resume against current state with a bounded restart budget. Negative
lookups are revision-scoped too. A foreign reference remains a retained
capability dependency; loading a foreign grant row cannot replace invoking it.

Load grant ancestry and relevant resource ancestry in bounded batches. The
configured depth and selection limits bound admission's required working set.
Do not pin an entire subtree to check membership. Selected scopes must retain
the current semantics for stale members, even when that requires validating
more than the requested target. Start with explicit bounded traversal; add
indexes or memoization only with equivalence and invalidation tests.

Pins belong to active operations, not every live endpoint. Cache entries contain
immutable record versions; endpoints retain identities and owner leases. A
mutation installs its changed records and invalidates derived access decisions
before returning its event. Since the owner is the exclusive writer, unchanged
cached rows remain valid across a known complete local delta. Whole-decision
caches are keyed by the owner authority revision initially. Reads completing
from an older backend snapshot cannot overwrite newer resident records.

Pin and dirty/prepared bytes have separate limits from evictable cache bytes.
Admission reserves its bounded working set before taking the mutation slot.
If it cannot fit, return pressure without starting an unfinishable transaction.
Eviction releases only unpinned, clean rows; it does not revoke a capability,
destroy content, or require a durable write. Large cold stores are supported
without allocating their total capacity when opening an owner.

Canonical containment stores parent edges. Depth is derived or a validated
index value, not a requirement to rewrite every descendant after a move.
Cycle and maximum-depth validation must remain in Zig. A large subtree move
uses bounded, resumable preflight over a consistent owner revision to establish
subtree height and audience effects, followed by revision-checked commit.
Continuation state is bounded; elapsed-work limits may refuse an oversized
move before mutation. Revision drift restarts or conflicts; it cannot commit
a partly validated move. The current descendant-depth rewrite must change
before claiming move cost independent of subtree size.

## Buffer and completion ownership

| Value | Lifetime and release owner |
| --- | --- |
| Synchronous arguments and content facts | Borrowed for the owning turn only; an asynchronous operation must retain or copy its bounded inputs before returning. |
| Backend read buffers | Owned by the read completion until transferred into validated cache storage or discarded; decoding cannot retain a released database cursor's memory. |
| Record pins and operation scratch | Owned by one active managed access operation until settlement, cancellation completion, or recovery transfers custody. |
| Prepared mutation and content participant | Retained through the real write outcome, including uncertainty; caller cancellation cannot free them underneath storage. |
| Host capabilities and answer completion | Retained/released by existing Host custody; workers carry operation tickets rather than thread-unsafe live owner pointers. |
| Completed return buffers | Explicit transfer or bounded borrow through the existing Zig/FFI conventions, with one release owner. |

SQLite row data and browser database values can require bounded materialization
before their backend callback ends. Name and measure that copy at the adapter;
do not claim zero-copy storage or hide another copy in each language binding.
Coalesced reads share immutable buffers only while explicit pins keep them live.
Owner shutdown stops admission, retires/join-completes effects, then releases
pins and buffers; stale completion tickets refuse without touching freed state.

## Calling patterns

Consumer APIs remain capability calls. Holding the invoked reference supplies
its authority. The local and remote entry points feed the same managed access operation;
no caller supplies an additional grant credential or manually drives a cache.
A full application binding returns an immediate result or its language's usual
future/promise. The lower-level embedding API exposes effects explicitly.

| Call | Execution and cost contract |
| --- | --- |
| Warm scalar read | Check current authority and borrow resident content facts in the same owning turn. No managed access heap allocation, storage operation, durable receipt, or extra queue hop. Reply encoding may have its existing transport cost. |
| Cold read | Retain one bounded operation; batch missing records through storage; resume on the owning executor and recheck authority before disclosing content. |
| Mutation | Load facts, prepare one bounded delta, reserve memory/publication capacity, run one backend commit, install synchronously without allocation, then emit events and settle. |
| Share existing authority | Retain/pass the exact existing capability through Host custody. No new grant or storage write unless new durability/publication is explicitly requested. |
| Issue a durable facet | Commit grant, optional control, publication recipe and receipt together; return the exact publication after commit. |
| Long read or listing | Use bounded chunks/pages and recheck current authority on each delivery. Release database snapshots between pages; an access-scoped cursor may report conflict after reorganization. |
| Remote dependency | Use existing send/forward/deferred-answer operations. Never hold a local database transaction while waiting on the network or report a remote timeout as revocation success. |

Local hosted calls use the existing near-call/eventual-send mechanisms. A warm
operation may finish in its turn; an operation needing storage defers through
the existing Host answer mechanism. Direct non-hosted Zig calls use the same
core and storage effect contract without dialing a dummy session. Blocking
convenience APIs, if exposed, are explicitly named and forbidden on the Host
execution thread. No synchronous core lookup hides an I/O wait.

Clients may use the existing CapTP promise-pipelining machinery for deferred
results. A capability-producing promise resolves only after its authority is
committed and installed; pipelined calls cannot invoke the proposed grant early.
Existing Host/promise queue limits apply, alongside managed access pending-call budgets.
Managed access introduces no second pipeline or per-grant progress loop. Bounded explicit
multi-resource commands can share one owner transaction when the application
declares their combined authority and all-or-nothing effect; do not secretly
batch independently acknowledged operations under weaker durability.

A content handler supplies operation requirements and facts, prepares opaque
content changes, and receives admission bound to that effect and revisions.
It must not run a reusable `require` check, await arbitrary work, then mutate
content without another admission. Returned capabilities are checked or wrapped
before disclosure, including after deferred content reads and event delivery.

Once a durable commit has completed, the accepted mutation has happened even
if its caller disconnected. Reply delivery and event fanout can fail without
undoing it. Retained receipts allow recovery. Cancellation before storage starts
can discard preparation; cancellation during storage retires the observer and
joins the actual operation before state is released.

## Publication and restoration

Durable publication uses the existing Host's publication identity and capability
custody. Store the exact authority recipe, including control ceilings and
lifecycle, rather than serializing a process-local opaque pointer. Restoring a control
must not construct an unrestricted controller from just its target grant.
Original publications retain original authority; facet publications retain
their grant dependency. Preserve the peer/restorer identity needed by existing
locators as part of deployment custody and backup.

Opening an owner loads its header, schemas, recovery metadata, and requested
working set. Resolve a durable publication by indexed lookup and load only its
needed resource/grant/control records. Do not enumerate every stored publication
and spawn every actor at startup. The active publication registry remains
Host-owned; the access module's store owns the restoration recipes.

Two integration requirements must be proven against the existing Host API:
reserve an endpoint/publication's installation capacity before committing
issuance, and defer a cold durable lookup while its recipe is loaded. If current
public APIs cannot do either, extend the owning Host publication/answer seam.
Do not implement a second export table or publication server inside managed access.
These reservations and a lazy resolver are not currently implemented by managed access.

A crash after commit but before publication installation leaves a restorable
recipe and receipt. Retry installs or returns that same publication, never a
new grant. Installation failure keeps the committed result recoverable and
reports its state accurately. Network transmission need not be infallible;
the local post-commit state transition must be allocation-free and non-reentrant.

Restore validates records lazily at their bounded trust boundary and checks
referential consistency on use. Missing required grant ancestors, unavailable
foreign dependencies, or malformed control definitions refuse access. An
operator consistency scan can validate the full store incrementally without
making every normal open an unbounded scan.

## Reclamation and backup

Live reference release, cache eviction, content deletion, grant revocation,
publication removal, and owner retirement are distinct operations. Durable
roots include application-owned content roots, active publications, retained
capability dependencies, and recoverable operations. A live operation's pins
also prevent reclamation of its records and buffers.

Start with explicit deletion and bounded maintenance, not distributed garbage
collection. Revoke/retire authority transactionally, then reclaim payloads only
when no durable dependency or active pin needs them. Cyclic content links cannot
be collected solely by reference counting: periodic bounded tracing or explicit
owner deletion determines their durable reachability. Remote peers holding a
sturdyref do not promise to report their last release; an active publication
therefore remains a root until explicitly retired by its owner.

Compact terminal grants and removed publications into sufficient dead-identity
metadata. Never reuse an old grant/control/publication identity, reinterpret an
old slot after generation reset, or expire a receipt into permission to reissue.
A missing compacted ancestor always refuses; surviving dependents cannot become
independent roots. Reclamation and retired-ID storage must be benchmarked under
sustained issue/revoke churn, not only a live-record steady state.

A backup contains a consistent owner revision, blobs reachable from its
manifest, publication/restorer custody, schemas, and retirement/receipt floors.
Use the selected engine's consistent backup facility, such as SQLite's
[backup API](https://www.sqlite.org/backup.html), rather than copying a live
database file without its transaction state. Pin reachable blobs
while backing up; serialize backup and reclamation decisions through the same
owner revision contract. Restoring an older backup under the same public
identity can undo later revocations. Same-identity recovery therefore requires
a complete authoritative recovery history, including committed revisions that
may already have been exposed. It cannot roll behind acknowledged changes. If
that completeness cannot be established, restore as a new owner/publication
identity and explicitly reshare. Do not claim
rollback-resistant revocation from a database snapshot alone.

## Performance contract and measurements

Measure the access module's incremental cost separately from database caches, application
content, actor objects, transport buffers, and page cache. Count all of them
in end-to-end resident-memory results. An ordinary non-managed access actor pays zero
managed access allocation and retains no managed access state.

Use an explicit per-owner memory budget with sublimits for clean record cache,
pinned records, prepared deltas, live endpoint contexts, pending calls, and
retained event/receipt pages. Share database connections and immutable schema
state at their owning scope. Track current bytes and high-water marks, and
refuse pressure before unbounded allocation. Warm invocation and final commit
have zero managed access general-purpose allocations; cold loading and issuance have
named bounded allocation budgets established by their implementation tests.

Benchmark these proposed workloads; numbers describe test inputs, not achieved
capacity or latency claims:

| Workload | Required observation |
| --- | --- |
| Warm reads with 1, 8, and maximum grant/resource depths | p50/p95/p99 CPU time, traversal steps, allocations, and policy-intersection cost. |
| Cold indexed reads with 10 thousand and 1 million stored resources under a fixed 32 MiB Loam record-cache budget | Records/bytes read, page-fault batches, bounded working set, cold latency, and no full-store scan or eager actor creation. Database cache is separately capped and reported. |
| Exact, maximum-selection, and subtree scopes | Work versus depth and selection size; no total-owner scan for a scalar admission. |
| Issue/edit/revoke at increasing descendant counts | Durable bytes/rows changed and commit latency. Parent revocation changes constant authoritative state; observer fanout is measured separately and bounded. |
| Hot reads during slow writes, cold loads, and checkpoint pressure | Host turn duration, unrelated actor latency, busy responses, queue bytes, and recovery fencing. |
| Repeated sharing, release, eviction, deletion, and revoke churn | Quiescent memory, allocator high-water marks, tombstone growth, WAL growth, and reclamation work. |
| Browser JavaScript/Wasm boundary and IndexedDB | Copies and crossings per read/write batch, UI responsiveness, transaction completion latency, quota refusal, and abandoned-observer cleanup. |

Do not put one FFI call or one database transaction around each grant ancestor.
Batch backend reads and foreign completions; the Zig continuation traverses
records. On a cold chain, bounded sequential fault batches may still be
necessary; measure them before adding materialized indexes. Yield long
preflight/listing work at a configured traversal budget through the existing
executor. No proposed microsecond target is a release claim before a recorded
machine, build, dataset, durability setting, and repeatable run establish it.
