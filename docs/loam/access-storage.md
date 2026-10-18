---
type: static
description: What managed access needs from Loam storage and its working set.
audience: human
sources:
  - resource: /src/loam/access/storage/
  - resource: /src/loam/core/
  - resource: /src/loam/hosting/
---

# Managed access integration with Loam storage

Managed access keeps its records in [Loam](architecture.md) and has no
storage engine of its own. Content, grants, and receipts share Loam's
transactions, cache limits, and recovery. Your program picks a storage engine
and runs its work outside the Host's message handling.
[ADR-0157](../decisions/adr/ADR-0157-access-storage-and-residency.md) records
the decision, and the [access architecture](access-architecture.md) lists the
decision behind each part that exists.

The managed access guide describes each operation:

- [Resource moves, deletion, and children](access.md#resource-moves-deletion-and-children):
  listing children from Zig, tree changes in hosted calls, and what watchers
  see
- [Observing held access](access.md#observing-held-access): registering a
  receiver and its limits
- [Bounded owner cleanup](access.md#bounded-owner-cleanup): freeing finished
  records, pruning indexes, and retiring durable names
- [Stored capability fields](references.md): saving and restoring local and
  remote references
- [SQLite operations](sqlite.md) and [LMDB operations](lmdb.md): capacity,
  inspection, and compaction

The [Loam API](api.md) defines leases, transaction steps, and storage
outcomes, and the [coverage page](coverage.md) lists the tests.

## Who decides what

Managed access decides which resources and grants exist, who may act, and
what a commit or recovery means for access. Loam decides which records stay
in memory and commits them atomically, and its Host attachment wakes actors
and runs durable work. The synchronous cores ask for storage work as explicit
requests, and your program's storage worker does the I/O on its own executor.
[Loam's architecture](architecture.md#who-owns-what) draws that line, and the
[actor guide](actors.md) covers waking actors and putting them to sleep. A new
kind of storage engine needs measurements against the existing ones.

- [SQLite](sqlite.md) is the default disk engine. [LMDB](lmdb.md) meets the
  same contract, and [IndexedDB](browser.md) serves the browser.
- Content and managed access records changed by one operation share one
  engine transaction.
- A volatile engine serves local applications that keep nothing between runs,
  and passes the same tests.
- You choose the engine explicitly. Failing to open durable storage never
  falls back to the volatile engine.

Stored state can grow without adding resources in memory, callable
endpoints, or connections. A reference keeps its owner and a stable identity,
not the resource tree, its ancestors, or message history. A durable name
nobody is using needs no actor in memory.

The tree and grant records reserve their whole record capacity in memory.
That layout stays out of every ABI so it can change.

## Content and access in one transaction

Loam commits an application's content, its stored references, and the managed
access records for its resources and grants in the same transaction.

A held resource reference allows its operations under current permissions,
and a stored reference is a value whose access can be restored. Row keys,
index entries, and SQL connections are never exposed. Whoever runs the
storage engine controls everything stored in it, so managed access does not
protect an application from its own database administrator.

These rules hold:

1. Content and the references that carry access commit at the same revision.
2. Saving, copying, loading, and passing a reference keep its access. A new
   editable grant appears only when someone issues one.
3. Restored controls keep their own powers and dependencies, including
   changes made after they were published. A target existing cannot restore
   more control than the stored control had.
4. Queries and returned references stay within the capability the caller
   used to reach them. Counts, ordering, cursors, and errors never open an
   unrestricted path to everything the owner holds.
5. Evicting a record changes only what is in memory. Deleting, revoking, and
   retiring a durable name change stored state through their own operations
   and stay in effect after recovery and compaction.
6. The engine only stores records, and one shared Zig implementation decides access,
   including when data loads late, a write's outcome is unknown, or a call
   resumes.

### References embedded in application content

A conversation entry, attachment, saved invitation, or other application
field can hold a capability. Opaque bytes cannot tell managed access which
references must survive or when they can be freed, so the content declares
its capability fields in the same transaction as its payload changes.

The sketch call `tx.store_ref(held_capability)` saves the local recipe for
restoring the capability, or a remote sturdyref it already has, and returns a
typed stored-reference value for that field. It never builds a reference from
resource and grant IDs. Typed bindings use it instead of serializing run-time
handle bytes. Loading the field rebuilds the reference under the field's
declared rules for returning it, and copying it creates no grant.

The reference index updates with the payload in one transaction. Removing or
replacing a field releases the edge that kept the old reference alive only
when the change commits. A live-only capability can sit in volatile content,
and a durable field refuses it unless its source can save that access. A
durable remote reference may need a remote call before the local
transaction, and is never a made-up remote record ID.

A method either hands over the saved capability or keeps the called endpoint
as a dependency:

- `ContentCall.discloseExact` hands over a strong field the call declared
  ([ADR-0172](../decisions/adr/ADR-0172-explicit-disclosure-of-returned-capabilities.md)).
- `ContentCall.discloseDependent` returns a facet whose target method must
  pass both current grants
  ([ADR-0173](../decisions/adr/ADR-0173-dependent-returned-capabilities-and-reference-edits.md)).
- `replaceReference` and `removeReference` change declared strong fields in
  the content transaction.

The [stored capability field guide](references.md) covers local
dependencies, checked remote saves, and preparing a restore. The storage
encoding cannot choose or widen how a capability is handed out.

### Queries and consistency

Public queries start from a held collection or resource capability and offer
a bounded, typed set of options: which items, what order, page size, and a
cursor. Engine indexes supply candidates, and managed access checks scope and
declared requirements before revealing each result or returned reference. A
raw total count or unfiltered index cursor could reveal hidden siblings, so
neither is offered, and application search indexes must hold to the same
rule.

Each operation sees one committed owner revision. Content facts and
permissions both come from it, and a check never mixes records from different
revisions. A deferred read checks current permissions again before it
answers. A paged query can restart or report a conflict after changes, and
never keeps an old snapshot or reveals data after a revoke.

A durable commit decides what recovery finds. The owner moves the revision
that calls see before the change's result returns. Reads during a pending
write may use the last applied revision, and a read from disk that finds a
newer revision waits for the Store to take it in or for recovery, instead of
showing part of the write. Bytes already delivered cannot be taken back.

Atomicity ends at the owner's transaction. Remote calls, email, and other
outside effects cannot roll back with the local store. An application that
needs a durable outside action records what it means to do in the same
transaction and does it afterward under the receiving interface's retry
rules. Local receipts give no exactly-once remote effects and no distributed
transactions.

## Who owns each part

| Part | Owner |
| --- | --- |
| Checking grants, scope, and status, preparing changes, and what recovery means for access | The managed access core, one Zig implementation for Zig and every binding. |
| Keeping records in memory, storage leases, and counting bytes | Loam's core, shared with ordinary records and actor storage. |
| Encoding records and connecting them to storage | `access/records` encodes owners, directories, resources, grants, and events with Syrup. `access/storage` connects views and writes to Loam, which owns general records and engine work. |
| Running LMDB | The optional LMDB engine, run on your program's executor for blocking work. |
| Running the browser database | The optional Rust IndexedDB executor applies the shared storage batches. There is no separate browser grant checker. |
| Calls, promises, holding references, and active durable names | The existing actors, Vat, Host, and their public APIs. |
| Network I/O and reachability | The existing driver and transports. |
| Content schemas, application indexes, and large binary data | The application's own records, written in the same engine transaction. The access checks never look inside content. |

The record encoding imports only the lower layers it needs. A storage engine
may depend on its database library and sits outside `access/core` as optional
I/O, so builds of the core alone and browser builds link neither LMDB nor
SQLite. The portable `loam_access_records` and `loam_access_storage` modules
exist beside the optional LMDB and SQLite engines, which block. The C archive
keeps each engine's symbols separate.

The [document worker](../../apps/rooms/rust/services/src/documents.rs) keeps
blocking work until it completes, even if its watcher cancels, and the
[browser transaction owner](../../apps/rooms/rust/browser/src/storage/transaction.rs)
keeps callbacks until the transaction's final event. Reuse those patterns,
not their document and archive formats.

The Host is not a database executor, so your program supplies one. Workers
receive fixed inputs and return completions, and never change a live owner
or call into the Host from their thread.

## Stored records and indexes

An owner is a boundary for permissions and transactions, not necessarily a
database file, and one database can hold several owners. Loam allows one
prepared write per store, with one writer per owner taking part. Owners in
one file or LMDB environment still share that engine's single writer. Moving
content between owners is an explicit capability operation, and a shared
database gives no atomic control across owners.

| Record | What it stores and how it is found |
| --- | --- |
| Owner | Stable owner ID, format and schema identities, a commit revision that only goes up, the highest IDs allocated. Looked up by owner. |
| Resource | Stable ID and generation, kind, status, parent, content revision, and content key. Children indexed by owner, parent, and a stable ordering key. |
| Content | Application records and the facts permissions depend on, at the resource's committed content revision. Application indexes join the same transaction. |
| Content reference | The resource and field holding it, the exact stored capability recipe, any narrowing, and the edges that keep it alive. Outgoing references and incoming durable dependencies are indexed. |
| Use grant | Grant ID, target or scope, the limit it was issued with, its terms, status, parent and dependencies, how far it can be shared, and revision. Direct children indexed by parent grant. |
| Grant control | Stable control identity, the grant or scope it manages, its limit, allowed operations, status, and dependencies. A control never yields use access unless it was granted. |
| Durable name | The Host's durable name identity, the exact recipe for restoring the original, use, or control capability, the target's generation, and dependencies. Looked up directly by name. No shortcut from a resource ID to the original. |

Owner, resource, grant, and bounded
change-batch records are stored as ordinary Loam records. Sparse four-level directories
map resource and grant slots to Loam object references. The owner header
keeps the directory roots and saves the full policy. Strong edges between
records let Loam's collection see what is still in use. The volatile, LMDB,
and SQLite engines all run this layout.

The directories add a bounded number of lookups above the engine's own index,
so measure that cost before adding an index for one engine. An index never
authorizes a result without checking the current record. The one index that
exists is engine-neutral and resident: `Capabilities` keeps the last few
owners' decoded headers and resolved directory slots at their committed header
revision, because a directory edit always re-proposes the header. A repeat
operation on one of those owners copies the header and binds each demanded
slot without walking, and a transaction that has staged the owner bypasses
the index until commit. A committed resource row decodes once per revision:
the binding keeps its reply for the Read, and the index keeps it for the
next Read at the same revision.

Managed access owns a versioned record encoding, built on Syrup, with field
names, limits, and schema identities.

- The owner saves stable permission and constraint keys and operators, and
  grant masks refer to that fixed description.
- Process pointers, struct layouts, and run-time type names mean nothing on
  disk.
- Decoders check lengths and ordering before allocating.
- An unknown required schema or format version refuses to open. A format
  change before release never resets an existing store or reads an old format
  through a second path.

Durable name secrets and kept remote sturdyrefs grant access to whoever holds
them. Store, back up, and redact them in logs the way your program handles
other secrets, and never include them when exporting resource metadata.
Encryption and backup keys belong to whoever runs the deployment.

Application content is never copied wholesale into Zig. A prepared operation
owns a bounded batch of content changes, or a content participant that runs
in the same transaction as the managed changes, under an expected content
revision. Content cannot supply its own grant checker or commit its half
alone.

## What managed access hands to each transaction

The [Loam transaction API](api.md#transactions) and
[storage work and failure](api.md#storage-work-and-failure) define batches,
tickets, outcomes, and recovery. Managed access supplies this data to them:

| Loam operation | What managed access supplies |
| --- | --- |
| Bounded record read | Owner identity, generation, the revision it needs, and resource or grant keys or ranges. |
| Atomic batch | Resource and grant changes, content participants, durable name recipes, a receipt, and the events to publish after commit. |
| Recovery | The exact request identity and its content for that owner, plus checks on the restored resources. |

The access API reports a shared commit with an unknown outcome as
`OutcomeUnknown` or `RecoveryRequired`, and submits no other write to settle
it.

One engine transaction compares the owner, writer, and content revisions and
writes content, relationships, grants, controls, durable names, indexes, the
receipt, and events. It moves the owner revision forward once. An operation
stores only what changed, and the storage worker never turns a storage error
into an access decision.

An unknown outcome blocks protected access to that owner. Recovery waits for
the old write to finish, then looks up its receipt from a view the engine
guarantees is current. A receipt with a different request is a conflict, not
a retry. Absence means nothing changed only once the old writer provably
cannot commit later, and a worker timeout or abandoned future proves nothing.
After a restart, reload committed metadata and affected records before
allowing calls again.

Managed access uses Loam's [receipt rules](api.md#retries-and-receipts). A
request's sequence belongs to the capability it came through. Looking up and
replaying a receipt checks current permissions again, so it cannot bring back
a revoked durable name or reveal a result the caller can no longer see.

### Disk engines

[Stores, transactions and reads](store.md) covers the transactions and
borrowed reads every disk engine shares. Each engine locks its directory
until its workers finish and it closes, and a timeout never hands that lock
to another process. Each engine's own page covers its durability settings,
capacity, cache costs, and maintenance.

The [workload guide](../../bench/loam/README.md) describes the comparisons,
and the [recorded results](../../bench/loam/results.md) give each run's
settings. One workload's result does not pick the engine for every
application.

### Browser IndexedDB

Put every owner record and content store an operation touches in one
IndexedDB database and one readwrite transaction. Separate localStorage
checkpoints or archive transactions could commit half of the operation.
Prepare inputs before the transaction, issue dependent requests inside active
request callbacks (see the
[transaction lifecycle](https://www.w3.org/TR/IndexedDB/#transaction-lifecycle)),
and report a commit only on the completion event. Never hold a transaction
open across a network wait or user interaction.

Ask for strict durability on writes that change access, and report what the
engine promises. The browser can still evict storage, and a durability hint
is not a promise to keep data forever. A failure or full quota refuses to
publish instead of falling back to memory.

With several tabs open, the hosting tab holds an exclusive
[Web Lock](https://www.w3.org/TR/web-locks/) for the owner without stealing
it, and stops stale commits by comparing the owner's generation atomically.
Without Web Locks this setup refuses to run, because a lease with a timeout
would let a suspended tab serve stale access. Any script with access to the
origin's storage is trusted, and nothing here protects scripts on that origin
from each other.

## Content size

Content lives in records whose schema bounds their size, and commits with
its metadata. Loam has no separate API for large binary data or streamed
files. An application that stores large files elsewhere owns their
durability, access checks, and consistency with the references it commits to
Loam. A saved digest alone gives no permission to fetch those bytes.

## Records in memory and loading on demand

One synchronous interface for viewing records lets the same Zig scope,
sharing, and transaction code run on records in memory and on disk. A lookup
returns a checked record, a known absence, or a typed request for missing
records. Storage workers supply records and revisions, never answers such as
"is an ancestor" or "allowed". A record that is not loaded leads to a read
request, and only a confirmed absence produces `Gone`.

An operation that needs records from disk keeps a bounded record of where it
is: its capability, requirements, targets, requested keys, and expected
revisions. It returns a read request to your program. The result carries the
owner generation, the request identity, and the snapshot revision, and a
stale or mismatched result is dropped. The operation then resumes against
current state, with a limit on restarts. A lookup that found nothing is also
tied to its revision. A remote reference stays a held capability, and loading
a remote grant record never replaces calling it.

Grant and resource ancestors load in bounded batches. Depth and selection
limits bound what one check holds in memory, and no check pins a whole
subtree to test membership. Chosen scopes keep their meaning for stale
members, even when that means checking more than the requested target. Add
indexes or memoization only with tests that show the results match and that
invalidation works.

Pins belong to active operations, not to every live endpoint. Cache entries
hold record versions that never change, and endpoints keep identities and
owner leases. A change applies its new records and drops cached access
decisions before returning its event. The owner is the only writer, so
unchanged cached records stay valid across a whole local change. Cached
decisions are keyed by the owner's revision, and a read from an older engine
snapshot cannot overwrite newer records in memory.

Pinned, changed, and prepared bytes have their own limits, apart from cache
bytes that can be evicted. A check reserves its memory before taking the
write slot, and reports pressure instead of starting a transaction it cannot
finish. Eviction drops only unpinned, unchanged records and changes nothing
stored. Opening an owner
allocates nothing in proportion to a large store on disk.

The tree stores parent edges. Depth is computed or a checked index value, so
moving a resource rewrites none of its descendants. Checks for cycles and
maximum depth stay in Zig.

Moving a large subtree first runs a bounded check that can pause and resume,
over one owner revision, to learn the subtree's height and who gains or loses
access. A commit checked against that revision follows. The check reads each
descendant once, so its cost grows with the subtree, while the commit
rewrites only the moved resource's edges and two directory indexes. A limit
on elapsed work may refuse an oversized move before anything changes, a
newer revision restarts the move or reports a conflict, and a move that was
only partly checked never commits.

## Who owns each buffer

| Value | How long it lives and who releases it |
| --- | --- |
| Synchronous arguments and content facts | Borrowed for the turn that owns them. An asynchronous operation must keep or copy its bounded inputs before returning. |
| Engine read buffers | Owned by the read result until moved into checked cache storage or dropped. Decoding cannot keep memory from a released database cursor. |
| Record pins and operation scratch | Owned by one active managed operation until it finishes, its cancellation completes, or recovery takes them over. |
| A prepared change and its content participant | Kept until the real write outcome is known, including an unknown one. A caller canceling cannot free them while storage still uses them. |
| Host capabilities and answer completion | Kept and released by the Host as usual. Workers carry operation tickets, never pointers to a live owner that are unsafe across threads. |
| Returned buffers | Handed over explicitly or borrowed within a bound, following the existing Zig and C conventions, with one owner who releases them. |

SQLite rows and browser database values may need a bounded copy before their
engine callback ends. Name and measure that copy in the storage worker, never
claim zero-copy storage, and never hide a copy in a binding. Reads combined
into one share fixed buffers only while pins keep them alive. Shutting down an
owner stops new calls, waits for pending work, then releases pins and
buffers, and a stale result ticket is refused without touching freed memory.

## How calls run

Local and remote callers go through the same managed operation, and no caller
manages a cache. An application binding returns a result at once or as its
language's future or promise, and the Zig API returns storage requests.

| Call | How it runs and what it costs |
| --- | --- |
| Read with records in memory | Check current permissions and borrow content facts in the same turn. No managed heap allocation, storage operation, durable receipt, or extra queue hop. Encoding the reply keeps its usual transport cost. |
| Read that needs disk | Keep one bounded operation. Batch the missing records through storage. Resume on the owning executor and check permissions again before revealing content. |
| Change | Load facts, prepare one bounded change, reserve memory and durable name room, run one commit, apply it synchronously without allocating, then send events and answer. |
| Pass on existing access | Keep and pass the existing capability through the Host. No new grant or storage write unless new durability or a durable name is asked for. |
| Issue a durable facet | Commit the grant, optional control, durable name recipe, and receipt together. Return the durable name after the commit. |
| Long read or listing | Use bounded chunks or pages and check current permissions on each delivery. Release database snapshots between pages. A scoped cursor may report a conflict after the tree changes. |
| Remote dependency | Use the existing send, forward, and deferred-answer operations. Never hold a local database transaction while waiting on the network, and never report a remote timeout as a successful revoke. |

Local hosted calls use near calls and eventual sends. An operation with its
records in memory may finish in its turn, and one that needs storage defers
through the Host's answer mechanism. Direct Zig calls outside hosting use the
same core and storage requests without connecting to anyone. Blocking helper
APIs say so in their names and are forbidden on the Host's thread. No
synchronous core lookup hides an I/O wait.

Clients may pipeline CapTP promises. A promise for a capability resolves only
after its access is committed and applied, so a pipelined call can never use
an uncommitted grant. Host and promise queue limits apply alongside managed
access limits on pending calls. A bounded command that touches several
resources can share one owner transaction when the application declares
their combined permissions and that they all succeed or fail together.
Operations confirmed separately are never batched under weaker durability.

A content handler supplies requirements and facts, prepares opaque content
changes, and receives a permission result tied to that change and its
revisions. It must not run a reusable `require` check, wait on unrelated
work, then change content without checking again. Returned capabilities are
checked or wrapped before they are handed out, including after deferred
content reads and event delivery.

Once a durable commit completes, the change has happened even if its caller
disconnected, and kept receipts let it be recovered. Delivering the reply or
events can fail without undoing it. Canceling before storage starts discards
the preparation. Canceling during storage drops the waiting caller and waits
for the operation before releasing state.

## Durable names and restoring

Durable names use the Host's own name identity and reference handling. Store
the recipe for the access, including control limits and status, never a
pointer that only means something in this process. Restoring a control must
never build an unrestricted controller from its target grant. A durable name
for an original keeps original access, and one for a facet keeps its grant.
Deployment and backup must keep the peer and restorer identity that existing
locators need.

Opening an owner loads its header, schemas, recovery data, and the records
asked for. A durable name is found by an indexed lookup that loads only its
resource, grant, and control records, so startup neither lists every durable
name nor starts every actor. The Host owns the registry of active durable
names, and the access store owns the recipes for restoring them.

Issuing reserves room for the endpoint or durable name before it commits, and
looking up a durable name that is not in memory waits while its recipe loads
([ADR-0176](../decisions/adr/ADR-0176-on-demand-durable-publication-discovery.md)).
Anything the Host is missing goes into the Host's own durable name or answer
path, never into a second export table or name server in managed access.

A crash after the commit but before the durable name is installed leaves a
restorable recipe and receipt. A retry installs or returns that durable name
and creates no new grant. The local step after the commit allocates nothing
and cannot be reentered.

Restoring checks records when they are first used and checks that they agree
with each other on use. Missing grant ancestors, unavailable remote
dependencies, or damaged control records refuse access. A scan that someone
runs on purpose checks the whole store a piece at a time, so an ordinary open
never scans it.

## Freeing space and backups

Releasing a reference, evicting from the cache, deleting content, revoking a
grant, removing a durable name, and retiring an owner are separate
operations. What keeps stored records alive is application content roots,
active durable names, held capability dependencies, and requests that can
still be recovered. A running operation's pins also keep its records and
buffers.

Freeing space uses explicit deletion and bounded cleanup, not distributed
garbage collection. Access is revoked or retired in a transaction, and
payloads are freed once no durable dependency or active pin needs them.
Reference counting cannot free cycles of content links, so bounded tracing or
deleting the owner decides whether they are still reachable. Remote holders
of a sturdyref never report that they dropped it, so an active durable name
stays a root until its owner retires it.

Finished grants and removed durable names shrink to a record of dead
identities. An old grant, control, or durable name identity is never reused,
a slot is never read as something else after its generation resets, and an
expired receipt never allows issuing again. A missing ancestor that was
compacted away refuses access, and surviving dependents never become roots of
their own.

A backup must keep one consistent owner revision, the durable name and
restore records, schemas, and the lowest valid sequences for retirement and
receipts. Loam has no shared backup API. A program using an engine's own
backup tool must keep that consistency and any application files stored
elsewhere. Never copy a live database file without its transaction state.

Restoring an older backup under the same public identity can undo later
revokes. Recovering under the same identity therefore needs the complete
history, including committed revisions that may already have been seen, and
cannot roll back behind changes that were confirmed. Otherwise restore as a
new owner with new durable names, and share again.

## Performance contract and measurements

Measure what the access module itself adds, apart from database caches,
application content, actor objects, transport buffers, and the OS page
cache, and count all of them in end-to-end memory results. An ordinary actor
pays no managed access allocation and keeps no managed access state.

Each owner's memory budget has separate limits for cached records, pinned
records, prepared changes, live endpoint contexts, pending calls, and kept
event and receipt pages. Track current bytes and the highest seen, and refuse
under pressure before allocating without bound. Calls on records in memory
and the final commit make no general-purpose allocations in managed access.
Loading from disk and issuing grants have allocation limits set by their
tests.

The numbers below are test inputs.
`zig build bench-loam -- --scale-only` measures indexed reads from disk.
`zig build loam-browser-test` checks atomic browser storage, ownership,
cancellation, sharing, and restoring after a page reload. The
[roadmap](../roadmap.md#durable-applications) tracks the rest.

| Workload | What it must show |
| --- | --- |
| Reads from memory at grant and resource depths of 1, 8, and the maximum | p50, p95, and p99 CPU time, steps walked, allocations, and the cost of intersecting policies. |
| Indexed reads from disk with 10 thousand and 1 million stored resources under a fixed 32 MiB Loam record cache | Records and bytes read, batches of loads, a bounded working set, latency, and no full-store scan or actors started early. The database cache has its own cap and is reported separately. |
| Exact, largest-selection, and subtree scopes | Work against depth and selection size. No scan of the whole owner for a single check. |
| Issue, edit, and revoke with more and more descendants | Stored bytes and rows changed and commit latency. Revoking a parent changes a fixed amount of stored state. Notifying watchers is measured separately and bounded. |
| Frequent reads during slow writes, loads from disk, and checkpoint pressure | Host turn time, latency of unrelated actors, busy responses, queue bytes, and blocking during recovery. |
| Repeated sharing, release, eviction, deletion, and revoke churn | Memory at rest, the allocator's highest use, growth of removed-record markers, WAL growth, and cleanup work. |
| The browser's JavaScript and Wasm boundary and IndexedDB | Copies and crossings per read or write batch, how responsive the UI stays, transaction latency, quota refusals, and cleanup after a watcher goes away. |

Never wrap each grant ancestor in its own FFI call or database transaction.
Batch engine reads and foreign completions, and let the Zig code walk the
records. A chain on disk may still need a few bounded batches in sequence, so
measure them before adding precomputed indexes. Long checks and listings
pause at a step budget through the executor. A latency target becomes a
release claim only once a recorded machine, build, dataset, durability
setting, and repeatable run back it.
