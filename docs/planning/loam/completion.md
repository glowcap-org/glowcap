# Loam completion queue

Status: active plan. Only maintainer-owned macOS acceptance remains.
The implemented Zig contracts and
Linux checkpoint, C/Rust lifecycle and browser lifecycle have evidence. That
checkpoint establishes behavior, not the absence of avoidable work. This queue
also retains the macOS evidence required for Loam's LMDB support claims.
The [execution order](#execution-order) below owns priority within this queue.
The [roadmap](../../roadmap.md) places it among project work; the
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
| Managed content calls and control edits through Host, including exact and dependent local reference disclosure, transactional field edits, cold restart and lost acknowledgements | [Managed LMDB tests](../../../test/loam/lmdb/managed_hosting_test.zig), [process-loss proof](../../../test/loam_managed_crash.zig), [hosting tests](../../../test/loam/access/hosting_test.zig), [CapTP hosting tests](../../../test/loam/access/hosting_wire_test.zig) |
| Durable fixed-resource derivation with eight receipts per source, hidden publication reservation and exact retry recovery | [Sharing tests](../../../test/loam/access/sharing_test.zig), [LMDB sharing tests](../../../test/loam/lmdb/sharing_test.zig) |
| Scoped use inspection through the admission evaluator, including ancestor restrictions and inactive-status-only replies | [Description tests](../../../test/loam/access/description_test.zig) |
| Committed grant events and atomic content/grant/event writes | [Event tests](../../../test/loam/access/grant_events_test.zig), [LMDB owner tests](../../../test/loam/lmdb/owner_test.zig) |
| Bounded cold publication discovery, atomic name index, retirement barriers and restart without enumeration | [Discovery tests](../../../test/loam/hosting/discovery_test.zig), [process restart probe](../../../test/loam_actors_crash.zig), [ADR-0176](../../decisions/adr/ADR-0176-on-demand-durable-publication-discovery.md) |
| Tracing reclamation, explicit publication retirement, map growth, physical-size inspection and offline compaction | [Collection tests](../../../test/loam/core/collection_test.zig), [LMDB tests](../../../test/loam/lmdb/storage_test.zig), [compaction tests](../../../test/loam/lmdb/compaction_test.zig), [publication code](../../../src/loam/hosting/publication.zig) |
| Actor and managed lifecycle/ancestry measurements, bounded worker execution and process memory | [Workload method and recorded results](../../../bench/loam/README.md) |
| macOS test execution is configured | [macOS CI job](../../../.github/workflows/check.yml); configuration alone is not a successful run |

Persistent moves and leaf deletion now share the resident resource invariants.
[LMDB resource proofs](../../../test/loam/lmdb/resource_lifecycle_test.zig)
cover their index, scope, recovery and reopen behavior. Existing actor benchmarks already cover hot/cold calls,
retained endpoints, cache pressure, wake bursts and collection interference.
The [LMDB workload](../../../bench/loam/README.md) records the implemented
working sets, cost and overload evidence. The remaining obligations cover target-platform acceptance.
Passing Linux checks cannot establish macOS behavior.

## How to consume this queue

Pick a ready item, read its linked implementation and owning contract, and
implement a complete Zig API and storage path. Preserve the shared evaluator, Store
transaction path, and Host/Vat custody. Do not add a second runtime, authority
engine, custom pager, prerelease migration reader, or compatibility alias.

Each item states a verified gap, dependencies, and a deletion criterion.
Dependencies refer to mechanisms: if an item has been removed, check its
implementation and tests instead of recreating it. Keep IDs stable while this
file exists. Follow the execution order below, checking the required mechanisms
at the start of each item. Extend the owning failure and workload evidence
with each feature rather than treating them as a final testing phase.

Follow the [planning completion definition](../README.md#definition-of-complete),
including verified integration into `dev`.
Remove an item in the same change that implements it, tests its failure paths,
documents ownership/cost, and updates affected contracts, `docs/loam.md`,
`docs/shipped.md`, and `docs/boundaries.md`. Remove completed dependencies from
remaining items. A narrower documented profile is a scope decision, not evidence
that the requested behavior shipped; do not close an item by merely documenting
its absence. Record such a decision with the maintainer before changing scope.

When no items remain, remove this file and its links from the roadmap,
architecture, and planning index. Keep durable contracts and evidence in their
owning documents. Do not turn this queue into a completed-work archive.

## Execution order

The maintainer owns the remaining macOS acceptance. Typed
local and foreign capability fields are implemented in the
[reference guide](../../loam/references.md).
Scoped observation, shared mutation receipts, persistent resource lifecycle,
independent management custody and bounded terminal retirement are implemented
in the [usage guide](../../loam/access.md), with Linux evidence for those
contracts. The maintainer-owned macOS run remains required for
closing this queue and claiming the completed profile on that target. It is
not a scheduling prerequisite for consumer work under the current ownership split.
Agent work resumes [Rooms integration](../README.md#priority-and-readiness).

| Owner | Work | Required mechanisms and readiness |
| --- | --- | --- |
| Maintainer | [N09/N11: macOS acceptance](#n09-compact-and-replace-an-lmdb-store-safely) | Offline replacement, final reference preservation and Linux failure tests pass. The maintainer owns macOS execution. |

Failure and cost evidence accompany every feature. Extend the existing
process-loss proofs and workload budgets in each implementation change. Current coverage includes
receipt-backed content edits, issuer control recovery, control attenuation,
resource moves, deletion, observation registration and cancellation, owner
closure and publication-bearing cleanup. Management-chain and resource-query workloads run
alongside the existing managed population. macOS configuration remains separate
from successful execution; final platform evidence covers the completed profile.

Compaction is required by the
[readiness checkpoint](architecture.md#readiness-before-the-c-abi).
An alternative database comparison depends on measured engine constraints.
The implemented Zig contract checkpoint has Linux evidence. The first C/Rust
and browser profiles are proved; Rooms follows in the planning order while
the maintainer supplies macOS evidence. Those consumers do not close or block this queue.

## Remaining acceptance

### N09. Compact and replace an LMDB store safely

**Implemented, acceptance pending:** [Lmdb](../../../src/loam/backends/lmdb/mod.zig)
exposes offline `compact` and an owned `beginCompaction` operation.
[LMDB tests](../../../test/loam/lmdb/compaction_test.zig) prove continuous
custody, smaller files, exact metadata, cancellation, rename refusal and final
sync retry. Managed retirement and terminal receipt replay survive compaction
and cold reopen. The [process proof](../../../test/loam/lmdb/compaction_crash_test.py)
covers every public phase, a real file-size limit, competing owners, invalid
leftovers and relative-path opening followed by a working-directory change.
Linux execution is verified. The [reference preservation test](../../../test/loam/lmdb/reference_test.zig)
compacts both stores and restores original/use/control roles with the source
vat starting first. Successful macOS execution remains required before removing this item.

**Work:** The maintainer owns the same native and process checks on macOS
through N11.
[ADR-0181](../../decisions/adr/ADR-0181-offline-lmdb-replacement.md) owns the
offline maintenance contract and its filesystem, synchronization, disk-headroom
and failure assumptions. The operation compares every key/value before
installation and needs no application schema-specific copier.

**Remove when:** Copy/install failures, insufficient space, process loss at
installation boundaries, and competing owners cannot select stale authority or
open two writers. The compacted store preserves records, roots, receipts,
retirement floors and exact totals. Validate Linux and macOS behavior through
N11; preserve implemented owner, endpoint and name retirement metadata. Backups restored to an older authority state
need a separate rollback policy, not a claim that compaction solves rollback.

## Remaining evidence

### N11. Verify the complete managed path under failure and on macOS

**Verified gap:** Process probes cover records, ordinary durable actors,
tracing, and managed issuance, attenuation, revocation, content/reference
edits, moves, leaf deletion, observation registration and cancellation, owner
closure and publication-bearing cleanup.
The [managed proof](../../../test/loam_managed_crash.zig) kills writers before
commit, after commit, after local installation, and after publication activation
with an undelivered reply. Fresh processes check atomic events, exact issuance
and mutation retries, issuer control custody, role separation, cold name
discovery, persisted observation cursors, retired names and exact maintenance
progress. The compaction probe tests installation boundaries, copy capacity
refusal and uninterrupted writer custody. The macOS job includes these
process probes, but configuration is not a successful target-platform run.
Linux results do not establish macOS behavior. Target-platform execution must
cover the completed native profile, including durable foreign fields.

**Work:** Extend owning tests with each implementation item, including its
failure handling. Preserve the existing 48-case managed process proof, including owner closure
and publication-bearing cleanup. The nine-case foreign-field process proof
covers original/use/control roles at commit and installation boundaries. Cover allocation/read
refusal, cancellation, quotas, uncertain outcomes, late completions, shutdown
and release of every newly retained handle/buffer. Exercise LMDB maintenance
and writer custody on macOS through its supported test job.

**Remove when:** The complete create/share/use/edit/observe/revoke/retire/
restart path has reproducible failure evidence on Linux and macOS. Record exact
revision, commands and results in the owning test or stability documentation.
Do not substitute cross-compilation or CI configuration for a successful run
on the target platform. Process-kill evidence establishes process-loss behavior;
state the selected
synchronous LMDB durability assumptions without claiming tested hardware power loss.

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

Broader C/Rust projections, Rooms content/UX adoption, alternative backend
comparisons, and the 500k socket experiment remain in the roadmap and broader
designs. They are not hidden tasks in this queue. Durable general-purpose
inboxes/outboxes, timers, unresolved promises and operating-system handles also exceed the
record-backed actor profile. Implemented durable capability fields and scoped
observation cover restoration and change replay. Neither promises transparent
persistence of all execution state. Plain networking continues to need no Loam or managed-resource allocation.
