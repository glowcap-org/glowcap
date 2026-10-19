---
id: ADR-0015
status: accepted
date: 2026-10-19
tags: ["actors", "vat", "time-travel", "snapshot", "memory", "persistent", "collections", "layer"]
decision: "Local functional behavior replacement is staged until a turn succeeds."
supersedes: []
superseded_by: []
amends: []
amended_by: []
---

# ADR-0015 Persistent collections and time travel

## Context

Snapshotting local functional actor state should not require copying every retained byte, and actors that never snapshot should not pay for a collector on every turn.

## Decision

Local functional behavior replacement is staged until a turn succeeds. Snapshot and restore retain local actor state, sharing immutable structure where possible. The persistent map is a dependency-free leaf that applications may use for incremental state changes. The Vat does not require it.

A snapshot does not rewind CapTP sessions, wire queues, remote effects or managed grant authority. Mutable actor state changed directly by a behavior is outside functional rollback.

## Alternatives and consequences

Eager deep copies make each snapshot proportional to total mutable state. Mandatory immutable state plus GC charges every behavior change. Immediate behavior replacement loses discard-on-error semantics.

The collection layer remains deliberately small. It supplies the implemented map rather than a general collection framework. Applications choose state representations and retain the responsibility for effects beyond local functional state.

## Evidence

Actor snapshot, failed-turn and persistent-map tests run under `zig build test`. Transactional far sends have a separate [turn contract](ADR-0058-transactional-turn-sends.md).
