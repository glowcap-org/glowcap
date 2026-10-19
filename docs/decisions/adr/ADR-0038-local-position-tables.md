---
id: ADR-0038
status: accepted
date: 2026-10-19
tags: ["model", "position", "handoff", "session", "naming", "performance", "engine", "driver"]
decision: "Wire positions and locally synthesized identities use explicit representation arms."
supersedes: []
superseded_by: []
amends: []
amended_by: []
---

# ADR-0038 Local positions and table identity

## Context

Locally issued handles can support direct lookup, while stale references and partner-selected integers must retain their full meaning. Reserving a band of the peer's integer namespace would confuse those two contracts.

## Decision

Wire positions and locally synthesized identities use explicit representation arms. A peer can choose any representable protocol position. Local mechanisms do not confiscate high bits or sentinel bands from that namespace.

A locally issued handle names a row and its generation. Each layer owns its own row lifetime. Own-side session positions use dense reusable rows, and an observer that can outlive an answer incarnation also retains its stamp.

Facts about a local position live on its row. A relation whose value already names its own key needs no redundant reverse row. Peer-keyed tables retain their separate hashing and validation contract.

## Alternatives and consequences

A raw row pointer cannot fail closed after reuse. A monotonic vector with no reuse grows throughout a long session. A shared table across layers would merge distinct lifetimes. Reserving every released answer until all notifications disappear would unnecessarily prevent ordinary position reuse.

Bounds, generation and incarnation checks protect stale readers. Exhaustion refuses rather than wrapping. Dense local storage changes no wire semantics or peer authority.

## Evidence

Full-range peer positions, reuse, stale handles, answer stamps and resolver-link transitions run under `zig build test` and `zig build oracle-check`.
