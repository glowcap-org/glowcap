---
id: ADR-0045
status: accepted
date: 2026-10-19
tags: ["rooms", "browser", "persistence", "capabilities", "operations", "sessions", "schemas", "architecture"]
decision: "One portable Rust application owns Rooms policy and capability custody across process and browser execution."
supersedes: []
superseded_by: []
amends: []
amended_by: []
---

# ADR-0045 Managed Rooms sessions

## Context

A browser projection, live capability inventory and durable workspace cannot all be the authority for one conversation. A reconnect must also distinguish a known committed effect from an unknown outcome.

## Decision

One portable Rust application owns Rooms policy and capability custody across process and browser execution. Platform I/O and service composition remain separate crates. React contexts expose stable owners, and page state is a non-authoritative projection.

A managed session keeps workspace intent, exact held references and recoverable effects in one Loam graph. Attached views consume admitted observations and submit commands through their held use endpoints. Use and control grants have separate lifetimes, and every call checks current authority.

Credential preparation precedes dependent workspace commits. Secrets remain private custody and never enter ordinary views or exports. Reconnect replaces a live nickname claim only through authenticated continuity or its one-use voucher. Recovered timeline rows reconcile by identity and ordering rather than assuming they form a missing prefix.

Sharing can forward an already held reference or supply a source-dependent managed facet. A collection path, provenance label or common process grants nothing by itself. Recovery retains the exact accepted terms instead of substituting a broader reusable entrance.

Process-local budgets admit work at effect boundaries. Restart resets short-lived debt, and replicas have independent budgets. Admission is not a fleet-wide abuse ledger or hosting security guarantee.

## Alternatives and consequences

Separate browser and process policies would drift. Binding-owned grant ledgers would duplicate shared authority. Serializing raw runtime handles cannot restore authority after restart. A larger retry window supplies no identity proof.

The shared typed failure vocabulary preserves policy, storage, capability, runtime and cleanup causes until a product boundary renders them. A failed direct route need not stop sibling conversations.

## Evidence

[The session guide](../../rooms/session.md) owns production startup and recovery. Shared tests, process-loss probes and shipped-page browser journeys establish the scopes recorded in [stability](../../stability.md).
