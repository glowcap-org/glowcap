---
id: ADR-0064
status: accepted
date: 2026-10-19
tags: ["session", "engine", "performance", "host", "handoff", "outbound", "memory", "v1_0"]
decision: "The session admits an outbound tree through one owning validation path and inventories reference-bearing slots once."
supersedes: []
superseded_by: []
amends: []
amended_by: []
---

# ADR-0064 Borrowed outbound encoding

## Context

Repeated tree walks for validation, lowering, accounting and encoding dominate small calls. Keeping caller trees until a later drive also makes queue lifetime depend on the caller's arena.

## Decision

The session admits an outbound tree through one owning validation path and inventories reference-bearing slots once. Lowering stages the exact leases it claims in that walk. Admission charges, encodes and queues the deliver as its owned frame.

The queue retains the frame and protocol resources needed for later emission or rollback. The caller regains its borrowed tree when send returns. The drain does not encode or traverse the tree again.

Codec encoders read one borrowed view contract. Owned trees project into that contract without a second encoder implementation. Capability-free caller values can be lent directly. Typed integer slices project as list runs, avoiding per-element temporary values.

Codec measurement remains with its writer. Syrup can carry encoded size through admission so its later count pass covers the envelope rather than the tree. Session validation still owns depth, uniqueness and reference authority.

## Alternatives and consequences

A generic visitor invoked for each old pass would retain the cost of visiting every element repeatedly. Certifying inside a codec would move authority out of the session. Encoding a borrowed tree at emission would read reset turn storage. A growable output buffer would add a copy or shrink instead of one exact allocation.

Capability-bearing sends retain transactional lowering, and typed runs keep ordinary list semantics across codecs. There is no promise of one identical instruction path for every representation or profile.

## Evidence

Admission, allocation failure, borrowed values, typed runs, queued rollback and wire golden tests run under `zig build test` and `zig build oracle-check`. [Benchmarks](../../../bench/README.md) owns the measured costs.
