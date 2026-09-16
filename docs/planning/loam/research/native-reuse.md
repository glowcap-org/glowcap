# Native persistence: reuse and ownership

Status: active plan and source review, dated 2026-09-14. The
[roadmap](../../../roadmap.md#durable-applications) owns priority. This review answers
the build-or-adapt question in the
[memory and persistence plan](memory-persistence.md).
The [planning guide](../../README.md) locates the resulting design contracts.
This review supports their build-or-adapt direction; it does not select a
production backend or establish comparative performance.

The [native implementation](../../../loam.md) exercises this direction with
local records and LMDB. Capability/actor integration and comparative measurement
remain open; the source findings below retain their stated review scope.

## Recommendation for glowcap

Build the shared Zig object-and-capability persistence layer over an existing
transactional engine. Measure the implemented LMDB path first; retain SQLite as
an optional comparison when the workload identifies an engine constraint.
Loam supplies that foundation with managed access as its included resource, grant, and
lifecycle extension. The [architecture](../architecture.md) owns placement. Integrate durable
activation with the existing actors, Vat, and Host.

Do not adopt Blackrock or POST++ wholesale, and do not begin with a custom
pager, allocator-backed database, journal, or distributed storage service.
Their useful mechanisms deserve explicit reuse in the design. The evidence
below identifies which mechanisms are implemented and what adaptation would
cost. Existing glowcap and Rooms persistence remains the starting inventory.

This recommendation follows the [project vision](../../../vision.md): portable
semantics, visible memory ownership, ordinary capability APIs, and replaceable
I/O adapters. A persistence runtime with different scheduling, reference, or
heap rules would export substantial complexity into the C ABI and bindings.
The 500,000-session target also makes optional persistence and bounded residency
important: opening a session must not load an application's durable graph.

The work above the engine is substantial. It includes reference retention,
activation, schema evolution, crash outcomes, and authority-safe restoration.
Building it is justified by its integration with glowcap's existing model.
There is no evidence here that writing a new physical database would improve
that fit, or that a glowcap implementation would outperform Goblins.

## Evidence and limits

The review inspected these exact sources:

| Project | Source identity | Verification performed |
| --- | --- | --- |
| [Blackrock](https://github.com/sandstorm-io/blackrock/tree/4e8da53f181b7b239c7096e449535fb9890b4e5d) | Revision `4e8da53f181b7b239c7096e449535fb9890b4e5d`; commit dated 2020-02-01. | Read schemas, filesystem implementation, journal, factory, reference restoration, build rules, and storage tests. No build or runtime test. |
| [POST++](https://github.com/knizhnik/POST--/tree/70f6479288b18870f3ba24739b4d11205c8ee3b3) | Revision `70f6479288b18870f3ba24739b4d11205c8ee3b3`; commit dated 2009-11-23. | Read storage, class descriptors, Unix transaction implementation, and C API. Built the library and exercised a small C client. |
| [Guile Goblins 0.18.0](https://files.spritely.institute/releases/guile-goblins/guile-goblins-0.18.0.tar.gz) | Released archive; SHA-256 `2ab81640e57d3e97e84a2d0a7310eb65dcf1475003f4f383a527e1ca5100453e`. | Read actor portraits, waking, vat persistence ordering, Syrup store, and Bloblin store. No comparative benchmark or crash test. |

The two GitHub revisions were their default-branch heads when checked. Neither
repository was marked archived. Those dates describe the inspected repositories;
they do not prove that development, descendants, or support ceased everywhere.
Blackrock includes an Apache-2.0 license. POST++'s README grants broad use and
distribution permission; GitHub's missing license classification is not evidence
that permission is absent. No third-party implementation is imported here.

POST++ built unmodified on Linux with Debian GCC/G++ 14.2.0 using
`make -j2 libstorage.a`. Compilation emitted warnings, including strict-aliasing
and possible uninitialized reads in reference-fixup code. These require review
before adoption; a successful build does not settle their correctness.

The temporary C client used the shipped C API and transaction-log mode. It
allocated a root containing 42, committed, changed it to 99, rolled back,
checked 42, and closed. A fresh process reopened the file and checked 42 again.
Both executions succeeded. This establishes basic C interoperability and that
particular commit/rollback/reopen path. It tests neither pointer relocation,
crash durability, concurrent access, nor capability restoration.

## Blackrock: the closest capability-storage precedent

Blackrock's [storage interfaces][blackrock-schema] describe capability-bearing
values, blobs, block volumes, assignable values, ownership, weak persistent
references, and storage accounting. This is substantive native prior art above
a byte store. Its filesystem implementation actually converts embedded
capabilities into stored descriptors and reconstructs them when reading values.

The implementation's `saveCap` distinguishes owned local storage from external
capabilities. Local children receive stored keys; external capabilities use a
persistent save operation. `restoreCap` opens local children through the object
factory or invokes an external restorer. Failed restoration produces a broken
capability. These mechanisms directly inform glowcap's typed reference fields
and explicit foreign-reference persistence contract. [Source][blackrock-impl]

The object factory opens a file and constructs the appropriate storage object
on a cache miss. Dropping an object removes its cache entry. That supplies
on-demand storage objects, but it does not establish bounded eviction of actor
behavior while callers continue holding live references. Glowcap still needs
the sleepy-actor identity/residency separation in its existing Vat.

### Implementation boundaries

The inspected factory implements blobs, upload streams, volumes, and assignable
values. Immutable values, collections, and opaque objects are absent from its
restore switch. The schema's general transaction factory is not implemented
by this factory. Internal journal transactions do exist; they are a different
surface from the general application transaction interface. [Source][blackrock-impl]

Ownership is deliberately constrained. `AdoptionIntent` accepts an orphan and
commits adoption of newly created objects. General ownership transfer is marked
as future work in that implementation. The root-set schema also documents that
overriding an existing named root is not atomic. Those limitations matter for
Rooms moves and content-plus-grant transactions; interface declarations cannot
stand in for the missing implementation. [Interfaces][blackrock-schema]

Transitive block accounting follows the single-owner tree. Volume accounting
updates periodically rather than after every block mutation. This is a useful
charging model, not proof that arbitrary shared capability graphs have exact,
constant-cost reachable-size queries. The ownership tree and the authority
graph answer different questions. [Accounting implementation][blackrock-impl]

### Adaptation cost

The storage class accepts KJ event/timer objects and a Cap'n Proto restorer.
Its implementation uses Cap'n Proto capability hooks, Unix file descriptors,
filesystem metadata, and a journal with its own sync thread and completion
signals. The [build rules][blackrock-build] augment Sandstorm's build. Extracting
the storage class need not import the whole MongoDB-backed frontend, but it
still requires separating these runtime and persistence dependencies.

The journal contains real recovery machinery: batched operations, sync
completion, and replay. Replacing it with LMDB while also replacing capability
hooks, restorers, and runtime integration would preserve less implementation
than the project's surface resemblance suggests. Keeping it would make glowcap
maintain another physical recovery mechanism before demonstrating a need.

Blackrock is therefore a design reference and a possible source of carefully
isolated reusable code. It is not currently an evidenced drop-in persistence
library for glowcap. Its tests cover reload, ownership deletion, and blob
streaming; this review read those tests without executing them.

## POST++: persistent native heaps are real

POST++ supplies mapped allocation, persistent roots, reference fixups, class
registration, optional mark/sweep collection, and transactional page updates.
Its [class machinery][post-classes] describes pointer fields explicitly and uses
constructors to restore native object layout, including virtual dispatch.
This is a working example of substantial native machinery beyond LMDB's model.

The persistence representation follows native object layout. Class names and
sizes are checked during storage opening in the checked build. Reference
adjustment can traverse stored objects when relocation or reconstruction is
required. An OS demand-paged mapping consequently does not guarantee that
opening the graph touches only the application's immediate working set.
[Storage implementation][post-storage]

The [C API][post-c-api] is especially instructive. It exists and worked in the
smoke test, but `post_open` explicitly enables the fixed-address flag. It exposes
raw allocation and root pointers without the C++ pointer-field registration
surface. Generalizing the C API to relocatable typed Zig/Rust graphs would need
additional metadata and integration. The broader C++ implementation does support
reference adjustment; fixed addressing is not a limitation of every POST++ mode.

The Unix transaction implementation uses memory protection and fault handling
to capture before-write pages. It includes log synchronization, locked-page
handling, mapped-data synchronization, rollback, and reprotection. Those effects
belong to its process memory model. They cannot be carried unchanged into
glowcap's synchronous core or a browser adapter. [File implementation][post-file]

Adopting POST++ would commit glowcap to substantial heap-layout and process
integration work while leaving capability custody, CapTP restoration, grant
checks, and actor activation to implement. Explicit field descriptions and
separate roots are useful precedents. A native-pointer heap is not the default
shared representation for the portable product.

## Goblins: a concrete semantic and storage baseline

Goblins supplies the most directly relevant actor behavior. Its
[sleepy-actor contract](https://files.spritely.institute/docs/guile-goblins/0.18.0/Sleepy-actors.html)
retains callable references while behavior sleeps and reconstructs it on use.
Portraits separate behavior reconstruction from persisted data and references.
Glowcap should preserve those useful semantics wherever its explicit residency
and calling contracts permit them.

The released source adds three important qualifications to comparisons:

- In `goblins/persistence-store/bloblin.scm`, generations store changed portraits
  and indexes identify relevant generations. The `object-portrait` path calls
  a generation reconstruction routine before selecting the requested portrait.
  Its latest-generation routine gathers the current portraits across relevant
  generations. Direct per-object indexed retrieval is therefore a concrete
  alternative to measure, not evidence of a measured glowcap advantage.
- Bloblin's write path calls `force-output`; the inspected Bloblin and Syrup
  store paths do not explicitly call `fsync` or `fdatasync`. Guile documents
  [port flushing and descriptor synchronization](https://www.gnu.org/software/guile/manual/html_node/Ports-and-File-Descriptors.html)
  as distinct operations. Power-loss durability comparisons must specify the
  actual flush contract and storage configuration.
- In `goblins/vat.scm`, far messages are dispatched before
  `vat-maybe-persist-changed-objs!`. This path does not demonstrate a durable
  outbox or commit-before-external-publication contract. Glowcap must establish
  its intended ordering with recovery tests, rather than attribute it to a
  precedent that has a different contract.

These are findings about the pinned release's inspected paths. They neither
establish defects under Goblins' intended contract nor measure throughput,
latency, memory use, or a newer implementation.

## Applying the evidence to Loam

The [Loam architecture](../architecture.md#product-and-ownership) owns the
resulting responsibility split. The reuse recommendation rests on the following
storage, lifetime, and authority constraints.

LMDB's key/value layout can represent the graph through object records, typed
edge records, roots, and indexes committed within one environment transaction.
It does not require object pointers to be persisted. The
[LMDB C contract](https://git.openldap.org/openldap/openldap/-/blob/mdb.master/libraries/liblmdb/lmdb.h)
also makes the costs explicit: one writer, reader snapshots, and values borrowed
for transaction-limited lifetimes. Long-lived readers retain old pages.

A CapTP capability can expose operations backed by a read transaction, but a
raw transaction pointer is neither a wire representation nor a restart recipe.
The hosting object must own that transaction's lifetime, authority, and limits.
An arbitrarily long-lived remote reference should not silently pin an LMDB
reader. Durable snapshot capabilities need an explicit retained-version design;
ordinary references resolve current records through bounded transactions.

Trusted native code still shares the process address space. Passing an opaque
handle provides a capability API under that embedding's trust assumptions;
neither mmap nor a Zig allocator isolates malicious unsafe code. CapTP protects
remote reference use through the existing protocol boundary. Storage offsets
remain internal, and restoration must preserve the exact saved facet.

Keep three graphs distinct: content placement, authority/delegation, and storage
retention. Shared edges and cycles prevent summing child sizes without double
counting. Define charged bytes per storage owner, resident and pinned bytes,
and any requested reachable-size query separately. A useful product may offer
exact ownership totals and explicitly costed reachability queries.

## Implementation decision and falsification

The next experiment should carry one small graph through ordinary records,
a sleepy actor, and a mutable managed access facet. Use the shared C ABI from Rust as well
as native Zig. Exercise a browser adapter before freezing the execution API.
This proves the proposed shared layer without starting a new application stack.

The first native path should use LMDB and the existing glowcap ownership seams.
First measure the shared mechanism with Rooms-shaped native workloads. Compare
SQLite only when a measured constraint warrants a backend experiment, using
the same transactions, synchronization, data shape, and memory limits. Packed regions remain
a layout experiment over a mature commit mechanism. They become a custom engine
only if measured constraints justify taking ownership of physical recovery.

The [main experiment plan](memory-persistence.md#experiment-sequence-and-decision-points)
owns the full workload. The build-or-adapt decision requires these observations:

1. Cold activation reads bounded metadata and the required records without
   reconstructing the whole graph. Concurrent calls to one cold actor share one
   activation; unrelated targets remain able to progress.
2. A content change and a grant change commit together. Crash injection around
   commit and installation cannot restore wider authority or publish success
   for a change lost under the selected durability contract.
3. Eviction, deletion, and revocation remain distinct. Restoring a saved facet
   preserves its attenuation; old content snapshots cannot bypass current
   managed authority. Durable roots and cycles have tested reclamation rules.
4. The C ABI and browser executor reuse the shared activation and recovery
   decisions. If either needs a parallel state machine, revise the shared API
   before extending consumers.
5. Measure allocated, resident, pinned, and dirty bytes; startup and cold-call
   latency; bytes read and written; commit latency; and retained snapshot growth.
   State the workload and durability setting with every result.

Reconsider adaptation if a concrete library extraction preserves most of a
candidate's tested implementation while meeting those boundaries. Reconsider
the physical engine if measurement locates the limiting cost in that engine,
after separating encoding, retained readers, layout, and scheduling costs.
If the shared design requires universal VM persistence or a replacement Vat,
reduce its scope to typed records and explicit behavior reconstruction.

The defensible opportunity is an integrated native library: capability-bearing
data, bounded lazy residency, and durable actor/resource semantics behind one
portable API. Its component ideas have extensive prior art. The integration
and its measured behavior are the contribution glowcap must actually prove.

[blackrock-schema]: https://github.com/sandstorm-io/blackrock/blob/4e8da53f181b7b239c7096e449535fb9890b4e5d/src/blackrock/storage.capnp
[blackrock-impl]: https://github.com/sandstorm-io/blackrock/blob/4e8da53f181b7b239c7096e449535fb9890b4e5d/src/blackrock/fs-storage.c%2B%2B
[blackrock-build]: https://github.com/sandstorm-io/blackrock/blob/4e8da53f181b7b239c7096e449535fb9890b4e5d/Makefile
[post-classes]: https://github.com/knizhnik/POST--/blob/70f6479288b18870f3ba24739b4d11205c8ee3b3/classinfo.h
[post-storage]: https://github.com/knizhnik/POST--/blob/70f6479288b18870f3ba24739b4d11205c8ee3b3/storage.cxx
[post-c-api]: https://github.com/knizhnik/POST--/blob/70f6479288b18870f3ba24739b4d11205c8ee3b3/post_c_api.cxx
[post-file]: https://github.com/knizhnik/POST--/blob/70f6479288b18870f3ba24739b4d11205c8ee3b3/file.cxx
