---
id: ADR-0053
status: accepted
date: 2026-10-19
tags: ["loam", "access", "actors", "persistence", "capabilities", "ownership", "hosting", "lifetime"]
decision: "A managed method declares how it can disclose returned authority."
supersedes: []
superseded_by: []
amends: []
amended_by: []
---

# ADR-0053 Returned capability authority

## Context

A method returning a capability can disclose more authority than its data reply suggests. Saving a reference by object id or a broader parent path can also restore a stronger capability after restart.

## Decision

A managed method declares how it can disclose returned authority. A stored reference field preserves the exact held grant. A dependent result mediates each operation through both the original source intent and the exact upstream target.

Returned recursive read capabilities keep that source admission. Resource identifiers describe data and never replace a held dependency. Content and reference-field edits commit in the same owner transaction.

Saved recipes use checked local dependencies or established sturdyrefs. Live-only fields instead retain the exact capability in a bounded hosting lifetime. A stable dependent live result is prepared once, saved once and compared against its guarded pair on settlement retry.

## Alternatives and consequences

Trusting arbitrary callback returns would make disclosure ambient application policy. Deriving a new independent grant is not equivalent to passing an existing reference or mediating two existing authorities. Serializing a numeric handle cannot preserve authority across runtime teardown.

A saved live field does not make a seat or upload survive restart. Mediated access checks current source and upstream authority, but cannot recall a remote effect already dispatched. Live custody, durable graph edges and payload pages have separate owners.

## Evidence

Disclosure, dependent-result, recipe, revocation and restart tests run under `zig build test` and the relevant engine/consumer checks. [Managed access architecture](../../loam/access-architecture.md) owns the complete declaration contract.
