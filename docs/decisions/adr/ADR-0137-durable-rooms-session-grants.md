---
id: ADR-0137
status: accepted
date: 2026-08-26
tags: [rooms, sessions, capabilities, persistence, revocation]
decision: "Rooms session access uses shared Loam grants with independent use/control publications, per-call admission, revision-checked management and exact receipt recovery across restart."
supersedes: []
superseded_by: []
amends: [ADR-0134, ADR-0135]
amended_by: [ADR-0183]
---

# ADR-0137 Durable Rooms session grants

## Context

A shared session must retain the same authority after restart. Issuance, policy
changes and revocation need durable commit points, bounded storage and recovery
that cannot substitute a stronger grant after a lost reply.

## Decision

Use shared Loam grant records and exact endpoint publications for session access.
The managed session owns content and receipts. Shared grants own ancestry,
ceilings, current policy, suspension and terminal retirement. Store and service
quotas bound that state. Startup restores bounded owner metadata and discovers
publications on demand.

Use and management have independent stable names. Use checks current source
admission on every operation and protected delivery. Inspect, Issue, Edit,
DelegateControl and lifecycle powers belong to held controls, with independent
ceilings. Inventory is descriptive, bounded and indexed by direct children.
It supplies no use or management capability.

Fresh changes compare expected revision. Exact issuance and mutation replay
recover the original committed receipt before comparing an old revision as a
new request. Source and returned custody checks still apply. Policy changes
preserve endpoint identity. Revocation cannot make an old endpoint active
again. Inactive observations disclose status only.

A viewer keeps every power its issuing source can pass on. Editing a newly
issued grant is bounded by the source's edit and issuance ceilings. Sharing
management attenuates a separate control. The recipient cannot add a power
fixed at issuance. The [session guide](../../rooms/session.md#management)
owns the production editor and consumer contract.

## Evidence and costs

The [executor scenarios](../../../apps/rooms/rust/proofs/src/session_executor.rs)
exercise source loss, saved grants and exact receipt recovery on both stores.
The [production editor journey](../../../apps/rooms/test/page/shared_session_access.ts)
checks issue, independent control sharing, conflict recovery, permission changes,
pause, resume and revoke through the pages. Indexed inventory and on-demand
publication keep ordinary workspace writes independent of a grant-population scan.
