---
id: ADR-0138
status: accepted
date: 2026-08-26
tags: [rooms, browser, react, sessions, state, performance]
decision: "The Rooms browser supplies stable presentation and managed-session owners through React contexts, while each page keeps a non-authoritative Zustand projection read through selectors."
supersedes: []
superseded_by: []
amends: [ADR-0134, ADR-0135]
amended_by: [ADR-0142, ADR-0143]
---

# ADR-0138 Rooms browser controller and projection

## Context

Presentation, application authority and changing view data have different
lifetimes. A context holding all three makes every update broadly observable
and hides who can execute a command or retain a capability.

## Decision

Keep a stable browser controller for presentation and session establishment.
After establishment, supply the actual managed viewer through
`ManagedSessionProvider`; the grouped session controller submits commands
through that viewer. Setup and chat both receive the page's presentation
projection. Session-dependent components require an opened managed workspace.

Each `RoomsPage` owns one non-persistent Zustand projection.
`RoomsProjectionProvider` supplies it, and `useRoomsState` selects the fields a
component renders. The projection owns no live capability authority. Managed
intent and activity project into it; commands, uncertain operations and retained
results remain with their application/session owners.

Separate pages keep display state, rosters and unread projections independently.
Views attached to one workspace observe its committed drafts and selection.
Promise identity can coalesce a live request, while durable idempotence uses the
original receipt and canonical intent. Unmounting a form cannot discard uncertain
issuance or effect custody.

## Performance and evidence

Leaf selectors isolate draft, roster, typing and message updates from unrelated
application rendering. Temporary maps index conversation identity and held-line
IDs during projection, avoiding repeated population scans. Classification reuses
the already decoded JavaScript view. Allocation and traversal claims belong to
[session measurements](../../../bench/rooms/session-costs.md).

The [production shared-session journey](../../../apps/rooms/test/proofs/shared_session_proof.ts)
checks shared drafts, independent page attachment, process restart and editor
focus. The [projection regression](../../../apps/rooms/test/session/managed_projection_cost_test.ts)
holds bounded traversal work across the admitted population. Replacing React or
Zustand cannot change capability, command or OCapN semantics.
