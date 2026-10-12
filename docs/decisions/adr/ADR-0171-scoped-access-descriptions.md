---
id: ADR-0171
status: accepted
date: 2026-09-15
tags: [loam, access, actors]
decision: "Held use capabilities describe their current target-specific access through the same evaluator that authorizes calls."
supersedes: []
superseded_by: []
amends: [ADR-0169]
amended_by: []
---

# ADR-0171 Scoped access descriptions

## Decision

`GrantView.describe` and `require` share one effective-policy calculation over
the selected grant ancestry and current resource containment. Description
returns an owned, bounded snapshot. Active access includes the grant's own
ceiling and configured policy, the effective intersection, and its remaining
delegation depth. A paused, revoked, or out-of-scope path returns only that
status. A revoked ancestor wins over a paused descendant.

`GrantLedger.describe` and held `GrantUse.describe` expose the same calculation
for resident models. `storage.Operation.describe` uses the existing bounded
read continuation and revision checks. It returns the snapshot and immutable
policy vocabulary needed to interpret its values. Control references refuse
this use-only operation.

Managed use endpoints accept `describe-access()` without a target argument.
The endpoint supplies its fixed resource binding. Preparation loads authority
records without loading application content. The existing Host attachment
restarts stale preparation, fences uncertain writes, and runs the reply through
the normal Vat settlement path. No snapshot is reusable admission for a later
content effect.

## Public representation

The reply is a tagged `access:description` value. Active fields are, in order:
status symbol, policy schema ID, ceiling policy, configured policy, effective
policy, and delegation depth. Other statuses have one field.

An `access:policy` has a list of enabled stable permission keys and a list of
restricted bounds. Each `access:bound` contains its key, `lower_bound` or
`upper_bound`, and unsigned value. Missing bounds mean unrestricted. Schema
IDs, keys, and bounds use exact protocol integers, including large integers
above the signed 64-bit range.

No owner/grant identity, ancestor policy, sibling inventory, resource scope
list, global revision, or event sequence enters this representation. Unrelated
owner activity leaves it unchanged. Inactive descriptions reveal no fresh
policy values. The Zig policy vocabulary contains declaration metadata, not
ancestor restrictions. The wire representation projects only the stated fields.

## Cost and limits

Evaluation allocates nothing. Stored evaluation uses the existing operation
and bounded working set. Unloaded records request ordinary storage work.
Wire projection and reply copying use the retained call's fixed arena and
the existing frame limit. The schema limits of 64 permissions and 16 constraints
bound each policy. Budget room for all three policies when choosing call and
frame limits. Insufficient capacity fails without changing state.

This implements access snapshots, not subscriptions, replay cursors, control
inspection, or resource inventory. Those contracts remain in the
[readiness checkpoint](../../loam/architecture.md#readiness-before-the-c-abi).
Future observation can use this snapshot for resynchronization, but must add
scope-bound cursors and retained committed events rather than publish owner
revision counters.
