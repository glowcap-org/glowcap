---
id: ADR-0158
status: accepted
date: 2026-09-14
tags: [access, storage, resources]
decision: "Resource scope evaluation consumes one revision-checked record view, and structural resource metadata has a bounded versioned Syrup encoding."
supersedes: []
superseded_by: []
amends: [ADR-0153, ADR-0157]
amended_by: [ADR-0166]
---

# ADR-0158 managed access resource record views

## Context

The [storage plan](../../planning/loam/access/storage.md) requires a bounded working
set and one authority evaluator across resident and persistent execution.
Scope previously depended directly on the resident graph. Adding a database
adapter behind that dependency would either treat unloaded data as absent or
require another implementation of resource ancestry.

This slice establishes the data-only read boundary and first record grammar.
It does not implement the complete owner store, a cache, asynchronous loading,
or restoration of capability authority.

## Decision

Expose `ResourceView` through `glowcap.loam.access.core`. A view binds an owner and
resource revision, a maximum ancestry depth, and a synchronous record-source
function. A source returns a snapshot-stamped present record, known absence,
or unloaded state. Its only direct failure is `ReadFailed`; it cannot supply
an access decision or substitute an error for a typed unloaded response.
The embedding must keep the source alive and serialize calls with its state.

A canonical structural record contains resource identity, kind, and parent.
`Record.validate` checks generation and immediate parent shape. The view
checks the returned identity and snapshot before exposing a value. Row shape
and snapshot agreement cannot prove that a malicious storage adapter supplied
truthful data; the source is part of the trusted embedding.

`get` returns `RecordUnloaded` with an exact owner/revision/resource demand in
`missing`. Callers inspect that field only after that error. A new lookup clears
the old demand. Unknown and deleted records remain distinct from unloaded ones;
stale present, absent, and unloaded replies all refuse as `RevisionConflict`.
The demand is not an asynchronous completion receipt or an authority handle.
Owner incarnation, load coalescing, pin ownership, and late-completion matching
still belong to the pending storage-effect implementation.

`Scope` and `Terms` now consume this view. The resident graph exposes a view,
and its own ancestry operation uses the same traversal. Grant use, issuance,
and control-ceiling validation construct resident views before calling those
shared functions. No callback implements containment or permission algebra.
The ledger itself still retains all grant records and its resource graph.

Subtree traversal follows canonical parent edges with bounded work and no
allocation. A positive ancestor match still validates the remaining path to a
root; it cannot hide an unloaded or absent ancestor, a cycle, or excess depth.
Cycles longer than one edge exhaust the configured depth budget and refuse.
This costs a complete ancestry walk even when the selected subtree matches
near the target; it remains bounded by configured depth, not owner size.
Selected scopes continue to validate every member before returning coverage.

## Structural record grammar

Expose `glowcap.loam.access.records.ResourceRecord` with an explicit format version,
row revision, and canonical structural resource. The first grammar is:

```text
< 'access:resource 1 row-revision owner-bytes slot generation kind parent >
parent = false | [ owner-bytes slot generation ]
```

The notation abbreviates actual Syrup lengths and integer markers. Owners are
exactly 16 bytes in big-endian order. Slots fit unsigned 32 bits; generations,
kinds, and revisions fit unsigned 64 bits. Zero resource generations, foreign
parents, and immediate self-parenting refuse through shared record validation.
The row revision records a stored version; it does not establish which backend
snapshot supplied a later read. The record source must independently stamp that
snapshot. The codec does not publish a capability from decoded identifiers.

`encodeAlloc` produces one exact allocation, freed by its caller. `decode`
returns owned scalar values without allocation or retained byte borrows. A
192-byte input cap bounds the fixed grammar before parsing. Trailing bytes,
noncanonical integers, unsupported format versions, malformed lengths, and
out-of-range identities refuse. Parent depth and sibling indexes are derived
state and are not serialized. Content, lifecycle tombstones, grants, controls,
publications, and receipts still need their own record definitions.

The codec reuses Syrup's existing checked readers and scalar writers through
`RecordSyntax`. No protocol parser or CapTP message behavior changes. A new
`loam_access_records` build module imports `loam_access_core` and `syrup`, stays synchronous
and free of I/O, and is exposed through `access.records`. The authority core
continues to import neither codecs nor storage. Database execution remains an
optional adapter to implement separately.

## Evidence and remaining work

`test/loam/access/resource_view_test.zig` compares the same scope operations with
resident and forced-miss records. It checks stale snapshots, mixed-revision
traversals, missing/deleted distinctions, malformed identity/parent records,
bounded cycle refusal, full selection validation, and expired resident views.
The resident read and reparent path is checked with allocations disabled.
Temporarily removing snapshot validation made the stale-reply test fail;
returning early after a subtree match made the ancestry test fail. Both defects
were removed and the focused suite rerun.

`test/loam/access/resource_record_test.zig` pins root and parent golden encodings,
maximum scalar sizes, every truncated prefix, malformed/versioned input,
borrow-free decoding, exact allocation count, and allocation failure ownership.
These tests establish a resource read boundary and record format, not durable
application restoration. The next work adds grant/control records and shared
read evaluation, then owner effect/receipt lifetimes and the real backend.
