---
id: ADR-0155
status: accepted
date: 2026-09-14
tags: [access, grants, transactions]
decision: "managed access prepares bounded grant deltas under graph reservations, commits them only on matching completion, and fences protected access after an uncertain write outcome."
supersedes: []
superseded_by: []
amends: [ADR-0153, ADR-0154]
amended_by: [ADR-0156, ADR-0157, ADR-0166]
---

# ADR-0155 managed access prepared grant writes

## Context

The [grant model](ADR-0154-access-local-grant-lifecycle.md) validates ceilings,
ancestor restrictions, and lifecycle changes. Its original mutation methods
installed state and returned events immediately. Storage-backed access needs
those decisions to remain valid across an asynchronous write without exposing
uncommitted authority or recomputing policy after storage has committed.

The [owner transaction contract](../../planning/loam/access/architecture.md#atomic-content-and-access-changes)
also requires atomic application content changes. Prepared grant writes are
its first primitive. They do not yet implement the complete owner API,
authenticated admission, content participation, or a persistent backend.

## Decision

Add preparation and exact completion to `GrantLedger`. Existing synchronous
mutation methods use this same preparation path and finish through its volatile
commit. There is one implementation of grant validation and mutation; storage
adapters do not reconstruct the grant transition from a reported outcome.

`prepareCopying` accepts one command and the current graph/ledger version. It
validates the command, copies retained selections, reserves the graph, and
returns a transaction ticket. A validated no-op returns no ticket and keeps the
revision. Preparation emits no event and exposes no grant through committed
lookup or access evaluation. Proposed record IDs are storage data, never
publication authority.

Only the bounded delta is retained. Preparation does not copy the entire graph
or grant table. Exact and subtree scopes allocate nothing after initialization;
selected scopes retain the same bounded copies needed by their final records.
Every allocation completes before the graph reservation is installed. Applying
or discarding a prepared delta performs no allocation or I/O.

### Scope reservation

A graph reservation keeps the resource revision stable across the write.
Creation, reparenting, deletion, and graph destruction refuse while it is held,
including a no-op reparent. Reads can still inspect the committed structure.
A reservation has an owner and a monotonically advancing local sequence;
a stale token cannot release a later reservation. Counter exhaustion refuses.

The ledger owns the reservation until completion. Another grant mutation
returns busy, while protected reads use committed state. Independent owners
remain available. The embedding must keep the graph at a stable address and
serialize native calls, as before; managed access adds no scheduler, thread, or queue.

### Storage phases and lifetime

| Phase | Permitted completion | State visible to protected reads |
| --- | --- | --- |
| Prepared | Cancel, commit volatile, or begin the storage write. | Last committed grants. |
| Writing | Report committed, known unchanged, or unknown outcome. | Last committed grants. |
| Uncertain | Resolve the outcome as committed or known unchanged. | Refusal until the outcome is established. |

`beginWrite` returns the exact typed write view and marks it in flight. The view
includes the resulting grant record, resulting revision, and any parent
inventory record affected by child issuance. Those records must persist as one
atomic unit. This view is not a serialized format or a database implementation.
The adapter must preserve the immutable policy schema needed to interpret it.

The ticket binds owner identity, transaction sequence, and base graph/ledger
revision to the retained immutable payload. Completion compares the entire
ticket and phase. A stale, altered, duplicated, or cross-owner completion cannot
apply a different change. These checks catch mismatched completion plumbing;
they cannot prove that a malicious storage adapter wrote the supplied data.

Write-view selections borrow ledger memory. The adapter must retire its I/O
before reporting an outcome. Cancellation is accepted only before `beginWrite`;
started and uncertain writes retain their memory and reservation. Both graph
and ledger destruction return busy while reserved or pending. An unknown
outcome retains the write view until recovery supplies a known resolution.

A successful storage completion installs the prepared delta synchronously and
returns its committed change event. It does not reallocate, rerun policy, or
emit before commit. A known-unchanged result discards the delta without changing
revision or emitting an event. After an unknown outcome, grant inspection,
effective-status evaluation, protected use, and new mutations refuse with
`RecoveryRequired`. Revision and record counts remain structural diagnostics.

Resolution of an uncertain write uses the same ticket. A confirmed commit
installs the retained delta and emits its event; a confirmed unchanged result
releases it without an event. A late duplicate completion refuses rather than
re-emitting an event. The storage adapter owns the evidence for the resolution.

### Remaining owner integration

These are trusted model APIs. A transaction ticket is not an invocation
credential, management capability, remote operation ID, or durable restart
record. The complete owner layer must admit actual held authority, apply
management ceilings, and compose graph, grant, and opaque content deltas in
one recoverable transaction. An arbitrary pair of independent writes cannot
satisfy that contract.

This slice provides no content callback, persistent codec, restart restoration,
remote retry receipts, or publication mechanism. In-process outcome resolution
is implemented; recovery after process loss remains unimplemented. Fresh
stores still require fresh owner identities. Hosts must not rebuild an empty
ledger with an old identity as a substitute for restoration.

CapTP actors, scoped subscriptions, and language bindings will consume these
shared state transitions through the existing Host. They must not add another
transaction engine or repeat grant decisions. The [managed access plan](../../planning/loam/access/architecture.md)
and [Rooms implementation plan](../../planning/rooms/access-grants.md) own
those remaining surfaces.

## Evidence

The managed access tests exercise pending invisibility, graph mutation refusal, parent
inventory atomicity, cancellation before writes, stale and altered tickets,
duplicate completions, uncertain outcomes, and both recovery resolutions.
They also verify allocation-free completion and resolution, retained selection
ownership, failure unwind, counter exhaustion, and independent graph owners.

An early test found that no-op reparenting bypassed the new reservation guard.
Graph mutation preconditions now share one check, and the transaction test
retains that case. Test cleanup explicitly retires its fake storage writes so
an assertion failure cannot be hidden by a busy-destruction failure.

Deliberately weakened ticket comparison, admitted reads during uncertainty,
and completion before a write started are rejected by their focused tests.
The tests use a fake storage boundary; they do not establish filesystem
recovery or distributed commit. `zig build test -Dtest-filter=access` runs them,
and `zig build check` includes the full model and public API compilation.
