---
id: ADR-0031
status: accepted
date: 2026-10-19
tags: ["diagnostics", "lifecycle", "c-abi", "bindings"]
decision: "A failure with a live caller uses its normal result or close barrier."
supersedes: []
superseded_by: []
amends: []
amended_by: []
---

# ADR-0031 Structured diagnostics

## Context

Some asynchronous failures have no live return recipient. Trace events and overwritten last-error slots cannot provide a reliable owner for those failures.

## Decision

A failure with a live caller uses its normal result or close barrier. A failure without one enters a typed bounded diagnostic journal owned by an explicit surviving object. The schema crosses the core, C ABI and bindings without each runtime inventing its own fields.

Records retain the owning lifecycle and exact cause. Capacity and lost-record counts are observable. Rendering, logging and escalation belong to the embedding. Per-call error text remains per-call state rather than becoming a journal.

## Alternatives and consequences

Live tracing is optional observation rather than failure custody. A last-error slot is overwritten by later calls. A process-global queue would be duplicated across independently compiled archives and would make lifetime implicit. Separate language journals would disagree about ordering, bounds and loss.

A bounded journal does not guarantee lossless telemetry. Its contract makes overflow visible and preserves the declared owner. Closing that owner must still account for pending failures through its own result contract.

## Evidence

Journal, overflow, provider-cleanup and per-call failure tests run under `zig build test` and the binding checks. [Architecture](../../architecture.md) describes where errors cross ownership boundaries.
