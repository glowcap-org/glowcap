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

The runtime owns retry policy over complete new dial attempts. Success creates a new session, not a continuation of old wire state.

An owning Host, Runtime or Session closes under an explicit pending-work policy. Cancel stops admitted work. Finish seals admission, drives existing work within a grace budget and escalates to cancel on expiry. Implicit cleanup cancels. Transport close remains interruption and release, not another protocol-finishing policy.

Sending or receiving abort is terminal. The engine commits the outbound abort then closes. Failure while encoding a projected refusal still closes and preserves the original cause.

The failed operation's owner supplies `BreakCause` separately from diagnostic text. Its origin identifies the provenance established for a named failure. Unclassified diagnostics keep unspecified origin even when written locally. Its reason records what that producer established. Fetch, restoration and withdrawal add operation context without replacing either fact. The foundation layer owns this vocabulary and the queries that binding generators project.

Crossing a CapTP connection establishes only partner provenance with an application reason. An explicit local application refusal carries local provenance. Both expose application protocol text only without an enclosing operation context. A local publication miss has its own reason. Only partner fetch refusals use the protocol's unknown-publication text to identify a miss.

The result family describes the operation's carrier. Cause can describe a different participant. A withdrawal through a live recipient session can break because the exporter closed. These facts remain separate.

Fresh dial reports accept only `RouteFailure`: peer unreachable or transport unavailable. A missing transport is established by the transport registry. Diagnostic words and cleanup failures cannot change that result. The terminal route cause says transport unavailable only when every accepted attempt reports it.

Binding generators derive the route-to-cause conversion and its exact inverse from `RouteFailure.cause()`. The inverse accepts only a fresh route cause, with no enclosing operation context. Route convenience queries accept fetch and withdrawal context but exclude restoration: the outer operation is a restoration failure, and its retained reason still describes the inner route failure.

Loam retains independent application and restoration diagnostic candidates. The callback's returned error selects which candidate settlement publishes, including failures during result materialization. A missing restoration detail renders the label alone.

C completions and the four bindings carry origin, reason and context without reconstructing them from text. Each C field is a 32-bit integer. Internal metadata is packed independently of this ABI. Human display and wire encoding render labels only at those boundaries. Retained diagnostics stay bounded, and operation context may label partner text.

## Alternatives and consequences

An invisible reconnect facade would invent continuity. A graceful Boolean leaves both the work set and timeout undefined. Waiting for sessions to end naturally can wait forever. Reconnect inside a borrowed completion backend cannot reconstruct the provider that owns it.

The library returns failures or latches them at the surviving owner. It does not choose an application's logging or recovery. A cleanup failure retires the smallest affected scope rather than condemning unrelated sessions.

## Evidence

Close barriers, abort projection, cancellation, deadlines and retry tests run under `zig build test`. Process and binding checks exercise their named runtimes. [Known limitations](../../boundaries.md) records the remaining guarantees.
