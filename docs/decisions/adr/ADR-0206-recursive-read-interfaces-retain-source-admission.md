---
id: ADR-0206
status: accepted
date: 2026-10-06
tags: [loam, hosting, capabilities, admission]
decision: "Trusted read declarations mediate recursive returned capabilities under the original source intent and exact upstream target."
supersedes: []
superseded_by: []
amends: []
amended_by: []
---

# ADR-0206 Recursive read interfaces retain source admission

## Decision

A managed read callback can disclose an exact target through a shared
`hosting.ReadScope`. Trusted content declares each permitted read verb and
the interface of every capability occurrence in its reply. The declaration
uses depth-first Value traversal order and can refer recursively to its own
interfaces. Empty result declarations forbid capabilities. Missing or extra
occurrences refuse the complete reply before outward delivery.

The scope copies the admitted source intent and declarations before any
upstream wait. It retains the actual source and every capability in that
intent. Each facade retains its exact upstream target and rechecks the
original source intent before forwarding. The upstream object independently
authorizes the requested call. Completion rechecks source admission before
recursively replacing result capabilities with restricted facades.

One weak cache entry names each exact target and interface within the scope.
Repeated occurrences preserve identity; different interfaces remain distinct.
Endpoint destruction releases its target, clears the entry and releases its
scope occurrence. A returned child can outlive its parent. In-flight calls
independently retain their declaration, so endpoint retirement cannot remove
the projection needed by their completion.

Temporary resolver refusal keeps the immutable upstream result. Retry checks
current source admission and projects that original result again; it never
redispatches or wraps an already projected reply. Container spines copy into
the call allowance. Scalar leaves borrow immutable result custody until
ordinary outward reply retention transfers them.

Each retry discards its prior admission preparation. Application lifetime can
change without a storage revision, so an unchanged snapshot cannot cache it.

Scope count, backing bytes and target capacity use the existing continuation
allowances. `ReadScope.sizeBound` derives the scope's physical demand from
intent topology and declaration counts. Host actor and registry storage,
retained calls, resolver preparation and C/Rust declaration projections keep
their existing separate owners. Allocation refusal releases constructor
custody before an immediate retry can reuse its cache entry.

## Trust and application use

These declarations belong to trusted content, which must register only read
operations. The shared managed callback refuses disclosure from a mutation
callback. Arbitrary actor method semantics cannot be inferred from their
names. Capability occurrence declarations restrict returned interfaces; they
do not validate the application's complete reply grammar.

Rooms exposes this boundary through `archive-reader`, selecting a checked
ArchiveAccess field once. History is required for the archive interface;
the file-enabled interface additionally requires ReadFile. Narrowed archives
retain the archive interface; attachments and blobs expose only read. Every
chunk therefore checks the same session source and actual upstream authority.
Session lifetime checks run during source admission, including forwarding and
post-wait disclosure; private receipt settlement remains available on shutdown.
Upstream archive constraints remain authoritative for conversation identity,
generation and history floors. Production consumers use this boundary through the
[managed session](../../rooms/session.md).

## Evidence

Shared Zig scenarios cover recursive identity, separate interface roles,
child lifetime, undeclared methods and results, source loss during waits,
independent managed upstream denial, physical sizing and constructor refusal.
A foreign-result scenario exercises immutable reply custody and settlement
retry without redispatch. A hosted wire proof closes source admission between
settlement attempts without editing storage and requires refusal. The C/Rust
Rooms proof exercises the same shared
owner through managed archive and blob calls on LMDB and IndexedDB.
