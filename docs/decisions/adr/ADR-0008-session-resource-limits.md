---
id: ADR-0008
status: accepted
date: 2026-10-19
tags: ["session", "limits", "resilience", "abort-taxonomy", "security", "captp", "memory", "flow-control"]
decision: "Session limits bound partner-driven tables and retained bytes at their owning insertion points."
supersedes: []
superseded_by: []
amends: []
amended_by: []
---

# ADR-0008 Session resource limits

## Context

A peer can send valid messages that retain too much state. Transient outbound pressure and retained answer authority also have different lifetimes.

## Decision

Session limits bound partner-driven tables and retained bytes at their owning insertion points. Exceeding a limit refuses with a typed resource failure before mutation. Deposited gifts charge their complete retained rows, and replacement admission uses the net change.

Sent inbound-answer resolutions move from transient flow accounting into a separate cumulative answer-store budget. The durable owner releases that charge on replacement, retirement, answer GC or close. It never evicts answer authority to meet its cap.

The C Host projects selective limits through one versioned caller-owned options record. Bindings expose the same named configuration rather than growing positional setters.

## Alternatives and consequences

Unbounded tables permit memory exhaustion. A protocol-error label would misclassify structurally valid overload. One budget for transient output and retained answers can make committed state prevent the traffic needed to release it.

These limits bound retained growth, not request rate or deployment-wide abuse. Tables keyed only by locally issued work follow their own ownership and capacity rules. Applications choose limits appropriate to their workload.

## Evidence

Session allocation failures, aggregate answer charges, gift replacement and refusal projections run under `zig build test`. The [stability guide](../../stability.md) distinguishes these checks from a hosting security guarantee.
