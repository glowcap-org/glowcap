---
id: ADR-0157
status: accepted
date: 2026-09-14
tags: [access, storage, performance]
decision: "managed access participates in Loam transactions that preserve content and exact capability authority together, with bounded residency and existing Host and executor mechanisms."
supersedes: []
superseded_by: []
amends: [ADR-0153, ADR-0155, ADR-0156]
amended_by: [ADR-0158, ADR-0159, ADR-0161]
---

# ADR-0157 managed access storage and residency

## Context

The native graph and ledger reserve their full record capacity in memory.
Prepared grant writes already reserve scope and handle uncertain completion.
Native use and control references carry authority over committed grants. Those
primitives do not store application content atomically, restore exact controls
and publications, or support a dataset larger than resident record capacity.
Persistence and cache ownership shape the next API, so they come before hosted
consumers depend on that representation.

## Decision

Adopt the [storage, calls, and performance contract](../../loam/access-storage.md)
as the implementation sequence before hosted Rooms integration. It owns the
record families, backend effects, buffer lifetimes, cold-call behavior,
reclamation rules, and measurement matrix without duplicating them here.

Managed access supplies managed-resource semantics over Loam's capability-bearing graph.
Loam owns shared persistence and bounded residency. Stored references are
first-class values whose authority and retention edges participate with their
containing content. Scoped queries disclose only results and references allowed
through the held capability. The storage contract includes these behaviors as
required observable properties.

The persistent owner commits content, resource/grant/control state,
publication recipes, receipts, and events together. Native backend selection
is reopened by [ADR-0159](ADR-0159-memory-and-persistence-research.md): compare
SQLite and LMDB before selecting the native profile. IndexedDB remains the
Rooms browser candidate. Applications
can supply another backend only by satisfying the same atomicity, revision,
and completion contract. A backend executes Loam batches containing managed access changes. It does not
reimplement scope, grant mutation, or recovery policy.

Keep `access/core` synchronous and free of I/O. A common record view serves both
resident and persistent execution. Missing records yield bounded storage
effects. Optional storage adapters execute those effects through the
embedding's existing executor. Use the existing actors, Host, deferred
answers, and capability custody for hosted calls. Extend the public Host
publication seam only where capacity reservation or deferred durable lookup
requires it. Do not create a managed access scheduler or export table. Physical engine
ownership and selection follow the comparative research in ADR-0159.

Bound resident records separately from durable records. Live endpoints retain
identity and owner custody. Active operations pin their working sets. Warm
scalar evaluation performs no storage request or managed access heap allocation.
Mutations write bounded deltas and perform allocation-free installation after
durable success. Cold operations resume against checked revisions. Stale rows
cannot reintroduce revoked authority.

Durable capability restoration preserves the exact original, use grant, or
control represented by the publication. Native pointer layouts and live CapTP
session tables are not storage formats. Record control authority explicitly.
Restoring a target grant alone cannot reconstruct its former controller's
limits. Record and publication reclamation must retain enough identity state
to refuse obsolete references and expired retries.

## Consequences

The current array-only representation is replaceable before prerelease. Its
semantics stay under existing tests while storage misses and resumable work
enter the same evaluator. No second Rust model or compatibility path is kept for
an unreleased representation.

The optional native adapter introduces a database dependency only for its
consumers. Browsers keep their own storage execution boundary. A real backend,
crash/restart proof, and bounded-cache workloads are prerequisites to claiming
application persistence. Mocked storage completions cannot establish them.

The design reserves publication capacity before committing issuance and keeps
receipts for interrupted publication. These remain implementation requirements,
not features delivered by the current native reference factory. Limits and
latency claims must be measured with durability settings and backend memory
included in the reported workload.

## Verification and current state

This decision and its linked plan change documentation only. Validate their
links, ADR relationships, and planning inventory with `zig build source-check`.
The plan specifies fault injections and native/browser evidence required for
each implementation stage. No persistence, cold-call, or performance result is
claimed by accepting this decision.
