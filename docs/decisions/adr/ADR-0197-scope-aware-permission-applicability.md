---
id: ADR-0197
status: accepted
date: 2026-10-04
tags: [loam, authority, persistence]
decision: "Persist exact-object and future-subtree permission support by resource kind. Validate scoped terms, exact effects, and containment at shared owners."
supersedes: []
superseded_by: []
amends: []
amended_by: []
---

# ADR-0197 Scope-aware permission applicability

## Context

A shared policy vocabulary can describe several interfaces. Knowing a key does
not make it applicable to every resource. Application-only checks leave direct
issuance and editing able to request unsupported permissions. A scan of current
children cannot establish what a subtree grant permits on future descendants.

## Decision

Policy copies a canonical table of at most 16 resource kinds. Each row declares
an exact-object permission mask and an owned-subtree mask covering future
children. Both masks use the complete vocabulary's stable ordering, obey its
permission dependencies, and keep exact support within subtree support.
An empty table explicitly declares kind-independent policy. A nonempty table
refuses unknown kinds. The owner record persists this contract. Registration
callbacks cannot replace it.

Terms validation uses exact support for one object, the union of exact support
for a finite selection, and the root kind's declared support for a subtree.
Every effect additionally checks the actual target's exact support. Access
descriptions project effective permissions to that target while preserving
stored configured choices and issuance ceilings. Derivation compares stored
terms, so a room subtree can issue message access without granting those message
operations on the room itself.

Creation and reparenting require the child's subtree support to fit the parent's
subtree support. This relation composes along containment without enumerating
descendants. The structural Graph receives the policy as a synchronous borrow.
The stored participants use their current owner descriptor. Validation precedes
mutation, including a same-parent move. Application schemas still own semantic
parent relations and committed content facts.

The fixed-resource C/Rust factory grants the original endpoint its exact kind's
supported permissions while retaining the complete descriptor. Rooms projects
its declared session interface. Recursive Rooms kinds require their own content
declarations. Generic attenuation never translates conversation permissions into
independent exact-message permissions.

## Alternatives considered

- Intersect support across a selection: rejects useful mixed collections.
- Accept a union without exact-target checks: admits keys on unsupported objects.
- Inspect today's descendants: misses future authority and costs graph-sized work.
- Add a second child-kind graph: duplicates a relation captured by subtree masks.
- Filter the vocabulary per interface: changes bit meanings under one identity.

## Consequences and bounds

Kind rows add 384 inline bytes plus a count to each copied descriptor. There is
no new allocation, retained callback, or descendant walk. The bounded selection
iterator shares canonical validation and resource lookup. Each kind lookup
visits at most 16 rows. Existing target admission supplies its resource record.
Owner encoding adds at most 16 byte strings of 24 bytes, within its existing
4 KiB payload budget. The maximum descriptor scenario checks that bound.

Old prerelease owner encodings without the kind list refuse decoding. Consumers
rebuild against the generated C and Rust layouts. Operators explicitly create a
fresh store and reissue authority. Reopening refuses incompatible state.

## Scope

This decision supplies generic applicability and the session declaration. It
does not supply callback context for exact content facts, projection relations,
canonical conversation history, deferred effect recovery, application management,
or the combined Rooms session replacement.

## Evidence and gate

Shared Zig scenarios cover strict declarations, direct grant and control paths,
heterogeneous selections, future children, target descriptions, and atomic
placement refusal. Owner round trips preserve the maximum descriptor. The
shared C/Rust and Chromium trace sends unsupported terms directly before and
after cold restoration. The owning checks are `check`, `runtime-check`,
`loam-browser-test`, and the Rooms browser contract.
