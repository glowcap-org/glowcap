---
id: ADR-0058
status: accepted
date: 2026-10-19
tags: ["actors", "vat", "turns", "goblins", "semantics", "engine", "node", "ordering"]
decision: "An outermost Vat turn commits its eventual sends only on success."
supersedes: []
superseded_by: []
amends: []
amended_by: []
---

# ADR-0058 Transactional turn sends

## Context

A turn can fail after preparing sends or capability handoffs. Publishing those effects immediately would make the failed turn observable, while holding a second queue above the session can reorder later protocol work.

## Decision

An outermost Vat turn commits its eventual sends only on success. Admission occurs during the turn. The Vat tells each enrolled participant to commit or abort once.

On failure the Peer retracts the provisional sends, the Host rolls back their capability lowering and the Node withdraws staged output and deposits. A send awaiting gift ids reserves its recipient queue position immediately. Later work cannot overtake that hole, and abort removes it.

The existing forward transitions prepare atomically. Rollback is their bounded inverse, not a whole-session snapshot or a per-mutation undo log charged to every send.

## Alternatives and consequences

Holding far sends in a Vat-owned queue would give the wrong owner ordering authority. A Node-only barrier would miss session-owned releases and listener traffic. Delaying all admission until turn end would alter promise and queue semantics.

Direct mutations of a mutable actor are not rolled back. Actors spawned during a failed turn remain alive because such state may already hold them. This contract does not retract an effect already dispatched outside the transaction boundary.

## Evidence

Failed-turn, provisional-window, exact deposit and queue-order tests run under `zig build test`. The [local snapshot decision](ADR-0015-persistent-collections-and-time-travel.md) owns functional state rollback.
