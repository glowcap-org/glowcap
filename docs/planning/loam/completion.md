# Loam completion queue

Status: active plan. This is a temporary, executable work queue for completing
Loam's Zig APIs and storage integration before its C ABI and Rust projection. The
[roadmap](../../roadmap.md) owns priority; the
[architecture checkpoint](architecture.md#readiness-before-the-c-abi)
owns the completion requirement. Existing design contracts remain authoritative.

## Scope and verified starting point

Source and test review used `570c472ac4288c6cb6360de18366d8d9fa53e302` on
Linux aarch64. The seven checkpoint areas describe integration breadth, not
seven absent subsystems. The portable store, LMDB backend, sleepy actors,
shared authority evaluator, durable grants, and fixed-resource managed calls
already work. Most remaining feature work broadens the managed application
surface; it does not require replacing the storage engine or actor runtime.

| Existing mechanism | Evidence to preserve and extend |
| --- | --- |
| Atomic records, exact totals, roots, cycles, bounded leases/cache, abort and uncertain-outcome recovery | [Core tests](../../../test/loam/core/), [LMDB storage tests](../../../test/loam/lmdb/storage_test.zig) |
| Sleep/wake, coalesced activation, local stored capability edges, commit-gated replies, held-reference retention and cancellation | [Actor tests](../../../test/loam/hosting/actors_test.zig), [CapTP delivery tests](../../../test/loam/hosting/wire_test.zig) |
| Resource creation, moves and leaf deletion in the resident graph | [Graph implementation](../../../src/loam/access/core/graph.zig), [graph tests](../../../test/loam/access/graph_test.zig) |
| Persistent resource creation, sparse owner indexes, shared grant evaluation, durable use/control descriptors, policy edits and pause/revoke | [Owner tests](../../../test/loam/access/owner_test.zig), [stored capability tests](../../../test/loam/access/stored_capability_test.zig) |
| Managed content calls and control edits through Host, including exact and dependent local reference disclosure, transactional field edits, cold restart and lost acknowledgements | [Managed LMDB tests](../../../test/loam/lmdb/managed_hosting_test.zig), [hosting tests](../../../test/loam/access/hosting_test.zig), [CapTP hosting tests](../../../test/loam/access/hosting_wire_test.zig) |
| Durable fixed-resource derivation with eight receipts per source, hidden publication reservation and exact retry recovery | [Sharing tests](../../../test/loam/access/sharing_test.zig), [LMDB sharing tests](../../../test/loam/lmdb/sharing_test.zig) |
| Scoped use inspection through the admission evaluator, including ancestor restrictions and inactive-status-only replies | [Description tests](../../../test/loam/access/description_test.zig) |
| Committed grant events and atomic content/grant/event writes | [Event tests](../../../test/loam/access/grant_events_test.zig), [LMDB owner tests](../../../test/loam/lmdb/owner_test.zig) |
| Tracing reclamation, explicit publication retirement, map growth and physical-size inspection | [Collection tests](../../../test/loam/core/collection_test.zig), [LMDB tests](../../../test/loam/lmdb/storage_test.zig), [publication code](../../../src/loam/hosting/publication.zig) |
| Actor/cache/wake-burst/collection measurements | [Workload and recorded results](../../../bench/loam/README.md) |
| macOS test execution is configured | [macOS CI job](../../../.github/workflows/check.yml); configuration alone is not a successful run |

The resident graph's moves and deletion need persistent integration, not a
second resource model. Existing actor benchmarks already cover hot/cold calls,
retained endpoints, cache pressure, wake bursts and collection interference.
Their missing dimensions are managed grants, sustained concurrent execution,
and whole-process memory. Source inspection identifies the missing contracts
below; a passing existing suite cannot prove those contracts implemented.

## How to consume this queue

Pick a ready item, read its linked implementation and owning contract, and
implement a complete Zig API and storage path. Preserve the shared evaluator, Store
transaction path, and Host/Vat custody. Do not add a second runtime, authority
engine, custom pager, prerelease migration reader, or compatibility alias.

Each item states a verified gap, dependencies, and a deletion criterion.
Dependencies refer to mechanisms: if an item has been removed, check its
implementation and tests instead of recreating it. Keep IDs stable while this
file exists. Independent items may proceed in another order.
Start with N03 or N10; both have independent entry points. Extend N11's
failure evidence and N12's workload coverage with each feature rather than
treating them as a final testing phase.

Remove an item in the same change that implements it, tests its failure paths,
documents ownership/cost, and updates affected contracts, `docs/loam.md`,
`docs/shipped.md`, and `docs/boundaries.md`. Remove completed dependencies from
remaining items. A narrower documented profile is a scope decision, not evidence
that the requested behavior shipped; do not close an item by merely documenting
its absence. Record such a decision with the maintainer before changing scope.

When no items remain, remove this file and its links from the roadmap,
architecture, and planning index. Keep durable contracts and evidence in their
owning documents. Do not turn this queue into a completed-work archive.

## Remaining implementation

### N01. Complete management authority and issuer-held child controls

**Verified gap:** [Control powers](../../../src/loam/access/core/control.zig)
admit edits, but [stored descriptors](../../../src/loam/access/records/capability_record.zig)
contain no independent control lifecycle or dependency chain. Trusted Zig API
creation can mint bounded controls. Hosted derivation returns only a use
capability, and `describe-access` describes use rather than management.

**Work:** Extend the shared management model with inspectable, attenuable,
independently revocable control authority. Let an authorized issuer retain and
recover a child's control separately from the use capability they share.
Commit issuance, control custody, publication recipes and receipt together.
Use possession alone must never recover the issuer's management capability.
Define how management dependencies behave when an ancestor changes or dies.

**Remove when:** Zig API and CapTP tests prove separate use/control custody,
management-ceiling enforcement, independent control revocation, scoped control
inspection, and exact recovery after a lost issuance reply and LMDB reopen.
Existing grant edits and eight-receipt derivation semantics remain covered.
Coordinate receipt storage with N07 and terminal control cleanup with N08.
The [access API](access/api.md) owns the public semantics.

### N03. Restore foreign and cross-vat capability fields

**Verified gap:** [Attachment.capture and restoreEdge](../../../src/loam/hosting/attachment.zig)
support one attachment/store. [Value copying](../../../src/loam/hosting/values.zig)
rejects reference/handoff request values; incoming durable calls currently take
plain data. Existing same-attachment strong edges already preserve local caps.

**Work:** Define and implement typed restoration recipes for exact held foreign
authority and local cross-vat dependencies. Obtain an actual durable reference
before committing a foreign field. Refuse live-only references that cannot be
saved. Establish retention before collection, retain bounded pending restoration
state, and route through existing Host networking. Local storage must work offline.
Decide and document the supported capability-bearing argument path through the
existing owned-value boundary; do not persist session export positions or pointers.

**Remove when:** Tests preserve original/use/control distinctions across restart,
restore vats in different orders, handle unavailable or revoked remote targets,
release replaced dependencies, and collect safely during restoration.
Unsupported reference kinds fail explicitly without partial content writes.
No cross-machine atomic transaction or snapshot of a live CapTP session is
required. Follow the [actor contract](actors.md) and [reference contract](access/storage.md#references-embedded-in-application-content).

### N05. Persist resource moves, deletion and bounded child queries

**Verified gap:** [Resident Graph](../../../src/loam/access/core/graph.zig)
implements reparenting and leaf deletion. Persistent access currently appends
resources and indexes them by identity; it has no staged move/delete or
parent-to-children listing API. An identity directory is not a child index.

**Depends on:** the implemented composed owner delta
([managed staging](../../../src/loam/access/storage/stage.zig);
[owner transaction tests](../../../test/loam/access/owner_test.zig)), which
already composes several owner changes, including resource appends, into one
header mutation.

**Work:** Share resource invariants with the resident model and add transactional
parent/child indexes. Preserve stable identities, refuse cycles and excessive
depth, and state leaf/subtree deletion behavior explicitly. Invalidate affected
scope facts when moving resources. Bound query work and filter before disclosing
items, counts or continuation information.

**Remove when:** LMDB reopen tests cover moves into and out of granted subtrees,
stale queued calls, cycle/depth refusal, deleted targets, child pagination under
mutation, hidden siblings, and rollback of every index/content participant.
Deleting content must not silently revoke unrelated references or implement a
Rooms-specific conversation operation. Follow [access storage](access/storage.md).

### N06. Retain and observe authorized changes

**Verified gap:** [OwnerRecord.change](../../../src/loam/access/records/owner_record.zig)
retains one latest event; [grant staging](../../../src/loam/access/storage/stage.zig)
replaces that edge. Committed events exist. Scoped retained history, observer
cursors and hosted subscriptions do not.

**Work:** Add bounded retained events and use/control observation with a
disclosure contract based on the existing scoped descriptions. Emit only after
commit, recheck current observation authority before delivery, and provide
explicit resynchronization when a cursor expires. Persist event intentions or
replay state needed by that contract; remote delivery must not hold a transaction.
Make subscription cancellation, revocation and retention costs explicit.

**Remove when:** Tests cover authorized live change delivery, replay after
disconnect/reopen, retention overflow, slow observers, ancestor revocation,
hidden sibling activity, and no event on abort or unchanged mutation.
Raw owner revisions and global event counters never become wire cursors.
Use N01 for control observation and the implemented composed owner delta for
multi-change events. General durable
mailboxes are separate work; see [access architecture](access/architecture.md).

### N07. Define bounded retries for other mutating methods

**Verified gap:** [Hosted sharing](../../../src/loam/access/hosting/sharing.zig)
has exact intent matching and eight retained receipts per source endpoint.
Control/content operations lack an equivalent caller retry contract. Backend
recovery resolves a submitted batch, but that alone cannot identify a new call
as a retry after its client lost the reply.

**Work:** Classify each mutation as explicitly idempotent, conditionally applied
against a version, or receipt-backed. Share bounded receipt mechanics where
required. Bind operation identity to the held source and exact intent, retain
the committed result, and define sequence ownership, conflicts and expiration.
Never present caller IDs alone as authority or retry expiration as a new request.

**Remove when:** Control edits and non-idempotent content/resource operations
have tested lost-reply behavior across reopen, conflicting intent is refused,
and old requests cannot remint capabilities or repeat effects after receipt
retirement. Replay checks current authority and preserves issuer control custody.
N01 and N05 use this contract; the [Loam API](api.md#atomic-mutations)
owns receipt semantics. No exactly-once network-delivery claim is required.

### N08. Retire managed owners, grants, controls and obsolete identities

**Verified gap:** Local tracing can collect unreachable records, but owner
resource/grant directories retain indexed rows. Revoked grants stay indexed;
persistent slots are never reused. There is no managed retirement operation
that updates all indexes, dependencies, publications and retained events.

**Depends on:** N01, N05, N06 and N07 for their retention contracts.

**Work:** Add bounded terminal-record and owner retirement. Distinguish revocation,
resource deletion, publication removal and physical collection. Preserve enough
dead-identity and receipt information to refuse obsolete authority without
retaining every terminal payload forever. A saved remote locator cannot report
its last release, so its active publication remains rooted until explicit retirement.

**Remove when:** Repeated create/share/revoke/delete cycles reclaim payload and
index storage, retained references preserve required records, and restart cannot
resurrect a grant or retarget a durable name. Test interrupted cleanup, stale
completions, expired receipts and owner retirement with outstanding work.
Measure remaining identity metadata. Extend existing tracing and publication
retirement rather than introduce another collector. See [cleanup contract](access/storage.md).

### N09. Compact and replace an LMDB store safely

**Verified gap:** [Lmdb](../../../src/loam/backends/lmdb/mod.zig) exposes open,
close, inspect and grow; it has no compact/copy/replacement operation. Collection
already makes LMDB pages reusable, but does not promise a smaller database file.

**Work:** Build an explicit maintenance operation using the physical engine's
supported mechanisms. Quiesce and join workers, preserve lifetime writer custody,
validate store identity and metadata, and make installation/recovery deterministic.
An offline, bounded-memory maintenance profile is sufficient; online compaction
is not an implicit requirement. State filesystem, synchronization, disk-headroom
and supported failure assumptions before claiming atomic replacement.

**Remove when:** Copy/install failures, insufficient space, process loss at
installation boundaries, and competing owners cannot select stale authority or
open two writers. The compacted store preserves records, roots, receipts,
retirement floors and exact totals. Validate Linux and macOS behavior through
N11; use N08's retirement metadata. Backups restored to an older authority state
need a separate rollback policy, not a claim that compaction solves rollback.

### N10. Restore durable publications on demand and own admission barriers

**Verified gap:** [publication.restore](../../../src/loam/hosting/publication.zig)
takes an already located descriptor and installs a Host entry, and startup
enumeration is application-owned. The administrative commit-to-registry
transition is now owned: staging a tombstone reserves bounded custody, the
attachment's write lane applies the discovery fence at the batch's terminal
outcome (fail closed on unknown outcomes), and recovery that proves the batch
absent re-publishes the still-rooted recipe
([retirement tests](../../../test/loam/hosting/wire_test.zig)). Managed
derivation already owns its reservation/activation barrier.

**Work:** Complete bounded lookup of stored publication recipes through the
existing Host/restoration boundary, so a restarted peer answers a fetch for an
unregistered stored publication without scanning or activating the graph.
Avoid eager endpoint creation for every stored publication: restore on demand
at fetch, with retirement races and simultaneous cold fetches preserving exact
target authority and bounded memory.

**Remove when:** A restarted peer fetches an unregistered stored publication
without scanning or activating the graph. Missing/retired names, simultaneous
cold fetches, unknown commit outcomes and retirement races preserve exact target
authority and bounded memory. Held references remain governed by their grant;
publication retirement only removes discovery. Include pressure/cancellation
and large cold-publication populations. Follow [actor identity](actors.md#identity-activation-and-retention)
and extend [Host publication custody](../../../src/driver/core/publish.zig).

## Remaining evidence

### N11. Verify the complete managed path under failure and on macOS

**Verified gap:** Existing process probes cover records, ordinary durable actors
and tracing. Managed LMDB tests simulate lost acknowledgements and reopen, but
do not kill a process through the complete managed issuance/control/event path.
The macOS CI job runs `test` and `loam-lmdb-test`; it omits the three process probes.
This review has Linux execution access, not new macOS execution results.

**Work:** Extend owning tests as N01–N10 land, rather than defer their failure
handling here. Add managed process probes around before-commit, after-commit,
publication installation and reply-loss boundaries. Cover allocation/read
refusal, cancellation, quotas, uncertain outcomes, late completions, shutdown
and release of every newly retained handle/buffer. Exercise LMDB maintenance
and writer custody on macOS, including process probes in its supported test job.

**Remove when:** The complete create/share/use/edit/observe/revoke/retire/
restart path has reproducible failure evidence on Linux and macOS. Record exact
revision, commands and results in the owning test or stability documentation.
Do not substitute cross-compilation or CI configuration for a successful run
on the target platform. Process-kill evidence establishes process-loss behavior;
state the selected
synchronous LMDB durability assumptions without claiming tested hardware power loss.

### N12. Measure managed workloads and sustained execution costs

**Verified gap:** The [Loam workload](../../../bench/loam/README.md) already
measures ordinary actor endpoint footprint, cache pressure, wake bursts and
foreground reads between collection batches. It excludes grants and subscriptions,
executes backend work synchronously, and excludes LMDB/OS residency from tracked
Zig heap. Those measurements must be retained, not repeated as new achievements.

**Work:** Extend the same workload with create/share/edit/revoke, cold grant and
resource ancestry, returned facets, observers and managed reclamation. Add a
bounded concurrent executor scenario with sustained arrivals and foreground
work during maintenance. Measure full-process memory separately from mapped
address space, retained Zig memory, encoded bytes and physical pages. Account
for startup publication metadata and dead-identity/event/receipt retention.

**Remove when:** Reproducible reports record revision, platform, durability,
population, limits, allocation/read counts, throughput and latency distributions.
Establish supported working sets and overload behavior; fix unexplained growth,
starvation or authority-dependent full-graph scans. Preserve structural budgets
in smoke tests without adding machine-dependent timing assertions. Extend as
features land; final coverage depends on N01–N10. The 500k live-session proof is
a separate whole-system experiment, not a condition for closing this item.

## Verification and boundaries

For Zig code, use `zig build check` and the relevant protocol reference
fixtures (`zig build oracle-check`). `check` includes LMDB tests and the
small Loam workload. The existing process steps are `loam-lmdb-crash-test`,
`loam-actors-crash-test`, and `loam-collection-crash-test`; additions belong in
the owning process checks and `runtime-check`. Plans alone require
`zig build source-check`. Follow the repository's build front when running them.

Baseline verification passed on Linux aarch64 on September 15, 2026, at the
revision above. The command was run through the repository build front:

```sh
zig build check oracle-check loam-lmdb-crash-test loam-actors-crash-test loam-collection-crash-test --summary failures
```

This includes the existing managed LMDB tests and workload smoke checks.
It establishes a passing starting point, not evidence for unimplemented items.
No new macOS execution or hardware power-loss experiment was performed here.

Browser storage, C/Rust projection, Rooms content/UX adoption, alternative backend
comparisons, and the 500k socket experiment remain in the roadmap and broader
designs. They are not hidden tasks in this queue. Durable general-purpose
inboxes/outboxes, timers, unresolved promises and operating-system handles also exceed the
record-backed actor profile. N03 covers durable capability fields and N06 covers
scoped change replay; neither promises transparent persistence of all execution
state. Plain networking continues to need no Loam or managed-resource allocation.
