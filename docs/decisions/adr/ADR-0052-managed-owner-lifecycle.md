---
id: ADR-0052
status: accepted
date: 2026-10-19
tags: ["loam", "access", "storage", "memory", "capabilities", "actors", "persistence", "authority"]
decision: "An owner stores its header and sparse resource, grant and child indexes in Loam records."
supersedes: []
superseded_by: []
amends: []
amended_by: []
---

# ADR-0052 Managed owner lifecycle

## Context

Use, management, issuance and mutation recovery need to survive storage suspension and restart without exposing broad bootstrap authority or replaying an effect under changed intent.

## Decision

An owner stores its header and sparse resource, grant and child indexes in Loam records. Use and control descriptors are distinct held capabilities. Management powers and ceilings are immutable and independently checked through their control dependencies.

A control can inspect or issue within its ceiling without requiring current use to be active or able to delegate. Revoking a control retires its management descendants without silently revoking the separately held use grant. Current grant ancestry still controls use.

Issuance, grant changes, content, retained result capabilities and publication custody compose in the same transaction. Newly prepared authority becomes usable only after confirmed settlement. Inventory walks bounded direct children rather than enumerating all grants at startup.

Receipt-backed methods record exact source, intent and result in bounded endpoint-specific sequence windows. Current admission precedes replay. Replaying a retained result does not invoke the mutation, changed intent conflicts, and an expired sequence cannot become a fresh request.

## Alternatives and consequences

Issuance through use would fail precisely when a paused grant needs administration. Binding-owned inventories would duplicate policy. A second issuance receipt family would repeat recovery machinery. Retrying an effect without an exact result receipt can perform it twice.

A receipt is not authority to bypass present revocation or scope. The fixed-resource profile does not imply that every recursive resource editor or owner-lifecycle API has been exposed in every language.

## Evidence

Managed owner, control, exact-replay and cold-inventory tests run through the shared suite. C, Rust, and browser consumer proofs establish their projections. [Storage integration](../../loam/access-storage.md) and [the roadmap](../../roadmap.md) own remaining application work.
