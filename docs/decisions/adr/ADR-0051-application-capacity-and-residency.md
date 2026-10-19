---
id: ADR-0051
status: accepted
date: 2026-10-19
tags: ["loam", "persistence", "memory", "lmdb", "storage", "indexeddb", "benchmark"]
decision: "Each application derives its capacity from its declared data shape and the largest admitted operation."
supersedes: []
superseded_by: []
amends: []
amended_by: []
---

# ADR-0051 Application capacity and residency

## Context

A small embedding and a large application have different record, call-memory and live-capability requirements. Increasing a global default only moves the point where an application fails.

## Decision

Each application derives its capacity from its declared data shape and the largest admitted operation. Store, call and endpoint limits remain independently bounded. Tests fill the application's declared boundary rather than relying on ordinary small examples.

The record cache charges the encoded size it actually retains. A maximum-size read reservation is released after completion copies the result to its retained size. Unchanged resident bytes can remain cached without extending the authority of an older lease.

Workloads distinguish hot reads, record-cache misses, operating-system page-cache state, durable changes and browser crossings. A report names the engine and environment that ran it.

## Alternatives and consequences

Larger defaults cannot know application fan-out or reply size. Charging a maximum reservation forever would waste the configured cache. Counting crossings alone cannot establish browser latency, and a warm OS cache cannot establish cold-disk cost.

Batching several admitted changes in one atomic call can reduce flush frequency without weakening acknowledgement. Choosing a default engine requires a matched comparison, not a claim that every engine pays the same flush protocol.

## Evidence

Capacity-limit tests, allocation checks and the existing [Loam workloads](../../../bench/loam/README.md) cover their named contracts. [The storage default](ADR-0062-sqlite-default-storage.md) owns engine selection. Unmeasured workloads remain in the roadmap.
