---
id: ADR-0007
status: accepted
date: 2026-10-19
tags: ["model", "session", "engine", "sturdyref", "enliven", "equality", "goblins", "interop"]
decision: "A sturdyref retains its complete peer identity and swiss name until enlivenment selects and verifies the peer."
supersedes: []
superseded_by: []
amends: []
amended_by: []
---

# ADR-0007 Sturdyrefs and publication

## Context

A durable reference identifies authority at a particular peer. A mutable name, a route hint and a live capability are different things and cannot substitute for one another during recovery.

## Decision

A sturdyref retains its complete peer identity and swiss name until enlivenment selects and verifies the peer. Hints advise routing and do not participate in peer identity. Assertion-only cleartext use requires the explicit low-level posture.

Bootstrap lookup checks session publications before Host publications and then the durable provider. Authority outside a session cannot replace a session's own publication. Mutable aliases and randomly minted durable names occupy distinct namespaces.

A durable publication survives restart through caller-retained entropy and republication. The core has no hidden registry store. Loam discovers durable publications on demand through bounded Host admission and an atomic name index. Name reservations survive descriptor collection so an old name cannot acquire another target.

A session caches settled imports and collapses concurrent fetches for one swiss name. Cache entries preserve the import kind.

Enlivenment reserves its completion recipient before cached, wire or parked resolution. Returned values and capability retains have an explicit owner, including on cancellation and failure.

## Alternatives and consequences

Trusting a caller-selected session permits same-name substitution across peers. Putting hints in identity turns routing updates into identity changes. Startup enumeration makes memory grow with publication count. A second durability registry would duplicate the application's storage authority.

A publication is discovery, not a replacement for an already held or deposited object. Restart guarantees still depend on the embedding retaining the required entropy and state.

## Evidence

Fetch, publication, cached enlivenment and restart tests run through `zig build test` and the owning Loam checks. [Known limitations](../../boundaries.md) states the deployment guarantees.
