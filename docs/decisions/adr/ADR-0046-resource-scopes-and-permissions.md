---
id: ADR-0046
status: accepted
date: 2026-10-19
tags: ["access", "resources", "architecture", "grants", "capabilities", "storage", "loam", "actors"]
decision: "Managed access is an optional Zig application layer."
supersedes: []
superseded_by: []
amends: []
amended_by: []
---

# ADR-0046 Resource scopes and permissions

## Context

Resource structure, grant authority and actor execution have different lifetimes. Applications need to declare what an operation requires without reimplementing ancestry or silently expanding requested rights.

## Decision

Managed access is an optional Zig application layer. Resource identity and exact, selected or continuing subtree scopes are independent of actor identities. A subtree includes future descendants under its declared scope rules.

A schema fixes permission keys, bound meanings and their compact representation. Intersection keeps only common permissions and the tighter bounds. Unknown or inconsistent terms refuse. Declared positive permission dependencies and resource-kind applicability are enforced by the shared evaluator rather than added implicitly.

Each grant has an immutable issuance ceiling and current configured terms. Effective use checks every current dependency. Parent restriction applies without rewriting descendants, and later expansion cannot enlarge an issued child's ceiling. Separate grant paths do not implicitly combine permissions.

Pause is temporary, revocation is terminal for its branch, and management is independently held. Held capabilities convey authority. A resource id, payload label or collection path does not. Trusted callbacks receive one canonical bound-resource context rather than reconstructing identity from caller data.

Hosted operations can compose admitted resource and content changes in their owner transaction. Naming another participant does not substitute for holding its authority.

## Alternatives and consequences

Actor ids would tie resource identity to runtime incarnation. Materializing a subtree's current members would lose continuing scope. Client-only checks can be bypassed. Adding prerequisites automatically would silently overgrant.

Applications still declare every relevant content fact. A correct permission evaluator cannot prove a requirement the application omitted. Generic recursive editing and foreign projections remain limited to their shipped profiles.

## Evidence

Shared graph, grant, scope and managed-call tests run under `zig build test`. [Managed access architecture](../../loam/access-architecture.md) owns the complete policy contract and application responsibilities.
