---
id: ADR-0048
status: accepted
date: 2026-10-19
tags: ["access", "storage", "performance", "memory", "persistence", "research", "loam", "architecture"]
decision: "Loam is an optional persistence foundation below managed access."
supersedes: []
superseded_by: []
amends: []
amended_by: []
---

# ADR-0048 Loam persistence foundation

## Context

Durable graph state is useful beyond one access model. Putting persistence in the Host or reimplementing it in every binding would couple optional storage to protocol authority.

## Decision

Loam is an optional persistence foundation below managed access. It stores bounded records and transactions, with explicit leases, residency and opening incarnations. Immutable collections remain a dependency-free leaf.

The shared Zig core evaluates transaction batches. Evaluation is resumable across a missing read and retains no backend row across that suspension. Once writes begin, they are emitted synchronously into the same atomic storage transaction. Engine adapters and browser execution supply effects rather than a second transaction interpreter.

Managed access composes its resource, grant and content records through that foundation. Host and Vat integration retain their existing execution ownership. Historical content snapshots do not restore historical grant authority for an ordinary call.

## Alternatives and consequences

A managed-access-only database would duplicate a general record graph. Retaining a transaction-sized snapshot would make memory grow with its work set. A Rust or JavaScript evaluator would repeat record, authority and recovery laws. Suspending after partially emitted writes could repeat publication or mark work.

The store's configured bounds remain explicit. A mock completion proves plumbing rather than durable recovery. Engine commit acknowledgement and tested process-loss recovery do not establish untested power-loss behavior.

## Evidence

Shared transaction tests run under `zig build test`, and each disk engine runs the durable suite and process-loss probes. [Loam](../../loam.md) and [stability](../../stability.md) record the supported execution forms and fault limits.
