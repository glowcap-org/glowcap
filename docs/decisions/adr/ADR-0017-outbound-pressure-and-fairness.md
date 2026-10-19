---
id: ADR-0017
status: accepted
date: 2026-10-19
tags: ["net", "resilience", "memory", "performance", "host", "scheduling", "backpressure", "node"]
decision: "A completion connection stops arming reads when pending outbound bytes cross its high-water mark."
supersedes: []
superseded_by: []
amends: []
amended_by: []
---

# ADR-0017 Outbound pressure and fairness

## Context

A slow reader can make one connection retain committed replies indefinitely. A pressured recipient must not stop unrelated sessions from making progress.

## Decision

A completion connection stops arming reads when pending outbound bytes cross its high-water mark. It resumes on drain and releases capacity beyond its explicit steady retention bound. This applies backpressure before admitting more work that would produce replies.

A Node action refused by one recipient's outbound pressure parks on that recipient. It becomes runnable when that recipient's output is taken. Ordering is per recipient rather than one global FIFO across independent peers.

## Alternatives and consequences

Dropping a committed reply would violate protocol state. Condemning a merely slow recipient turns normal flow control into a failure. Repeatedly rotating a refused action can spin, and reserving capacity before its actual recipient is known duplicates admission policy.

The queue and parked row remain bounded owners. This does not promise that an application can produce unlimited output or that arbitrary peers make progress. Session resource limits and application admission still apply.

## Evidence

Completion backpressure, stalled-recipient, fairness and bounded-retention scenarios run under `zig build test`. The [benchmark guide](../../../bench/README.md) separates idle and busy costs.
