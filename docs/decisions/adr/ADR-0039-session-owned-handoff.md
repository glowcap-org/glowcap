---
id: ADR-0039
status: accepted
date: 2026-10-19
tags: ["handoff", "three-party", "gift-registry", "engine", "session", "captp", "authority", "gifts"]
decision: "Each Peer owns its session's deposited gifts, replay state and profile-defined emitted counter."
supersedes: []
superseded_by: []
amends: []
amended_by: []
---

# ADR-0039 Session-owned handoff authority

## Context

Three-party handoff spans several connections, but deposits, signatures and replay counts belong to specific CapTP transcripts. A Host-wide registry would give them the wrong lifetime.

## Decision

Each Peer owns its session's deposited gifts, replay state and profile-defined emitted counter. Withdrawal resolves the live gifter/exporter session named by the signed give, verifies with that session's key and consumes its exact gift. Receive-side replay validation belongs to the receiver/exporter session.

The Node coordinates routes without replacing those authorities. Its automatic baseline redeem path keeps a separate Host-lifetime emitted cursor for Goblins reconnect interoperability. That affects issuance, not receive-side replay checks. Fresh session signing keys separate reconnect incarnations.

Signatures cover canonical protocol fields rather than a particular codec's serialization. Inline gives can appear recursively in passable data. Outbound lowering retains every capability occurrence in a bounded transaction and publishes only when the complete message is admitted.

## Alternatives and consequences

A shared gift registry copies provenance and survives the session that authorized it. Re-fetching a publication at withdrawal can replace the object actually deposited. Signing arbitrary codec bytes would make re-encoding invalidate a signature.

Incremental deposit publication would leave externally visible gifts after a sibling failed. Raw capability ids without retains would let callers release authority before the batch finishes. Close destroys only the session's own gift and replay state.

## Evidence

All three handoff roles, replay refusal, exact-target retention and allocation rollback run under `zig build test` and `zig build oracle-check`. [Community review](../../community-review.md) records live Goblins handoff evidence.
