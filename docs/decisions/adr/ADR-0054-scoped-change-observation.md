---
id: ADR-0054
status: accepted
date: 2026-10-19
tags: ["loam", "access", "observation"]
decision: "One owner transaction appends one bounded change batch."
supersedes: []
superseded_by: []
amends: []
amended_by: []
---

# ADR-0054 Scoped change observation

## Context

Filtering raw owner events is insufficient when a cursor or revision reveals hidden activity. Observers need committed ordering and an explicit result when retained history expires.

## Decision

One owner transaction appends one bounded change batch. Grant, resource, content and control changes share that writer. Abort and unchanged mutations append nothing. Storage completion and recovery govern visibility.

An observation context binds an exact held descriptor and target where required. Its persisted unpredictable key seals opaque cursor state and authorized dependencies. A cursor is neither transferable authority nor a raw owner revision.

Every delivery checks current authority. Replies disclose only scoped changes and status, without raw ancestor identities or hidden sibling positions. A cursor advances for changes visible to that context. Expired history yields an explicit reset requirement rather than silently omitting changes.

Authority, inventory, placement and content stamps stay distinct, so a child-index rewrite does not fabricate an access change. Bounded retention drops old history edges for ordinary tracing to reclaim.

## Alternatives and consequences

An owner-wide revision leaks unrelated activity and creates needless invalidation. Keeping database snapshots would make observer cost grow with state. Treating an event as authority would let stale notifications override current revocation.

This is bounded recovery over committed metadata, not a remote delivery transaction or an unbounded event log. Terminal revocation discloses status alone.

## Evidence

Scoped cursor, hidden-change, retention-gap and recovery tests run under `zig build test` and the shared durable suites. [Managed storage](../../loam/access-storage.md) describes the observation integration.
