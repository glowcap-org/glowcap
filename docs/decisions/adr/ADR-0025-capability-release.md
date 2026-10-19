---
id: ADR-0025
status: accepted
date: 2026-10-19
tags: ["gc", "bindings", "memory", "captp", "host", "identity", "rust"]
decision: "An application can release a held Host capability explicitly."
supersedes: []
superseded_by: []
amends: []
amended_by: []
---

# ADR-0025 Capability release

## Context

A capability handle retains remote authority. Native deterministic destruction and language finalizers provide different guarantees and should not silently choose the same policy.

## Decision

An application can release a held Host capability explicitly. Automatic release accounts for the particular handle's retain rather than requiring a shared position-to-proxy registry.

Rust releases the Host retain when the last Ref clone drops by default. The setting belongs to the Host. Languages whose cleanup depends on a garbage-collector finalizer retain an explicit opt-in posture. Finalizers complement deterministic release rather than defining when an application must release authority.

The session owns actual wire accounting. A handle release and a promise answer's protocol lifetime are distinct operations. Delayed release carriers follow the session's batching and park contract.

## Alternatives and consequences

Explicit-only release burdens ordinary ownership in languages that can do it reliably. A per-session weak identity registry couples cleanup to proxy deduplication. Enabling nondeterministic finalizer behavior by default would change wire traffic and lifetime behind the application.

Automatic cleanup is not a timing guarantee and cannot recover a killed process's live session. Tests must distinguish wrapper collection, Host retain retirement and a remote peer actually reclaiming its export.

## Evidence

Handle, Rust Drop, finalizer and GC tests cover local behavior. [Community review](../../community-review.md) states which live Goblins checks release handles explicitly and what finalization they establish.
