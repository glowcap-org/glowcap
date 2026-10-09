---
id: ADR-0134
status: accepted
date: 2026-08-25
tags: [rooms, sessions, capabilities, persistence, browser]
decision: "A Rooms session owns workspace intent, exact capability custody and recoverable effects in one managed Loam graph, while attached views consume admitted observations and submit commands through held use endpoints."
supersedes: []
superseded_by: []
amends: [ADR-0133]
amended_by: [ADR-0135, ADR-0137, ADR-0138, ADR-0139, ADR-0141]
---

# ADR-0134 Shared Rooms session capability

## Context

A session is the application peer holding directory, room, direct, archive and
operator capabilities. Multiple views may use it, and the session may continue
while they are detached. Serialized presentation cannot replace that authority.

## Decision

Keep one managed session owner across the process and browser embeddings.
Workspace intent, typed custody and effect receipts commit in one Loam graph.
Every command checks its held initiating use endpoint and exact selected targets.
Local and remote clients use the same application declarations and receipt
executor. Shared Zig owns grant semantics and capability identity.

Use and management are independent capabilities. Explicit grouped permissions
govern observation, interaction, custody, recovery and upstream operations.
Controls govern only their admitted branch. Presets expand into those permissions;
a view label or an inventory row cannot confer them.

Commit original effect intent and target custody before dispatch. Retain exact
returned results through settlement and recovery. Unknown non-idempotent work
stays unresolved. Canceling a view's wait releases observation while admitted
execution remains owned. The [effect contract](../../rooms/session-effects.md)
owns dispatch, cancellation and replay details.

Observe workspace intent and activity through bounded source-checked receivers.
Drafts and shared selection belong to the workspace; theme, modal state and rail
presentation belong to each page. Membership, direct and signaling workers
retain the original source and retire exact live registrations on replacement.
A detached view cannot retire sibling workers or erase the session's receipts.

The [session guide](../../rooms/session.md) owns production startup, storage,
shutdown, management and consumer paths. Archives and private bridge secrets
retain separate storage owners and explicit acquisition boundaries.

## Evidence and costs

The [executor scenarios](../../../apps/rooms/rust/proofs/src/session_executor.rs)
exercise actual source/target custody on Linux and Chromium. The
[shared-session journey](../../../apps/rooms/test/proofs/shared_session_proof.ts)
uses two production pages, files, shared drafts, process restart and access
management. [Cost measurements](../../../bench/rooms/session-costs.md) record
allocation and traversal budgets without claiming network latency.
