---
id: ADR-0004
status: accepted
date: 2026-10-19
tags: ["syrup", "wire-profile", "gc", "reference-counting", "abort", "goblins-parity", "conformance", "goblins"]
decision: "The baseline profile follows the pinned OCapN suite and Goblins-canonical Syrup forms."
supersedes: []
superseded_by: []
amends: []
amended_by: []
---

# ADR-0004 Baseline wire interoperability

## Context

A protocol implemented only against its own fixtures can be internally consistent and still fail to communicate with another implementation.

## Decision

The baseline profile follows the pinned OCapN suite and Goblins-canonical Syrup forms. Export and answer GC are separate operations. Export GC carries parallel position and wire-delta lists, and session accounting refuses mismatches and underflow before mutation.

Abort has one typed internal reason, projected into the profile's wire form. A baseline peer receives the required string representation. Private profiles may carry additional structure without changing the baseline.

Baseline structural projections use the shared answer/listener machinery. Optional operations are sent only when the negotiated feature permits them. Supporting an operation internally does not establish that Goblins exposes it through an application API.

## Alternatives and consequences

A combined release operation or saturating counters would obscure the peer's actual accounting. Comparing only glowcap-authored fixtures would provide no outside interoperability evidence.

The oracle corpus supplies deterministic regression coverage. Live Goblins peers and the upstream suite supply independent wire authority. Neither implies support for an untested transport, API or future upstream revision.

## Evidence

`zig build oracle-check`, `zig build goblins-interop` and `zig build check-external` cover different parts of this contract. [Community review](../../community-review.md) owns the exact coverage and omissions.
