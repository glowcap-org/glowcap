---
id: ADR-0050
status: accepted
date: 2026-10-19
tags: ["loam", "persistence", "memory", "lifecycle", "access", "retirement"]
decision: "Loam performs bounded transactional tracing with persisted work queues, explicit live roots and atomic insertion barriers."
supersedes: []
superseded_by: []
amends: []
amended_by: []
---

# ADR-0050 Transactional reclamation

## Context

Persistent cycles require tracing, while newly held capabilities can become roots after a collection cycle starts. Reclaiming storage before retiring authority can leave live handles pointing at reused data.

## Decision

Loam performs bounded transactional tracing with persisted work queues, explicit live roots and atomic insertion barriers. The collector invokes no actor behavior and adds no state to CapTP sessions.

A collection cycle captures live custody once and journals newly admitted mark obligations until the exact collection receipt confirms their durable shading. Bounded exhaustion refuses new custody before it becomes visible. Managed retirement first disables authority through owner-local identity inventories, then shared tracing reclaims unreachable payloads.

Scratch and root inventories have explicit bounds. Storage writes advance the relevant revision without refreshing an unrelated lease's acquisition authority. Batches that do not delete data can preserve unchanged resident bytes.

## Alternatives and consequences

Keeping only the initial root snapshot misses later claims. Repeatedly scanning custody multiplies work without improving the ownership model. Submitting a root prefix would need another barrier before sweep. A best-effort deletion before authority retirement would be unsafe.

Collection needs write headroom. A full storage map can prevent it from making progress. Graph reclamation and revocation of already dispatched remote effects remain different contracts.

## Evidence

Collection, insertion, admitted-custody and bounded-retirement tests run under `zig build test` and the shared durable suites. [Loam](../../loam.md) owns operational limits.
