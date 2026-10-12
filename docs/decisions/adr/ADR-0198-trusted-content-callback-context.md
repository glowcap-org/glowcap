---
id: ADR-0198
status: accepted
date: 2026-10-04
tags: [loam, authority, bindings]
decision: "Resolve one canonical bound-resource snapshot in managed hosting and pair it with selected content for every application callback. Forwarding describes its mediating source only."
supersedes: []
superseded_by: []
amends: []
amended_by: []
---

# ADR-0198 Trusted content callback context

## Context

A payload and method arguments cannot certify which resource an endpoint binds.
Applications need that binding to declare content facts, while local dependent
calls and forwarding have different knowledge of their dispatch targets.

## Decision

Managed hosting resolves one canonical resource snapshot through the selected
operation's existing read owner. It retains identity, kind, canonical Store
object and owner resource-graph revision with the content registration. One
`ContentInvocation` pairs those values with the selected content view, method,
arguments and delivery mode for declaration, structural action, reference
preparation and invocation. C and Rust project the same input. The storage lookup
is trusted embedding metadata before admission, never holder-facing inspection.
Scoped `describe` remains the owner of that inspection contract.

Local calls, including local dependent calls, describe their executing target.
Forwarding describes only the mediating source. The destination is the separately
held capability. It may belong to another attachment or peer. No source callback
certifies that destination's resource identity, ancestry or history.

The resource revision describes the owner's graph snapshot. The content revision
describes its payload. Neither is an admission token. The full Store-revision
fence restarts preparation after any intervening commit, including grant-only
changes. Invocation still requires current source and selected-target authority.
C verifies its reserved first strong object edge against the canonical resource
object before calling application code. Rust borrows payload, method and converted
arguments only through the synchronous callback.

## Alternatives and costs

Payload-derived identities duplicate trusted metadata and allow the application
to confuse a caller's description with an endpoint binding. A second metadata
registry adds an owner and synchronization obligation. Rebuilding metadata for
each callback repeats resolution and risks disagreement between phases.

One scalar snapshot charges the existing bounded retained call arena. No new
heap owner, lease, payload copy or descendant walk exists. Accepted calls already
need that resource row for admission. Cold proofs count one physical read per
selected row. Declaration follows resource loading, so a refusing declaration
can incur that bounded read. Existing argument projection and owned Rust
argument conversion retain their costs.

## Scope and evidence

This supplies trusted callback context. Applications still own exact held-target
admission, authorship and conversation/history facts, deferred-effect recovery,
and the combined Rooms session replacement.

[Shared Zig scenarios](../../../test/loam/access/callback_context_test.zig)
distinguish same-schema local resources, dependent targets and retired
generations. [Registration proofs](../../../test/loam/access/registration_test.zig)
hold callback consistency and grant-only revision restart.
[Forwarding proofs](../../../test/loam/access/reference_test.zig) hold source selection.
The [C seam proof](../../../test/c_abi/loam_test.zig) refuses mismatched reserved
bindings before callback execution. One
[Linux and Chromium trace](../../../bindings/proofs/_support/loam_context.rs)
compares exact/dependent identity before and after cold restoration. Generated
layouts and archive fingerprints cover the ABI change. Owning checks are
`check`, `runtime-check` and `loam-browser-test`.
