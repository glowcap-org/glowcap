---
id: ADR-0026
status: accepted
date: 2026-10-19
tags: ["driver", "handoff", "three-party", "node", "c-abi", "bindings", "engine", "sans-io"]
decision: "The standard multi-session product composes one Host with one Vat through session-specific ports."
supersedes: []
superseded_by: []
amends: []
amended_by: []
---

# ADR-0026 Host-scoped capability identity

## Context

A session wire position cannot identify an object across sessions. Optional enrollment or re-fetching a publication during handoff can select an equivalent object while losing the exact object originally held.

## Decision

The standard multi-session product composes one Host with one Vat through session-specific ports. The Host owns canonical opaque application capability identities. A session owns its wire projections, and the Node owns authority-neutral routing and scheduling.

Every application-held capability has a Host owner, regardless of how it was obtained. Identity is lifted automatically and lowered through the selected session. Equal positions on different sessions never alias, and stale routed handles cannot acquire a new meaning.

Publications name targets for discovery. Gifts retain the exact deposited target, including its state and local references. Closing a session retires its projections rather than destroying an actor rooted elsewhere.

## Alternatives and consequences

A separate actor copy per session would let state and behavior diverge. Re-resolving a swiss name at withdrawal would substitute current naming state for held authority. Optional enrollment makes correctness depend on which API produced a handle. Per-binding routing would duplicate the same policy across runtimes.

Host identity does not merge the protocol, Vat or I/O owners. Applications that need independent execution use separate Hosts. Cross-Host mediation remains an explicit capability relationship.

## Evidence

Host identity, cross-session equality, exact gifts and stale-handle scenarios run under `zig build test` and `zig build oracle-check`. Binding consumers exercise the shared C projection.
