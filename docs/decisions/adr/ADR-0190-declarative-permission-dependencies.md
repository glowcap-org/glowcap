---
id: ADR-0190
status: accepted
date: 2026-10-04
tags: [loam, authority, persistence]
decision: "Persist positive permission dependencies in the policy descriptor and enforce them on grant terms and control ceilings, independently of partial effect requirements."
supersedes: []
superseded_by: []
amends: []
amended_by: []
---

# ADR-0190 Declarative permission dependencies

## Context

Application policy declarations can require one permission to accompany another.
Validating only a client's typed terms leaves direct issuance, derivation and
editing able to bypass that rule. Hosting callbacks also miss model callers and
make cold restoration depend on registration state.

## Decision

The policy descriptor declares positive implications between stable permission
keys. Construction compiles them into at most 64 fixed prerequisite masks. The
owner record persists that matrix alongside its vocabulary. Schema identity
fixes dependency meaning as well as key ordering and constraint operators.

Configured terms and ceilings must contain every prerequisite of every selected
permission. Refusal never adds permissions. Root issuance, derivation, policy
edits and control attenuation use the existing shared validation boundary.
Transitive chains and mutually dependent groups use the same check: each selected
permission requires its declared neighbors. Valid sets remain closed under
intersection.

Effect requirements describe partial demands, rather than candidate grants.
Their keys and facts undergo structural validation without prerequisite closure.
The held grant remains subject to dependency validation. An effect asking for
Post can therefore use valid Post/Receive authority without expanding its demand.

The C ABI projects the fixed matrix. Rust converts key-pair declarations into it;
Rooms derives those pairs from its existing permission declarations and retains
the full domain ordering. No validation callback or graph traversal is added.

## Alternatives considered

- Client-only validation: remote and direct model callers can bypass it.
- Hosting decoder checks: omit direct storage calls and cold restoration.
- Registered predicates: useful for committed domain facts, but add lifetime and
  registration obligations to a finite relation expressible in the descriptor.
- Automatically add prerequisites: increases requested authority silently.

## Consequences and bounds

The matrix adds 512 bytes to each copied Policy descriptor. Construction and validation
allocate nothing. Validation visits at most 64 selected permissions. Owner
encoding stores one eight-byte byte string per declared permission in a bounded
list within the existing payload budget. Old prerelease owner encodings are
rejected; no fallback reader is added.

This contract does not decide interface applicability across heterogeneous
selections, future descendants or projections. Those scope-aware declarations
and exact-target execution remain separate prerequisites in the Rooms queue.

## Evidence and gate

Policy and grant scenarios exercise invalid raw values, transitive dependencies,
control ceilings, intersection closure and partial effect requirements. Owner
round trips and cold consumer restoration preserve enforcement. C/Rust and
browser proofs project the same declarations through the shared model. The
owning gates are `check`, `runtime-check` and the affected browser proof.
