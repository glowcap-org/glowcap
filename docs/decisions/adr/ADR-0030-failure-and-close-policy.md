---
id: ADR-0030
status: accepted
date: 2026-10-19
tags: ["resilience", "net", "driver", "c-abi", "error-handling", "host", "configuration", "captp"]
decision: "Adapters classify failures into actionable typed causes and bound waits on untrusted peers."
supersedes: []
superseded_by: []
amends: []
amended_by: []
---

# ADR-0030 Failure and close policy

## Context

A failed operation needs a caller that can act on it. Connection loss cannot be repaired by silently replaying a CapTP session whose tables no longer exist.

## Decision

Adapters classify failures into actionable typed causes and bound waits on untrusted peers. The runtime owns retry policy over complete new dial attempts. Success creates a new session, not a continuation of old wire state.

An owning Host, Runtime or Session closes under an explicit pending-work policy. Cancel stops admitted work. Finish seals admission, drives existing work within a grace budget and escalates to cancel on expiry. Implicit cleanup cancels. Transport close remains interruption and release, not another protocol-finishing policy.

Sending or receiving abort is terminal. The engine commits the outbound abort then closes. Failure while encoding a projected refusal still closes and preserves the original cause.

## Alternatives and consequences

An invisible reconnect facade would invent continuity. A graceful Boolean leaves both the work set and timeout undefined. Waiting for sessions to end naturally can wait forever. Reconnect inside a borrowed completion backend cannot reconstruct the provider that owns it.

The library returns failures or latches them at the surviving owner. It does not choose an application's logging or recovery. A cleanup failure retires the smallest affected scope rather than condemning unrelated sessions.

## Evidence

Close barriers, abort projection, cancellation, deadlines and retry tests run under `zig build test`. Process and binding checks exercise their named runtimes. [Known limitations](../../boundaries.md) records the remaining guarantees.
